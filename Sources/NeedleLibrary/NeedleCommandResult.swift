import Foundation

/// Outcome of a single natural-language command processed through Needle.
public enum NeedleCommandResult {
    case success(tool: NeedleToolName, arguments: [String: String])
    case invalidArguments(reason: String)
    case unsupportedTool(toolName: String)
    case modelError(message: String)
    case executionError(message: String)
    case noAction(reason: String)

    /// `true` when the command was successfully parsed and would execute (or dry-run validated).
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
