import Foundation

/// Wire protocol shared by the Mac bridge server and the iPhone client.
///
/// Envelope: one JSON object per WebSocket text message.
/// Client → Mac: auth, get_status, dial, answer, hangup
/// Mac → Client: welcome, device_status, call_state, incoming_call, result, error
enum RemoteBridgeProtocol {
    static let version = 1
    static let defaultPort: UInt16 = 48765
    static let bonjourServiceType = "_celldock-bridge._tcp"
    static let maxFrameBytes = 64 * 1024
    static let authTimeoutSeconds: TimeInterval = 5

    /// Normalized call states exposed on the wire (spec: idle/incoming/dialing/
    /// ringing/connected/ended/error). Raw CallPhase travels alongside so the
    /// client never loses information the Mac app has.
    static func normalizedState(from phase: CallPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .incoming: return "incoming"
        case .dialing: return "dialing"
        case .alerting: return "ringing"
        case .active: return "connected"
        case .ending: return "ended"
        case .recovering, .error, .unavailable: return "error"
        }
    }
}

struct RemoteBridgeDeviceStatus: Codable, Equatable {
    var moduleOnline: Bool
    var operatorName: String?
    var accessTechnology: String?
    var signalBars: Int
    var signalDBm: Int?
    var simReady: Bool
    var phoneNumber: String?
    var voiceSupported: Bool

    static func make(modem snapshot: ModemSnapshot) -> Self {
        RemoteBridgeDeviceStatus(
            moduleOnline: snapshot.isConnected,
            operatorName: snapshot.operatorName,
            accessTechnology: snapshot.accessTechnology,
            signalBars: snapshot.signalBars,
            signalDBm: snapshot.signalDBm,
            simReady: snapshot.simReady,
            phoneNumber: snapshot.simPhoneNumber,
            voiceSupported: snapshot.isConnected && snapshot.simReady &&
                snapshot.voiceServiceAvailability == .available
        )
    }
}

struct RemoteBridgeCallState: Codable, Equatable {
    var state: String
    var rawPhase: String
    var number: String?
    var direction: String?

    static func make(call snapshot: CallSnapshot) -> Self {
        RemoteBridgeCallState(
            state: RemoteBridgeProtocol.normalizedState(from: snapshot.phase),
            rawPhase: snapshot.phase.rawValue,
            number: snapshot.number,
            direction: snapshot.direction?.rawValue
        )
    }
}

// MARK: - Decoding (client → mac)

enum RemoteBridgeCommand: Equatable {
    case auth(token: String)
    case getStatus
    case dial(number: String)
    case answer
    case hangup

    static func parse(from data: Data) -> Result<RemoteBridgeCommand, RemoteBridgeCommandError> {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any],
            let type = dict["type"] as? String
        else {
            return .failure(.malformedJSON)
        }
        switch type {
        case "auth":
            guard let token = dict["token"] as? String, !token.isEmpty else {
                return .failure(.missingToken)
            }
            return .success(.auth(token: token))
        case "get_status":
            return .success(.getStatus)
        case "dial":
            guard let number = dict["number"] as? String,
                  !number.isEmpty,
                  number.utf8.count <= 32,
                  CallATParser.normalizedDialNumber(number) != nil else {
                return .failure(.invalidNumber)
            }
            return .success(.dial(number: number))
        case "answer":
            return .success(.answer)
        case "hangup":
            return .success(.hangup)
        default:
            return .failure(.unknownType)
        }
    }
}

enum RemoteBridgeCommandError: String, Error {
    case malformedJSON = "malformed_json"
    case missingToken = "missing_token"
    case invalidNumber = "invalid_number"
    case unknownType = "unknown_type"

    var wireCode: String { rawValue }
}

// MARK: - Encoding helpers (mac → client)

enum RemoteBridgeEncoder {
    static func data(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    static func welcome() -> Data? {
        data(["type": "welcome", "protocol": RemoteBridgeProtocol.version])
    }

    static func error(_ code: String, message: String? = nil) -> Data? {
        var object: [String: Any] = ["type": "error", "code": code]
        if let message {
            object["message"] = message
        }
        return data(object)
    }

    static func result(for action: String, ok: Bool, detail: String? = nil) -> Data? {
        var object: [String: Any] = ["type": "result", "action": action, "ok": ok]
        if let detail {
            object["detail"] = detail
        }
        return data(object)
    }

    static func deviceStatus(_ status: RemoteBridgeDeviceStatus) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(status),
            options: []
        ) as? [String: Any] else {
            return nil
        }
        object["type"] = "device_status"
        return data(object)
    }

    static func callState(_ state: RemoteBridgeCallState) -> Data? {
        guard var object = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(state),
            options: []
        ) as? [String: Any] else {
            return nil
        }
        object["type"] = "call_state"
        return data(object)
    }

    static func incomingCall(number: String?) -> Data? {
        var object: [String: Any] = ["type": "incoming_call"]
        if let number {
            object["number"] = number
        }
        return data(object)
    }
}
