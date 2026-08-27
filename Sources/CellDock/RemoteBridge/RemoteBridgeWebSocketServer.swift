import Foundation
import Network

/// Minimal RFC 6455 WebSocket server on top of NWListener.
///
/// Only what the bridge needs: text frames from the client, server-push text
/// frames back, masked client payloads, close handling. No TLS (LAN + pairing
/// token instead), no fragmentation, no extensions. Ping/pong keepalive is
/// handled by NWProtocolWebSocket options at 30s intervals.
final class RemoteBridgeWebSocketServer {
    struct Client {
        let id: UUID
        let connection: NWConnection
    }

    var onText: ((UUID, String) -> Void)?
    var onClientCountChanged: ((Int) -> Void)?

    private let port: UInt16
    private let queue = DispatchQueue(label: "app.celldock.remote-bridge.ws")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        // ponytail: plaintext WS on LAN; token auth only. Add TLS if this
        // ever leaves the home network.
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let websocketOptions = NWProtocolWebSocket.Options()
        websocketOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(
            websocketOptions,
            at: 0
        )
        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: port)!
        )
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                NSLog("CellDockBridge listener failed: \(error)")
                self?.stop()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.clients.values.forEach { $0.cancel() }
            self.clients.removeAll()
            self.onClientCountChanged?(0)
        }
    }

    func broadcast(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.clients.values {
                self.send(data, to: connection)
            }
        }
    }

    func broadcastExcept(_ id: UUID, _ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            for (clientId, connection) in self.clients where clientId != id {
                self.send(data, to: connection)
            }
        }
    }

    func send(_ data: Data, to id: UUID) {
        queue.async { [weak self] in
            guard let self, let connection = self.clients[id] else { return }
            self.send(data, to: connection)
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.clients[id] = connection
                self.onClientCountChanged?(self.clients.count)
                if let welcome = RemoteBridgeEncoder.welcome() {
                    self.send(welcome, to: connection)
                }
            case .failed, .cancelled:
                if self.clients.removeValue(forKey: id) != nil {
                    self.onClientCountChanged?(self.clients.count)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(connection: connection, id: id)
    }

    private func receiveLoop(connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if data.count > RemoteBridgeProtocol.maxFrameBytes {
                    connection.cancel()
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                self.onText?(id, text)
            }
            if error == nil {
                self.receiveLoop(connection: connection, id: id)
            } else {
                connection.cancel()
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(
            content: data,
            contentContext: context,
            completion: .contentProcessed { _ in }
        )
    }
}
