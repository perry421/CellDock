import Combine
import Foundation
import Network

/// LAN bridge exposing the existing call core to the iPhone client.
///
/// Layering (required): WS client → this controller → AppState.dial /
/// answerCall / hangUp → ModemService → DJI modem. This file never touches
/// ModemService or AT commands directly, so the Mac app UI and the phone
/// share exactly one dialing path.
@MainActor
final class RemoteBridgeController: ObservableObject {
    static let shared = RemoteBridgeController()

    @Published private(set) var isRunning = false
    @Published private(set) var connectedClientCount = 0

    var port: UInt16 { RemoteBridgeProtocol.defaultPort }
    var pairingToken: String { token }

    private let token = RemoteBridgeToken.loadOrCreate()
    private var server: RemoteBridgeWebSocketServer?
    private var bonjourListener: NWListener?
    /// Client IDs that completed token auth.
    private var authenticated: Set<UUID> = []
    private var appState: AppState?
    private var cancellables: [AnyCancellable] = []
    /// Key of the last call_state frame pushed, for transition-only pushes.
    private var lastPushedCallKey = ""

    private init() {}

    func configure(appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState
        observeAppState(appState)
        startServer()
    }

    private func startServer() {
        guard !isRunning else { return }
        let server = RemoteBridgeWebSocketServer(port: port)
        do {
            try server.start()
        } catch {
            NSLog("CellDockBridge failed to start on port \(port): \(error)")
            return
        }
        self.server = server
        isRunning = true

        server.onText = { [weak self] id, text in
            Task { @MainActor in
                self?.handleText(id: id, text: text)
            }
        }
        server.onClientCountChanged = { [weak self] count in
            Task { @MainActor in
                guard let self else { return }
                if count == 0 {
                    self.authenticated.removeAll()
                }
                self.connectedClientCount = count
            }
        }
        advertiseViaBonjour()
        NSLog("CellDockBridge started on port \(port)")
    }

    func stop() {
        server?.stop()
        server = nil
        bonjourListener?.cancel()
        bonjourListener = nil
        authenticated.removeAll()
        cancellables.removeAll()
        isRunning = false
    }

    // MARK: - Auth + command handling

    private func handleText(id: UUID, text: String) {
        guard let data = text.data(using: .utf8) else { return }
        switch RemoteBridgeCommand.parse(from: data) {
        case let .failure(code):
            sendError(code.wireCode, to: id)
        case let .success(command):
            switch command {
            case let .auth(receivedToken):
                if receivedToken == token {
                    authenticated.insert(id)
                    pushFullStatus(to: id)
                } else {
                    sendError("auth_failed", to: id)
                    authenticated.remove(id)
                }
            case .getStatus:
                guard isAuthenticated(id) else { return requireAuth(id) }
                pushFullStatus(to: id)
            case let .dial(number):
                guard isAuthenticated(id) else { return requireAuth(id) }
                dial(number, requester: id)
            case .answer:
                guard isAuthenticated(id) else { return requireAuth(id) }
                answer(requester: id)
            case .hangup:
                guard isAuthenticated(id) else { return requireAuth(id) }
                hangUp(requester: id)
            }
        }
    }

    private func isAuthenticated(_ id: UUID) -> Bool {
        authenticated.contains(id)
    }

    private func requireAuth(_ id: UUID) {
        sendError("auth_required", to: id)
    }

    private func sendError(_ code: String, to id: UUID) {
        guard let data = RemoteBridgeEncoder.error(code) else { return }
        server?.send(data, to: id)
    }

    // MARK: - Actions (delegate straight into the existing call core)

    private func dial(_ number: String, requester id: UUID) {
        guard let appState else {
            pushResult(action: "dial", ok: false, detail: "app_not_ready", to: id)
            return
        }
        guard appState.moduleCanDial(nil), appState.call.canDial || appState.call.phase == .idle else {
            pushResult(action: "dial", ok: false, detail: "cannot_dial_now", to: id)
            return
        }
        appState.dial(number)
        pushResult(action: "dial", ok: true, detail: nil, to: id)
    }

    private func answer(requester id: UUID) {
        guard let appState else {
            pushResult(action: "answer", ok: false, detail: "app_not_ready", to: id)
            return
        }
        guard appState.call.phase == .incoming else {
            pushResult(action: "answer", ok: false, detail: "no_incoming_call", to: id)
            return
        }
        appState.answerCall()
        pushResult(action: "answer", ok: true, detail: nil, to: id)
    }

    private func hangUp(requester id: UUID) {
        guard let appState else {
            pushResult(action: "hangup", ok: false, detail: "app_not_ready", to: id)
            return
        }
        guard appState.call.hasCall else {
            pushResult(action: "hangup", ok: false, detail: "no_active_call", to: id)
            return
        }
        appState.hangUp()
        pushResult(action: "hangup", ok: true, detail: nil, to: id)
    }

    // MARK: - State observation and push

    private func observeAppState(_ appState: AppState) {
        appState.$call
            .receive(on: DispatchQueue.main)
            .sink { [weak self] call in
                self?.callDidChange(call)
            }
            .store(in: &cancellables)
        appState.$modem
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.pushDeviceStatusToAuthenticated()
            }
            .store(in: &cancellables)
    }

    private func callDidChange(_ call: CallSnapshot) {
        let wire = RemoteBridgeCallState.make(call: call)
        let key = "\(wire.state)|\(wire.rawPhase)|\(wire.number ?? "")"
        guard key != lastPushedCallKey else { return }
        lastPushedCallKey = key
        if wire.state == "incoming" {
            server?.broadcast(
                RemoteBridgeEncoder.incomingCall(number: wire.number) ?? Data()
            )
        }
        server?.broadcast(RemoteBridgeEncoder.callState(wire) ?? Data())
    }

    private func pushDeviceStatusToAuthenticated() {
        guard let appState else { return }
        let status = RemoteBridgeDeviceStatus.make(
            modem: appState.currentCommunicationModemSnapshot
        )
        server?.broadcast(RemoteBridgeEncoder.deviceStatus(status) ?? Data())
    }

    private func pushFullStatus(to id: UUID) {
        guard let appState else {
            sendError("app_not_ready", to: id)
            return
        }
        let status = RemoteBridgeDeviceStatus.make(
            modem: appState.currentCommunicationModemSnapshot
        )
        server?.send(RemoteBridgeEncoder.deviceStatus(status) ?? Data(), to: id)
        server?.send(
            RemoteBridgeEncoder.callState(
                RemoteBridgeCallState.make(call: appState.call)
            ) ?? Data(),
            to: id
        )
    }

    private func pushResult(
        action: String,
        ok: Bool,
        detail: String?,
        to id: UUID
    ) {
        server?.send(
            RemoteBridgeEncoder.result(for: action, ok: ok, detail: detail) ?? Data(),
            to: id
        )
    }

    // MARK: - Bonjour

    private func advertiseViaBonjour() {
        do {
            let listener = try NWListener(
                using: .tcp,
                on: NWEndpoint.Port(rawValue: port)!
            )
            listener.service = NWListener.Service(
                name: "CellDock Bridge",
                type: RemoteBridgeProtocol.bonjourServiceType
            )
            listener.start(queue: .global())
            bonjourListener = listener
        } catch {
            // ponytail: Bonjour advertising is best-effort; manual IP entry
            // stays the fallback path for the MVP.
            NSLog("CellDockBridge Bonjour advertising unavailable: \(error)")
        }
    }
}
