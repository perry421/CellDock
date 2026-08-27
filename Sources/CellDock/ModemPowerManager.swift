import Foundation
import OSLog

enum ModemPowerPhase: String, Equatable, Sendable {
    case active
    case preparingForSleep
    case suspended
    case waking
}

enum ModemPowerATCommand: String, CaseIterable, Sendable {
    case attention = "AT"
    case queryCFUN = "AT+CFUN?"
    case disableRadio = "AT+CFUN=0"
    case enableRadio = "AT+CFUN=1"
    case testQSCLK = "AT+QSCLK=?"
    case queryQSCLK = "AT+QSCLK?"
    case enableQSCLK = "AT+QSCLK=1"
}

enum ModemPowerCommandOutcome: String, Equatable, Sendable {
    case ok
    case error
    case timeout
    case unsupported
    case notOpen
}

struct ModemPowerCFUNSnapshot: Equatable, Sendable {
    var reported: Int?
    var command: ModemPowerCommandOutcome
    var elapsedMS: Int
}

struct ModemPowerStatus: Equatable, Sendable {
    var phase: ModemPowerPhase = .active
    var lastSleepCFUN: ModemPowerCFUNSnapshot?
    var lastWakeCFUN: ModemPowerCFUNSnapshot?
    var supportsQSCLK: Bool?
    var lastQSCLKCommand: ModemPowerCommandOutcome?
    var modemRediscoverySeconds: TimeInterval?
    var atRestoreSeconds: TimeInterval?
    var internetRestoreSeconds: TimeInterval?
    var suspendedAt: Date?
    var wokeAt: Date?
    var lastError: String?
}

struct ModemPowerCommandResponse: Equatable, Sendable {
    var outcome: ModemPowerCommandOutcome
    var output: String
    var elapsedMS: Int
}

@MainActor
protocol ModemPowerTransport: AnyObject {
    func sendPowerManagementAT(
        _ command: ModemPowerATCommand,
        timeoutMS: Int,
        completion: @escaping (ModemPowerCommandResponse) -> Void
    )

    func setBackgroundWorkPaused(_ paused: Bool)
}

@MainActor
final class ModemServicePowerBridge: ModemPowerTransport {
    typealias Sender = (
        ModemPowerATCommand,
        Int,
        @escaping (ModemPowerCommandResponse) -> Void
    ) -> Void

    private let sender: Sender
    private let backgroundWorkHook: (Bool) -> Void

    init(
        sender: @escaping Sender,
        backgroundWorkHook: @escaping (Bool) -> Void
    ) {
        self.sender = sender
        self.backgroundWorkHook = backgroundWorkHook
    }

    func sendPowerManagementAT(
        _ command: ModemPowerATCommand,
        timeoutMS: Int,
        completion: @escaping (ModemPowerCommandResponse) -> Void
    ) {
        sender(command, timeoutMS, completion)
    }

    func setBackgroundWorkPaused(_ paused: Bool) {
        backgroundWorkHook(paused)
    }
}

enum ModemPowerResponseParser {
    static func currentCFUN(_ response: String) -> Int? {
        guard let line = ATResponseParser.normalizedLines(response).first(where: {
            $0.uppercased().hasPrefix("+CFUN:")
        }) else {
            return nil
        }
        let payload = line.dropFirst("+CFUN:".count)
        let value = payload.split(separator: ",").first.map(String.init) ?? ""
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func supportsQSCLK(_ response: String) -> Bool {
        guard let line = ATResponseParser.normalizedLines(response).first(where: {
            $0.uppercased().hasPrefix("+QSCLK:")
        }) else {
            return false
        }
        let payload = line.dropFirst("+QSCLK:".count)
        return payload.contains("1")
    }
}

struct ModemPowerPolicy: Equatable, Sendable {
    var sleepPowerReductionEnabled: Bool

    static let `default` = ModemPowerPolicy(sleepPowerReductionEnabled: true)
}

struct ModemPowerTiming: Equatable, Sendable {
    var sleepCommandTimeoutMS: Int
    var wakeCommandTimeoutMS: Int
    var wakeRediscoveryTimeout: TimeInterval
    var wakeBackoff: [TimeInterval]

    static let `default` = ModemPowerTiming(
        sleepCommandTimeoutMS: 1_500,
        wakeCommandTimeoutMS: 2_000,
        wakeRediscoveryTimeout: 12,
        wakeBackoff: [0.5, 1, 2, 3]
    )
}

@MainActor
final class ModemPowerManager {
    private static let log = Logger(
        subsystem: "app.celldock.mac",
        category: "Power"
    )

    private let transport: ModemPowerTransport
    private let timing: ModemPowerTiming
    private var policy: ModemPowerPolicy
    private var sleepTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var phaseChangeToken: UInt64 = 0

    private(set) var status: ModemPowerStatus
    var onStatusChanged: ((ModemPowerStatus) -> Void)?

    init(
        transport: ModemPowerTransport,
        policy: ModemPowerPolicy = .default,
        timing: ModemPowerTiming = .default,
        initialPhase: ModemPowerPhase = .active
    ) {
        self.transport = transport
        self.policy = policy
        self.timing = timing
        status = ModemPowerStatus(phase: initialPhase)
    }

    func setSleepPowerReductionEnabled(_ enabled: Bool) {
        policy.sleepPowerReductionEnabled = enabled
    }

    func handleSleep() {
        guard status.phase != .preparingForSleep,
              status.phase != .suspended else {
            Self.log.info(
                "[Power] Mac will sleep ignored phase=\(self.status.phase.rawValue, privacy: .public)"
            )
            return
        }

        phaseChangeToken &+= 1
        let token = phaseChangeToken
        wakeTask?.cancel()
        wakeTask = nil
        sleepTask?.cancel()

        status.phase = .preparingForSleep
        status.lastError = nil
        transport.setBackgroundWorkPaused(true)
        publishStatus()
        Self.log.notice("[Power] Mac will sleep")
        Self.log.notice("[Power] Recovery monitor paused")

        sleepTask = Task { [weak self] in
            await self?.runSleepSequence(token: token)
        }
    }

    func handleWake() {
        guard status.phase != .waking,
              status.phase != .active else {
            Self.log.info(
                "[Power] Mac did wake ignored phase=\(self.status.phase.rawValue, privacy: .public)"
            )
            return
        }

        phaseChangeToken &+= 1
        let token = phaseChangeToken
        sleepTask?.cancel()
        sleepTask = nil
        wakeTask?.cancel()

        status.phase = .waking
        status.wokeAt = .now
        status.modemRediscoverySeconds = nil
        status.atRestoreSeconds = nil
        status.internetRestoreSeconds = nil
        status.lastWakeCFUN = nil
        status.lastError = nil
        transport.setBackgroundWorkPaused(false)
        publishStatus()
        Self.log.notice("[Power] Mac did wake")
        Self.log.notice("[Power] Waiting for modem USB")

        wakeTask = Task { [weak self] in
            await self?.runWakeSequence(token: token)
        }
    }

    func cancelAllTransitions() {
        sleepTask?.cancel()
        wakeTask?.cancel()
        sleepTask = nil
        wakeTask = nil
        phaseChangeToken &+= 1
        transport.setBackgroundWorkPaused(false)
    }

    func recordInternetRestore(at date: Date = .now) {
        guard status.internetRestoreSeconds == nil,
              let wokeAt = status.wokeAt else {
            return
        }
        status.internetRestoreSeconds = date.timeIntervalSince(wokeAt)
        publishStatus()
        Self.log.notice(
            "[Power] Internet restored duration=\(self.status.internetRestoreSeconds ?? 0, format: .fixed(precision: 1))s"
        )
    }

    private func runSleepSequence(token: UInt64) async {
        guard !Task.isCancelled, token == phaseChangeToken else { return }
        guard policy.sleepPowerReductionEnabled else {
            Self.log.info("[Power] Sleep power reduction disabled")
            finishSleep(token: token)
            return
        }

        let query = await send(.queryCFUN, timeoutMS: timing.sleepCommandTimeoutMS)
        guard !Task.isCancelled, token == phaseChangeToken else { return }
        let currentCFUN = query.outcome == .ok
            ? ModemPowerResponseParser.currentCFUN(query.output)
            : nil
        Self.log.info(
            "[Power] Query CFUN reported=\(currentCFUN.map(String.init) ?? "unknown", privacy: .public) outcome=\(query.outcome.rawValue, privacy: .public)"
        )

        await configureQSCLKIfSupported(token: token)
        guard !Task.isCancelled, token == phaseChangeToken else { return }

        switch currentCFUN {
        case 1:
            let response = await send(
                .disableRadio,
                timeoutMS: timing.sleepCommandTimeoutMS
            )
            status.lastSleepCFUN = ModemPowerCFUNSnapshot(
                reported: 1,
                command: response.outcome,
                elapsedMS: response.elapsedMS
            )
            if response.outcome == .ok {
                Self.log.notice("[Power] CFUN 1 → 0")
            } else {
                Self.log.error("[Power] CFUN=0 failed, continuing sleep")
            }
        case 0:
            status.lastSleepCFUN = ModemPowerCFUNSnapshot(
                reported: 0,
                command: .ok,
                elapsedMS: query.elapsedMS
            )
            Self.log.info("[Power] CFUN already 0")
        default:
            status.lastSleepCFUN = ModemPowerCFUNSnapshot(
                reported: nil,
                command: query.outcome,
                elapsedMS: query.elapsedMS
            )
            Self.log.info("[Power] CFUN unknown; skipping CFUN=0")
        }

        finishSleep(token: token)
    }

    private func configureQSCLKIfSupported(token: UInt64) async {
        guard !Task.isCancelled, token == phaseChangeToken else { return }
        if status.supportsQSCLK == nil {
            let probe = await send(
                .testQSCLK,
                timeoutMS: timing.sleepCommandTimeoutMS
            )
            guard !Task.isCancelled, token == phaseChangeToken else { return }
            switch probe.outcome {
            case .ok:
                status.supportsQSCLK = ModemPowerResponseParser.supportsQSCLK(
                    probe.output
                )
            case .error, .unsupported:
                status.supportsQSCLK = false
            case .timeout, .notOpen:
                status.supportsQSCLK = nil
            }
        }

        guard status.supportsQSCLK == true else {
            Self.log.info("[Power] QSCLK unsupported or unknown; skipping")
            return
        }

        let query = await send(.queryQSCLK, timeoutMS: timing.sleepCommandTimeoutMS)
        guard query.outcome == .ok,
              !Task.isCancelled,
              token == phaseChangeToken else {
            status.lastQSCLKCommand = query.outcome
            return
        }
        let response = await send(
            .enableQSCLK,
            timeoutMS: timing.sleepCommandTimeoutMS
        )
        status.lastQSCLKCommand = response.outcome
        Self.log.info(
            "[Power] QSCLK=1 outcome=\(response.outcome.rawValue, privacy: .public)"
        )
    }

    private func finishSleep(token: UInt64) {
        guard token == phaseChangeToken else { return }
        status.phase = .suspended
        status.suspendedAt = .now
        sleepTask = nil
        publishStatus()
        Self.log.notice("[Power] Modem suspended")
    }

    private func runWakeSequence(token: UInt64) async {
        guard policy.sleepPowerReductionEnabled else {
            finishWake(token: token)
            return
        }

        let startedAt = Date.now
        let deadline = startedAt.addingTimeInterval(timing.wakeRediscoveryTimeout)
        var firstTransportResponseAt: Date?
        var atRestored = false
        var attempt = 0

        while Date.now < deadline {
            guard !Task.isCancelled, token == phaseChangeToken else { return }
            let response = await send(
                .attention,
                timeoutMS: timing.wakeCommandTimeoutMS
            )
            let now = Date.now
            if response.outcome != .notOpen, firstTransportResponseAt == nil {
                firstTransportResponseAt = now
            }
            if response.outcome == .ok {
                atRestored = true
                status.atRestoreSeconds = now.timeIntervalSince(startedAt)
                break
            }

            let remaining = deadline.timeIntervalSince(now)
            guard remaining > 0 else { break }
            let index = min(attempt, max(timing.wakeBackoff.count - 1, 0))
            let delay = timing.wakeBackoff.isEmpty
                ? min(0.5, remaining)
                : min(timing.wakeBackoff[index], remaining)
            attempt += 1
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }

        status.modemRediscoverySeconds = firstTransportResponseAt.map {
            $0.timeIntervalSince(startedAt)
        }

        guard atRestored else {
            status.lastError = "AT channel did not return after wake"
            Self.log.error(
                "[Power] AT channel not restored; Recovery Engine will retry"
            )
            finishWake(token: token)
            return
        }

        Self.log.notice("[Power] AT channel restored")
        let query = await send(.queryCFUN, timeoutMS: timing.wakeCommandTimeoutMS)
        let currentCFUN = query.outcome == .ok
            ? ModemPowerResponseParser.currentCFUN(query.output)
            : nil
        status.lastWakeCFUN = ModemPowerCFUNSnapshot(
            reported: currentCFUN,
            command: query.outcome,
            elapsedMS: query.elapsedMS
        )

        if currentCFUN == 0 {
            let response = await send(
                .enableRadio,
                timeoutMS: timing.wakeCommandTimeoutMS
            )
            status.lastWakeCFUN = ModemPowerCFUNSnapshot(
                reported: 0,
                command: response.outcome,
                elapsedMS: response.elapsedMS
            )
            Self.log.notice(
                "[Power] CFUN 0 → 1 outcome=\(response.outcome.rawValue, privacy: .public)"
            )
        }

        finishWake(token: token)
    }

    private func finishWake(token: UInt64) {
        guard token == phaseChangeToken else { return }
        status.phase = .active
        wakeTask = nil
        publishStatus()
        Self.log.notice("[Power] Starting Recovery Engine")
    }

    private func send(
        _ command: ModemPowerATCommand,
        timeoutMS: Int
    ) async -> ModemPowerCommandResponse {
        await withCheckedContinuation { continuation in
            transport.sendPowerManagementAT(command, timeoutMS: timeoutMS) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func publishStatus() {
        onStatusChanged?(status)
    }
}
