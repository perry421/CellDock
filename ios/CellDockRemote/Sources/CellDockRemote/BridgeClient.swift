import Foundation
import Network

/// Unified call state wire protocol (matches RemoteBridgeModels on Mac).
enum BridgeCallState: String, Equatable, Codable {
    case idle, incoming, dialing, ringing, connected, ended, error
}

/// Payload types the Mac bridge pushes over WebSocket.
enum BridgeMessage {
    case welcome(protocolVersion: Int)
    case deviceStatus(
        moduleOnline: Bool,
        operatorName: String?,
        accessTechnology: String?,
        signalBars: Int,
        signalDBm: Int?,
        simReady: Bool,
        phoneNumber: String?,
        voiceSupported: Bool
    )
    case callState(state: BridgeCallState, rawPhase: String, number: String?, direction: String?)
    case incomingCall(number: String?)
    case result(action: String, ok: Bool, detail: String?)
    case error(code: String, message: String?)
    case unknown(json: [String: Any])

    static func parse(_ data: Data) -> BridgeMessage {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else {
            return .unknown(json: [:])
        }
        switch type {
        case "welcome":
            return .welcome(protocolVersion: dict["protocol"] as? Int ?? 0)
        case "device_status":
            return .deviceStatus(
                moduleOnline: dict["moduleOnline"] as? Bool ?? false,
                operatorName: dict["operatorName"] as? String,
                accessTechnology: dict["accessTechnology"] as? String,
                signalBars: dict["signalBars"] as? Int ?? 0,
                signalDBm: dict["signalDBm"] as? Int,
                simReady: dict["simReady"] as? Bool ?? false,
                phoneNumber: dict["phoneNumber"] as? String,
                voiceSupported: dict["voiceSupported"] as? Bool ?? false
            )
        case "call_state":
            return .callState(
                state: BridgeCallState(rawValue: dict["state"] as? String ?? "") ?? .idle,
                rawPhase: dict["rawPhase"] as? String ?? "",
                number: dict["number"] as? String,
                direction: dict["direction"] as? String
            )
        case "incoming_call":
            return .incomingCall(number: dict["number"] as? String)
        case "result":
            return .result(
                action: dict["action"] as? String ?? "",
                ok: dict["ok"] as? Bool ?? false,
                detail: dict["detail"] as? String
            )
        case "error":
            return .error(
                code: dict["code"] as? String ?? "",
                message: dict["message"] as? String
            )
        default:
            return .unknown(json: dict)
        }
    }
}

/// Command types the iPhone sends to Mac.
enum BridgeCommand {
    case auth(token: String)
    case getStatus
    case dial(number: String)
    case answer
    case hangup

    var data: Data? {
        var dict: [String: Any] = ["type": typeString]
        switch self {
        case let .auth(token):
            dict["token"] = token
        case .getStatus:
            break
        case let .dial(number):
            dict["number"] = number
        case .answer:
            break
        case .hangup:
            break
        }
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    private var typeString: String {
        switch self {
        case .auth: return "auth"
        case .getStatus: return "get_status"
        case .dial: return "dial"
        case .answer: return "answer"
        case .hangup: return "hangup"
        }
    }
}

// MARK: - WebSocket client

final class BridgeClient: ObservableObject {
    static let defaultPort: UInt16 = 48765
    static let pairingTokenKey = "app.celldock.mac.bridge.pairingToken"

    @Published var isConnected = false
    @Published var isAuthenticated = false
    @Published var lastError: String?

    @Published var moduleOnline = false
    @Published var operatorName: String?
    @Published var signalBars = 0
    @Published var simReady = false
    @Published var phoneNumber: String?

    @Published var callState: BridgeCallState = .idle {
        didSet { objectWillChange.send() }
    }
    @Published var callNumber: String?
    @Published var callDirection: String?

    /// Discovered Bonjour services (best-effort; populated when visible).
    @Published var discoveredServices: [NWBrowser.Result] = []

    private var connection: NWConnection?
    private var receiveTask: Task<Void, Never>?
    private var browser: NWBrowser?
    private var token: String {
        get { Defaults.string(forKey: Self.pairingTokenKey) ?? "" }
        set { Defaults.set(newValue, forKey: Self.pairingTokenKey) }
    }

    /// Manual IP:port entry (for MVP before Bonjour is reliable).
    var manualHost: String?
    var manualPort: UInt16?

    var pairingTokenForUI: String {
        token.isEmpty ? "(no token)" : token
    }

    var connectionLabel: String {
        if let host = manualHost, let port = manualPort {
            return "\(host):\(port)"
        }
        if let svc = discoveredServices.first,
           case .hostPort(let host, let port) = svc.endpoint {
            return "\(host):\(port.rawValue)"
        }
        return "auto-discover"
    }

    func start() {
        receiveTask = Task { await runReceiveLoop() }
        startBonjourDiscovery()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        disconnect()
    }

    func authenticate() {
        guard !token.isEmpty else { return }
        send(BridgeCommand.auth(token: token))
    }

    func getStatus() {
        send(BridgeCommand.getStatus)
    }

    func dial(_ number: String) {
        send(BridgeCommand.dial(number: number))
    }

    func answer() {
        send(BridgeCommand.answer)
    }

    func hangup() {
        send(BridgeCommand.hangup)
    }

    func connect(to host: String, port: UInt16) {
        disconnect()
        manualHost = host
        manualPort = port
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let conn = NWConnection(to: endpoint, using: .tcp)
        setupConnection(conn)
    }

    private func send(_ command: BridgeCommand) {
        guard let data = command.data, let conn = connection, isConnected else { return }
        let context = NWConnection.ContentContext(identifier: "text", metadata: [
            NWProtocolWebSocket.Metadata(opcode: .text)
        ])
        conn.send(content: data, contentContext: context, completion: .contentProcessed { [weak self] _ in
            self?.lastError = nil
        })
    }

    private func setupConnection(_ conn: NWConnection) {
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.lastError = nil
                case .failed(let error):
                    self?.isConnected = false
                    self?.lastError = "connection failed: \(error.localizedDescription)"
                case .cancelled:
                    self?.isConnected = false
                default: break
                }
            }
        }
        conn.start(queue: .global())
        readMessages(from: conn)
    }

    private func readMessages(from conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if data.count > 64 * 1024 {
                    conn.cancel()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    self.handleMessage(text)
                }
            }
            if error == nil && !isComplete {
                self.readMessages(from: conn)
            } else {
                DispatchQueue.main.async {
                    self.isConnected = false
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let msg = BridgeMessage.parse(data)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch msg {
            case let .welcome(version):
                if version == 1 { self.authenticate() }
            case let .deviceStatus(moduleOnline, operatorName, _, signalBars, _, simReady, phoneNumber, voiceSupported):
                self.moduleOnline = moduleOnline
                self.operatorName = operatorName
                self.signalBars = signalBars
                self.simReady = simReady
                self.phoneNumber = phoneNumber
            case let .callState(state, _, number, direction):
                self.callState = state ?? .idle
                self.callNumber = number
                self.callDirection = direction
            case let .incomingCall(number):
                self.callState = .incoming
                self.callNumber = number
            case let .result(action, ok, detail):
                // result frames are acknowledgments; UI driven by call_state
                if !ok {
                    self.lastError = "[\(action)] \(detail ?? "")"
                }
            case let .error(code, message):
                self.lastError = "\(code): \(message ?? "")"
                if code == "auth_failed" || code == "auth_required" {
                    self.isAuthenticated = false
                }
            case .welcome: break
            case .unknown: break
            }
        }
    }

    private func disconnect() {
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = false
            self?.lastError = nil
        }
    }

    private func runReceiveLoop() async {
        // Reconnection is handled per-connection; this loop is a placeholder for
        // background keepalive or re-browser tasks.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: - Bonjour

    private func startBonjourDiscovery() {
        browser?.cancel()
        browser = nil
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: "_celldock-bridge._tcp",
            domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                // Bonjour unavailable on this network; user falls back to manual IP.
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { [weak self] in
                self?.discoveredServices = Array(results)
            }
        }
        browser.start(queue: .global())
    }
}

// MARK: - UserDefaults helpers

private enum Defaults {
    static func string(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }
    static func set(_ value: String?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
