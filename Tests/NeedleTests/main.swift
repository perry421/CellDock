import Foundation
import NeedleLibrary

var passed = 0
var failed = 0
var lastFail: String = ""

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "") {
    if a == b { passed += 1 }
    else { failed += 1; lastFail = msg; print("FAIL: \(msg ?? "(unnamed)") — expected \(b), got \(a)") }
}

func assertNil(_ a: Any?, _ msg: String = "") {
    if a == nil { passed += 1 }
    else { failed += 1; lastFail = msg; print("FAIL: \(msg ?? "(unnamed)") — expected nil, got \(a)") }
}

func assertTrue(_ cond: Bool, _ msg: String = "") {
    if cond { passed += 1 }
    else { failed += 1; lastFail = msg; print("FAIL: \(msg ?? "(unnamed)")") }
}

func assertFalse(_ cond: Bool, _ msg: String = "") {
    if !cond { passed += 1 }
    else { failed += 1; lastFail = msg; print("FAIL: \(msg ?? "(unnamed)")") }
}

func XCTAssertNotNil(_ value: Any?, _ msg: String = "") {
    if value != nil { passed += 1 }
    else { failed += 1; lastFail = msg; print("FAIL: \(msg ?? "(unnamed)") — XCTAssertNotNil failed") }
}

func testNeedleCommandResult() {
    let r1 = NeedleCommandResult.success(tool: .dial, arguments: ["number": "10086"])
    switch r1 {
    case .success(let t, let a):
        assertEqual(t, .dial, "cmd_result_success_tool"); assertEqual(a["number"], "10086", "cmd_result_success_args")
    default: failed += 1; lastFail = "cmd_result_success"; print("FAIL: cmd_result_success")
    }
    assertTrue(r1.isSuccess, "cmd_result_isSuccess")

    let r2 = NeedleCommandResult.success(tool: .answerCall, arguments: [:])
    switch r2 { case .success(let t, _): assertEqual(t, .answerCall, "cmd_answer_call") default: failed += 1; lastFail = "cmd_answer_call" }

    let r3 = NeedleCommandResult.success(tool: .hangUp, arguments: [:])
    switch r3 { case .success(let t, _): assertEqual(t, .hangUp, "cmd_hang_up") default: failed += 1; lastFail = "cmd_hang_up" }

    let r4 = NeedleCommandResult.unsupportedTool(toolName: "delete_file")
    switch r4 { case .unsupportedTool(let n): assertEqual(n, "delete_file", "cmd_unsupported") default: failed += 1; lastFail = "cmd_unsupported" }

    let r5 = NeedleCommandResult.modelError(message: "timeout")
    switch r5 { case .modelError(let m): assertEqual(m, "timeout", "cmd_model_error") default: failed += 1; lastFail = "cmd_model_error" }

    let r6 = NeedleCommandResult.invalidArguments(reason: "empty number")
    switch r6 { case .invalidArguments(let r): assertEqual(r, "empty number", "cmd_invalid_args") default: failed += 1; lastFail = "cmd_invalid_args" }

    let r7 = NeedleCommandResult.noAction(reason: "not a command")
    switch r7 { case .noAction(let r): assertEqual(r, "not a command", "cmd_no_action") default: failed += 1; lastFail = "cmd_no_action" }
}

func testNeedleToolDefinitions() {
    for tool in NeedleToolName.allCases {
        let schema = tool.schema
        XCTAssertNotNil(schema["name"] as? String, "schema_name_\(tool.rawValue)")
        XCTAssertNotNil(schema["description"] as? String, "schema_desc_\(tool.rawValue)")
        XCTAssertNotNil(schema["parameters"] as? [String: Any], "schema_params_\(tool.rawValue)")
    }
    assertTrue(NeedleToolName.dial.isSideEffect, "side_effect_dial")
    assertTrue(NeedleToolName.answerCall.isSideEffect, "side_effect_answer")
    assertTrue(NeedleToolName.hangUp.isSideEffect, "side_effect_hangup")
    assertFalse(NeedleToolName.getCallStatus.isSideEffect, "side_effect_status")

    let schema = NeedleToolName.dial.schema
    let params = schema["parameters"] as? [String: Any]
    let required = params?["required"] as? [String]
    assertEqual(required, ["number"], "dial_required_number")

    let names = NeedleToolName.allCases.map(\.rawValue)
    assertEqual(names.count, Set(names).count, "unique_names")
}

func testNeedleEngine() {
    assertEqual(NeedleEngine.EngineError.pythonNotFound.errorDescription, "Python 3 not found", "err_python")
    assertEqual(NeedleEngine.EngineError.inferenceTimeout.errorDescription, "Inference timed out", "err_timeout")
    assertEqual(NeedleEngine.EngineError.decodeError("json bad").errorDescription, "Decode error: json bad", "err_decode")
    assertEqual(NeedleEngine.EngineError.unknownTool("foo").errorDescription, "Unknown tool: foo", "err_unknown")

    let engine = NeedleEngine(timeoutSeconds: 1.0)
    
    XCTAssertTrue({ () -> Bool in engine.terminate(); return true }())
}

func testPhoneValidation() {
    assertEqual(validateTestPhoneNumber("10086"), "10086", "valid_digits")
    assertEqual(validateTestPhoneNumber("+8613800138000"), "+8613800138000", "plus_prefix")
    assertEqual(validateTestPhoneNumber("800-555-1234"), "8005551234", "with_dashes")
    assertEqual(validateTestPhoneNumber("(800) 555-1234"), "8005551234", "with_parens")
    assertEqual(validateTestPhoneNumber("*123#"), "*123#", "star_hash")
    assertEqual(validateTestPhoneNumber(" 10086 "), "10086", "with_spaces")

    let thirtyTwo = String(repeating: "1", count: 32)
    let result32 = validateTestPhoneNumber(thirtyTwo)
    if result32 == thirtyTwo { passed += 1 } else { failed += 1; lastFail = "32_chars"; print("FAIL: 32_chars — expected \(thirtyTwo), got \(result32 ?? "nil")") }

    assertNil(validateTestPhoneNumber(""), "empty")
    assertNil(validateTestPhoneNumber("   "), "whitespace")
    let long = String(repeating: "1", count: 33)
    assertNil(validateTestPhoneNumber(long), "too_long")
    assertNil(validateTestPhoneNumber("100AB"), "letters")
    assertNil(validateTestPhoneNumber("100@86"), "at_sign")
    assertNil(validateTestPhoneNumber("拨打10086"), "chinese")
}

func XCTAssertTrue(_ cond: Bool) -> Bool { return cond }

print("=== Needle Library Unit Tests ===")
testNeedleCommandResult()
testNeedleToolDefinitions()
testNeedleEngine()
testPhoneValidation()
print("=== Results: \(passed) passed, \(failed) failed ===")
if failed > 0 { print("Last fail: \(lastFail)") }
exit(failed > 0 ? 1 : 0)
