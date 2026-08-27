import Foundation
import OSLog

private let logger = Logger(subsystem: "app.celldock.mac", category: "Needle")

public final class NeedleEngine {

    public enum EngineError: Error, LocalizedError {
        case pythonNotFound
        case processNotReady
        case inferenceTimeout
        case decodeError(String)
        case unknownTool(String)

        public var errorDescription: String? {
            switch self {
            case .pythonNotFound: return "Python 3 not found"
            case .processNotReady: return "Needle engine not initialised"
            case .inferenceTimeout: return "Inference timed out"
            case .decodeError(let msg): return "Decode error: \(msg)"
            case .unknownTool(let name): return "Unknown tool: \(name)"
            }
        }
    }

    private let timeoutSeconds: TimeInterval

    public var isReady: Bool { findPython() != nil && findScriptPath() != nil }

    public init(timeoutSeconds: TimeInterval = 10.0) {
        self.timeoutSeconds = timeoutSeconds
    }

    deinit {}

    public static func bootstrap(tools: [NeedleToolName], timeoutSeconds: TimeInterval = 10.0) async throws -> NeedleEngine {
        let engine = NeedleEngine(timeoutSeconds: timeoutSeconds)
        guard engine.isReady else { throw EngineError.pythonNotFound }
        return engine
    }

    public func complete(_ text: String, dryRun: Bool = true) async throws -> NeedleCommandResult {
        guard let pythonURL = findPython() else { throw EngineError.pythonNotFound }
        guard let scriptPath = findScriptPath() else { throw EngineError.processNotReady }

        let proc = Process()
        proc.executableURL = pythonURL
        proc.arguments = [scriptPath]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()

        let payload = try JSONSerialization.data(withJSONObject: ["text": text, "dry_run": dryRun])
        let stdinContent = "COMMAND ".data(using: .utf8)! + payload + "\n".data(using: .utf8)!
        try stdinPipe.fileHandleForWriting.write(contentsOf: stdinContent)
        stdinPipe.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var response: String?
        while Date() < deadline {
            if !proc.isRunning { break }
            let data = stdoutPipe.fileHandleForReading.availableData
            guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else {
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            response = line
            break
        }

        let _ = proc.waitUntilExit()

        if let resp = response {
            return try parseResult(resp)
        }

        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errMsg = String(data: errData, encoding: .utf8) ?? ""
        if !errMsg.isEmpty {
            throw EngineError.decodeError(String(errMsg.prefix(200)))
        }

        throw EngineError.inferenceTimeout
    }

    public func terminate() {}

    private func findPython() -> URL? {
        if let env = ProcessInfo.processInfo.environment["NEEDLE_PYTHON"],
           FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        for path in [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3"
        ] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func findScriptPath() -> String? {
        // Check user-local bin
        let home = NSHomeDirectory()
        let userPath = home + "/bin/celldock-needle-bridge.py"
        if FileManager.default.fileExists(atPath: userPath) { return userPath }
        // Check /tmp
        if FileManager.default.fileExists(atPath: "/tmp/celldock-needle-bridge.py") {
            return "/tmp/celldock-needle-bridge.py"
        }
        return nil
    }

    private func parseResult(_ jsonStr: String) throws -> NeedleCommandResult {
        guard let data = jsonStr.data(using: .utf8) else {
            throw EngineError.decodeError("non-UTF8 response")
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.decodeError("not a JSON object")
        }

        if let errMsg = dict["error"] as? String {
            throw EngineError.decodeError(errMsg)
        }

        let confidence = (dict["confidence"] as? Double) ?? 0.0
        let rawCalls = dict["function_calls"] as? [[String: Any]] ?? []

        if rawCalls.isEmpty {
            let reasoning = dict["reasoning"] as? String ?? ""
            if confidence > 0.5 {
                return .noAction(reason: reasoning)
            }
            return .noAction(reason: "no tool call matched (confidence=\(String(format: "%.2f", confidence)))")
        }

        let call = rawCalls[0]
        let toolName = call["name"] as? String ?? ""
        let args = (call["arguments"] as? [String: Any]) ?? [:]
        let stringArgs = args.mapValues { "\($0)" }

        let tool: NeedleToolName?
        switch toolName {
        case "dial": tool = .dial
        case "answer_call": tool = .answerCall
        case "hang_up": tool = .hangUp
        case "get_call_status": tool = .getCallStatus
        default: tool = nil
        }

        guard let tool = tool else {
            logger.warning("Needle requested unknown tool: \(toolName, privacy: .public)")
            return .unsupportedTool(toolName: toolName)
        }

        logger.notice(
            "Tool selected: \(toolName, privacy: .public) | conf=\(String(format: "%.2f", confidence)) | args=\(stringArgs)"
        )

        return .success(tool: tool, arguments: stringArgs)
    }
}
