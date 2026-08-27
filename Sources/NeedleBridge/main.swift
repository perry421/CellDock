#!/usr/bin/env swift
import Foundation
import NeedleLibrary

final class MockCallController: NeedleCallController {
    var callPhase: CallPhase = .idle
    var callNumber: String?
    var callHasCall: Bool { callPhase != .idle && callPhase != .unavailable && callPhase != .error }
    var dialCalledWith: String?
    var answerCalled = false
    var hangUpCalled = false

    func dial(_ number: String) {
        fputs("[EXEC] dial(\"\(number)\")\n", stdout)
        fflush(stdout)
        callNumber = number
        callPhase = .dialing
    }

    func answerCall() {
        fputs("[EXEC] answerCall()\n", stdout)
        fflush(stdout)
        answerCalled = true
        callPhase = .active
    }

    func hangUp() {
        fputs("[EXEC] hangUp()\n", stdout)
        fflush(stdout)
        hangUpCalled = true
        callPhase = .idle
    }
}

func logSafe(_ number: String?) -> String {
    guard let n = number, n.count > 4 else { return "(empty)" }
    return String(n.prefix(3)) + "****" + String(n.suffix(4))
}

func printResult(_ result: NeedleCommandResult, dryRun: Bool) {
    switch result {
    case .success(let tool, let args):
        let label = dryRun ? "DRY RUN" : "EXEC"
        let numDisplay = args["number"].map { logSafe($0) } ?? ""
        fputs("\(label) Tool: \(tool.rawValue) | Args: \(args) | Number: \(numDisplay)\n", stdout)
    case .invalidArguments(let reason):
        fputs("INVALID_ARGS: \(reason)\n", stdout)
    case .unsupportedTool(let name):
        fputs("UNSUPPORTED_TOOL: \(name)\n", stdout)
    case .modelError(let msg):
        fputs("MODEL_ERROR: \(msg)\n", stdout)
    case .executionError(let msg):
        fputs("EXEC_ERROR: \(msg)\n", stdout)
    case .noAction(let reason):
        fputs("NO_ACTION: \(reason)\n", stdout)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
var dryRun = true
var showStatus = false
var listTools = false
var benchCount: Int?
var command: String?

// Parse args manually for clarity
var i = 0
while i < args.count {
    let arg = args[i]
    if arg == "--dry-run" { dryRun = true }
    else if arg == "--execute" { dryRun = false }
    else if arg == "--status" { showStatus = true }
    else if arg == "--tools" { listTools = true }
    else if arg.hasPrefix("--bench") {
        let rest = arg.dropFirst("--bench".count)
        if let count = Int(rest) {
            benchCount = count
        } else if i + 1 < args.count, let c = Int(args[i + 1]) {
            benchCount = c
            i += 1
        }
    } else if !arg.hasPrefix("--") {
        // First non-flag arg is the command
        if command == nil { command = arg }
    }
    i += 1
}

if listTools {
    fputs("Available Needle tools:\n", stdout)
    for tool in NeedleToolName.allCases {
        let side = tool.isSideEffect ? " [SIDE_EFFECT]" : " [READ_ONLY]"
        fputs("  - \(tool.rawValue)\(side)\n", stdout)
        if let desc = tool.schema["description"] as? String {
            fputs("    \(desc)\n", stdout)
        }
    }
    exit(0)
}

if showStatus {
    let mock = MockCallController()
    let engine = NeedleEngine()
    let router = NeedleToolRouter(engine: engine, controller: mock)
    let result = router.callStatusSnapshot()
    printResult(result, dryRun: false)
    exit(0)
}

if let count = benchCount, let cmd = command {
    fputs("Benchmark: \(count) runs of \"\(cmd)\"\n", stdout)
    fflush(stdout)
    do {
        let engine = try await NeedleEngine.bootstrap(tools: [.dial, .answerCall, .hangUp, .getCallStatus])
        let mock = MockCallController()
        let router = NeedleToolRouter(engine: engine, controller: mock)
        var latencies: [Double] = []
        for idx in 0..<count {
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = await router.processNaturalLanguageCommand(cmd, dryRun: true)
            let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            latencies.append(dt)
            fputs("  [\(idx+1)/\(count)] \(String(format: "%.0fms", dt)) → ", stdout)
            fflush(stdout)
            printResult(result, dryRun: true)
        }
        if let min = latencies.min(), let max = latencies.max(), !latencies.isEmpty {
            let avg = latencies.reduce(0, +) / Double(latencies.count)
            fputs("\nLatency: min=\(String(format: "%.0f", min))ms avg=\(String(format: "%.0f", avg))ms max=\(String(format: "%.0f", max))ms\n", stdout)
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stdout)
        exit(1)
    }
    exit(0)
}

if let cmd = command {
    fputs("Input: \(cmd)\n", stdout)
    do {
        let engine = try await NeedleEngine.bootstrap(tools: [.dial, .answerCall, .hangUp, .getCallStatus])
        let mock = MockCallController()
        let router = NeedleToolRouter(engine: engine, controller: mock)
        let result = await router.processNaturalLanguageCommand(cmd, dryRun: dryRun)
        printResult(result, dryRun: dryRun)
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stdout)
        exit(1)
    }
} else {
    fputs("""
NeedleBridge — CellDock local Needle 2 tool-calling CLI harness

Usage:
  swift run NeedleBridge [OPTIONS] "command"

Options:
  --dry-run     Validate without executing side-effect tools (default)
  --execute     Actually execute tool calls
  --status      Query call status only (no inference)
  --tools       List available tools and exit
  --bench N     Run N inference passes to measure latency

Examples:
  swift run NeedleBridge "Call 10086"
  swift run NeedleBridge --dry-run "拨打10086"
  swift run NeedleBridge --status
  swift run NeedleBridge --bench 5 "挂电话"
""", stdout)
}
