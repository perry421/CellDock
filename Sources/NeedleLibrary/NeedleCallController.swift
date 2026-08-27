import Foundation

/// Protocol that NeedleToolRouter calls to perform real actions.
/// Implementations live in CellDock (wrapping AppState); mocks live in tests/CLI.
public protocol NeedleCallController: AnyObject {
    func dial(_ number: String)
    func answerCall()
    func hangUp()
    var callPhase: CallPhase { get }
    var callNumber: String? { get }
    var callHasCall: Bool { get }
}

/// Call phase value (mirrors CellDock's CallPhase for standalone use).
public enum CallPhase: String {
    case unavailable
    case idle
    case incoming
    case dialing
    case alerting
    case active
    case ending
    case recovering
    case error
}
