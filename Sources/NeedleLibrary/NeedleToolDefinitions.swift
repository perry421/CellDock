import Foundation

/// All tools declared to Needle. The router knows which are read-only vs side-effect.
public enum NeedleToolName: String, CaseIterable {
    // Side-effect tools
    case dial
    case answerCall = "answer_call"
    case hangUp = "hang_up"

    // Read-only
    case getCallStatus = "get_call_status"

    /// `true` for tools that modify system state; `false` for read-only queries.
    public var isSideEffect: Bool {
        switch self {
        case .dial, .answerCall, .hangUp: return true
        case .getCallStatus: return false
        }
    }

    /// JSON schema describing this tool to the Needle Python process.
    public var schema: [String: Any] {
        switch self {
        case .dial:
            return [
                "name": "dial",
                "description": "Place an outgoing call to the given phone number. Use when user says 拨打/打电话/dial/call.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "number": [
                            "type": "string",
                            "description": "Phone number to dial. Digits only (0-9), may include + * #."
                        ]
                    ],
                    "required": ["number"]
                ]
            ]
        case .answerCall:
            return [
                "name": "answer_call",
                "description": "Answer an incoming phone call. Use when user says 接听/接电话/answer.",
                "parameters": [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            ]
        case .hangUp:
            return [
                "name": "hang_up",
                "description": "End or hang up the current phone call. Use when user says 挂断/挂电话/结束通话/hang up.",
                "parameters": [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            ]
        case .getCallStatus:
            return [
                "name": "get_call_status",
                "description": "Get the current call status without changing anything. Use when user asks 状态/现在怎么样/status.",
                "parameters": [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            ]
        }
    }
}
