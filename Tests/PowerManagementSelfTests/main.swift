import AppKit
import Darwin
import Foundation

enum PowerSelfTestFailure: Error {
    case failed(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw PowerSelfTestFailure.failed(message) }
}

@MainActor
final class MockModemPowerTransport: ModemPowerTransport {
    struct Entry: Equatable {
        let command: ModemPowerATCommand
        let timeoutMS: Int
    }

    var responses: [ModemPowerCommandResponse] = []
    private(set) var issued: [Entry] = []
    private(set) var backgroundWorkPaused = false

    func sendPowerManagementAT(
        _ command: ModemPowerATCommand,
        timeoutMS: Int,
        completion: @escaping (ModemPowerCommandResponse) -> Void
    ) {
        issued.append(Entry(command: command, timeoutMS: timeoutMS))
        completion(responses.isEmpty
            ? ModemPowerCommandResponse(
                outcome: .notOpen,
                output: "",
                elapsedMS: 0
            )
            : responses.removeFirst())
    }

    func setBackgroundWorkPaused(_ paused: Bool) {
        backgroundWorkPaused = paused
    }
}

@MainActor
func waitUntil(
    timeout: TimeInterval = 1,
    _ condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !condition(), Date.now < deadline {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
func runPowerManagementTests() async throws {
    let timing = ModemPowerTiming(
        sleepCommandTimeoutMS: 20,
        wakeCommandTimeoutMS: 20,
        wakeRediscoveryTimeout: 0.1,
        wakeBackoff: [0.001, 0.002]
    )

    // Test 1: Recovery Engine pauses health/recovery activity.
    let engine = ModemRecoveryEngine()
    engine.start()
    try expect(engine.isHealthMonitorRunning, "health monitor did not start")
    engine.handleSystemWillSleep()
    try expect(!engine.isHealthMonitorRunning, "health monitor was not paused")
    try expect(
        engine.status.powerPhase == .preparingForSleep,
        "recovery engine did not enter preparingForSleep"
    )
    engine.applyPowerStatus(ModemPowerStatus(phase: .suspended))
    engine.handleSystemDidWake()
    try expect(
        engine.status.powerPhase == .waking,
        "recovery engine did not enter waking"
    )
    try expect(
        !engine.isRecoveryOperationRunning,
        "recovery started before AT/CFUN restoration"
    )
    engine.applyPowerStatus(ModemPowerStatus(phase: .active))
    try expect(engine.isHealthMonitorRunning, "health monitor did not resume")
    engine.stop()
    print("  Recovery monitor pause/resume passed")

    // Test 2: CFUN=1 becomes CFUN=0 during Sleep.
    let sleepTransport = MockModemPowerTransport()
    sleepTransport.responses = [
        .init(outcome: .ok, output: "+CFUN: 1\r\nOK\r\n", elapsedMS: 1),
        .init(outcome: .error, output: "ERROR\r\n", elapsedMS: 1),
        .init(outcome: .ok, output: "OK\r\n", elapsedMS: 1),
    ]
    let sleepManager = ModemPowerManager(
        transport: sleepTransport,
        timing: timing
    )
    sleepManager.handleSleep()
    let reached1 = await waitUntil { sleepManager.status.phase == .suspended }
    try expect(reached1, "Sleep did not reach suspended")
    try expect(sleepTransport.backgroundWorkPaused, "modem polling was not paused")
    try expect(
        sleepTransport.issued.map(\.command).contains(.disableRadio),
        "Sleep did not issue AT+CFUN=0"
    )
    try expect(
        sleepManager.status.lastSleepCFUN?.reported == 1 &&
            sleepManager.status.lastSleepCFUN?.command == .ok,
        "Sleep CFUN transition was not recorded"
    )
    print("  CFUN 1 → 0 passed")

    // Test 3: CFUN=0 ERROR does not prevent Sleep.
    let errorTransport = MockModemPowerTransport()
    errorTransport.responses = [
        .init(outcome: .ok, output: "+CFUN: 1\r\nOK\r\n", elapsedMS: 1),
        .init(outcome: .error, output: "ERROR\r\n", elapsedMS: 1),
        .init(outcome: .error, output: "ERROR\r\n", elapsedMS: 1),
    ]
    let errorManager = ModemPowerManager(
        transport: errorTransport,
        timing: timing
    )
    errorManager.handleSleep()
    let reached2 = await waitUntil { errorManager.status.phase == .suspended }
    try expect(reached2, "CFUN error blocked Sleep")
    try expect(
        errorManager.status.lastSleepCFUN?.command == .error,
        "CFUN error was not recorded"
    )
    print("  CFUN error remains non-fatal passed")

    // Test 4: Wake restores AT, CFUN=1, then publishes active.
    let wakeTransport = MockModemPowerTransport()
    wakeTransport.responses = [
        .init(outcome: .ok, output: "OK\r\n", elapsedMS: 1),
        .init(outcome: .ok, output: "+CFUN: 0\r\nOK\r\n", elapsedMS: 1),
        .init(outcome: .ok, output: "OK\r\n", elapsedMS: 1),
    ]
    let wakeManager = ModemPowerManager(
        transport: wakeTransport,
        timing: timing,
        initialPhase: .suspended
    )
    wakeManager.handleWake()
    let reached3 = await waitUntil { wakeManager.status.phase == .active }
    try expect(reached3, "Wake did not return to active")
    try expect(!wakeTransport.backgroundWorkPaused, "modem polling did not resume")
    try expect(
        wakeTransport.issued.map(\.command) == [
            .attention, .queryCFUN, .enableRadio,
        ],
        "Wake command order was not AT → CFUN? → CFUN=1"
    )
    print("  Wake AT/CFUN restoration passed")

    // Test 5: USB/AT rediscovery survives initial not-open results.
    let rediscoveryTransport = MockModemPowerTransport()
    rediscoveryTransport.responses = [
        .init(outcome: .notOpen, output: "", elapsedMS: 0),
        .init(outcome: .notOpen, output: "", elapsedMS: 0),
        .init(outcome: .ok, output: "OK\r\n", elapsedMS: 1),
        .init(outcome: .ok, output: "+CFUN: 1\r\nOK\r\n", elapsedMS: 1),
    ]
    let rediscoveryManager = ModemPowerManager(
        transport: rediscoveryTransport,
        timing: timing,
        initialPhase: .suspended
    )
    rediscoveryManager.handleWake()
    let reached4 = await waitUntil { rediscoveryManager.status.phase == .active }
    try expect(reached4, "Wake did not survive USB re-enumeration")
    try expect(
        rediscoveryTransport.issued.filter { $0.command == .attention }.count == 3,
        "Wake did not retry AT after USB re-enumeration"
    )
    try expect(
        rediscoveryManager.status.modemRediscoverySeconds != nil &&
            rediscoveryManager.status.atRestoreSeconds != nil,
        "Wake rediscovery timings were not recorded"
    )
    print("  USB re-enumeration passed")

    // Test 6: rapid Sleep/Wake changes keep a single final transition.
    let stormTransport = MockModemPowerTransport()
    stormTransport.responses = [
        .init(outcome: .ok, output: "OK\r\n", elapsedMS: 1),
        .init(outcome: .ok, output: "+CFUN: 1\r\nOK\r\n", elapsedMS: 1),
    ]
    let stormManager = ModemPowerManager(
        transport: stormTransport,
        timing: timing
    )
    stormManager.handleSleep()
    stormManager.handleWake()
    stormManager.handleSleep()
    stormManager.handleWake()
    let reached5 = await waitUntil { stormManager.status.phase == .active }
    try expect(reached5, "Sleep/Wake storm did not settle to active")
    try expect(
        stormTransport.issued.filter { $0.command == .attention }.count <= 1,
        "Sleep/Wake storm created duplicate Wake sessions"
    )
    try expect(
        stormTransport.issued.filter { $0.command == .disableRadio }.count <= 1,
        "Sleep/Wake storm created duplicate CFUN=0 commands"
    )
    print("  Sleep/Wake storm single-flight passed")

    // Test 7: the typed command surface cannot express QPOWD/QCFG.
    let commands = ModemPowerATCommand.allCases.map(\.rawValue)
    try expect(
        commands.allSatisfy {
            !$0.uppercased().contains("QPOWD") &&
                !$0.uppercased().contains("QCFG")
        },
        "forbidden persistent/power-down command entered the command surface"
    )
    print("  No QPOWD/QCFG command surface passed")
}

Task { @MainActor in
    do {
        try await runPowerManagementTests()
        print("All power-management self-tests passed.")
        exit(0)
    } catch {
        print("Power-management self-tests failed: \(error)")
        exit(1)
    }
}

dispatchMain()
