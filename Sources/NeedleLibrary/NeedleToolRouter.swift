import Foundation
import OSLog

private let logger = Logger(subsystem: "app.celldock.mac", category: "Needle")

private func logSafe(_ number: String?) -> String {
    guard let n = number, n.count > 4 else { return "(empty)" }
    return String(n.prefix(3)) + "****" + String(n.suffix(4))
}

/// Extract digit characters from any input string.
public func extractDigits(from input: String) -> String {
    return input.filter { "0123456789".contains($0) }
}

/// Validate and clean a phone number string.
public func validatePhoneNumber(_ number: String) -> String? {
    guard !number.isEmpty else { return nil }
    guard number.count <= 32 else { return nil }
    // Only allow digits, +, *, #, -, space, (, )
    let allowed = Set<Character>(["0","1","2","3","4","5","6","7","8","9","+","*","#","-"," ","(",")"])
    guard number.allSatisfy({ allowed.contains($0) }) else { return nil }
    guard number.contains(where: { "0123456789".contains($0) }) else { return nil }
    // Clean formatting characters
    let clean = number.components(separatedBy: CharacterSet(charactersIn: " -()")).joined()
    guard !clean.isEmpty else { return nil }
    return clean
}

// Expose for tests
public func validateTestPhoneNumber(_ number: String) -> String? {
    return validatePhoneNumber(number)
}

public final class NeedleToolRouter {
    private let engine: NeedleEngine
    private let controller: NeedleCallController

    public init(engine: NeedleEngine, controller: NeedleCallController) {
        self.engine = engine
        self.controller = controller
    }

    public func processNaturalLanguageCommand(_ text: String, dryRun: Bool = true) async -> NeedleCommandResult {
        let needleResult: NeedleCommandResult
        do {
            needleResult = try await engine.complete(text, dryRun: dryRun)
        } catch let err as NeedleEngine.EngineError {
            logger.warning("Needle engine error: \(err.errorDescription ?? "unknown")")
            return .modelError(message: err.errorDescription ?? "unknown")
        } catch {
            logger.warning("Needle unexpected error: \(error)")
            return .modelError(message: error.localizedDescription)
        }

        switch needleResult {
        case .success(let tool, let arguments):
            return validateAndForward(tool: tool, arguments: arguments, dryRun: dryRun)
        case .invalidArguments, .unsupportedTool, .modelError, .executionError, .noAction:
            return needleResult
        @unknown default:
            return .modelError(message: "unknown result variant")
        }
    }

    public func callStatusSnapshot() -> NeedleCommandResult {
        let phase = controller.callPhase
        let hasCall = controller.callHasCall
        let number = controller.callNumber
        logger.notice(
            "Call status: phase=\(phase.rawValue, privacy: .public) hasCall=\(hasCall) number=\(logSafe(number))"
        )
        return .success(
            tool: .getCallStatus,
            arguments: [
                "phase": phase.rawValue,
                "hasCall": "\(hasCall)",
                "number": number ?? ""
            ]
        )
    }

    private func validateAndForward(
        tool: NeedleToolName,
        arguments: [String: String],
        dryRun: Bool
    ) -> NeedleCommandResult {
        if tool == .dial {
            let rawNumber = arguments["number"] ?? ""
            // For Chinese input like "拨打10086", Needle may put the whole string in number.
            // Extract digits to handle this case.
            let digits = extractDigits(from: rawNumber)
            let number = !digits.isEmpty ? digits : rawNumber
            guard let cleaned = validatePhoneNumber(number) else {
                return .invalidArguments(reason: "invalid phone number format")
            }
            if dryRun {
                logger.notice("DRY RUN dial → \(cleaned, privacy: .public)")
                return .success(tool: tool, arguments: ["number": cleaned])
            }
            logger.notice("Executing dial → \(logSafe(number))")
            controller.dial(cleaned)
            return .success(tool: tool, arguments: ["number": number])
        }

        if tool == .answerCall {
            if dryRun {
                logger.notice("DRY RUN answer_call")
                return .success(tool: tool, arguments: [:])
            }
            logger.notice("Executing answer_call")
            controller.answerCall()
            return .success(tool: tool, arguments: [:])
        }

        if tool == .hangUp {
            if dryRun {
                logger.notice("DRY RUN hang_up")
                return .success(tool: tool, arguments: [:])
            }
            logger.notice("Executing hang_up")
            controller.hangUp()
            return .success(tool: tool, arguments: [:])
        }

        return .unsupportedTool(toolName: tool.rawValue)
    }
}
