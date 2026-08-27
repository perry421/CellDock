import AppKit
import Foundation
import OSLog

@MainActor
final class ModemRecoveryEngine {
    var onStatus: ((ModemRecoveryStatus) -> Void)?
    var onRequestRefresh: (() -> Void)?
    var onRequestSoftRecovery: ((ModemRecoveryStage) -> Void)?
    var onSystemWillSleep: (() -> Void)?
    var onSystemDidWake: (() -> Void)?

    private static let log = Logger(
        subsystem: "app.celldock.mac",
        category: "Recovery"
    )

    private var machine = ModemConnectionStateMachine()
    private var observation = ModemConnectionObservation(
        usbDetected: false,
        modem: ModemSnapshot()
    )
    private var recoveryTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var started = false
    private var lastPublishedStatus: ModemRecoveryStatus?

    var status: ModemRecoveryStatus { machine.status }
    var isRunning: Bool { started }
    var isHealthMonitorRunning: Bool { healthTask != nil }
    var isRecoveryOperationRunning: Bool { recoveryTask != nil }

    func start() {
        guard !started else { return }
        started = true
        installSleepWakeObservers()
        startHealthMonitor()
        publishIfNeeded()
    }

    func stop() {
        guard started else { return }
        started = false
        recoveryTask?.cancel()
        recoveryTask = nil
        healthTask?.cancel()
        healthTask = nil
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
    }

    func updateUSBDetected(_ detected: Bool) {
        let wasDetected = observation.usbDetected
        observation.usbDetected = detected
        guard machine.status.powerPhase == .active else { return }

        if detected && !wasDetected {
            Self.log.info("[Recovery] USB modem detected")
            beginRecovery(
                trigger: machine.status.lastDisconnectAt == nil
                    ? .coldPlug
                    : .usbReconnect
            )
        } else if !detected && wasDetected {
            let expectedReboot = observation.modem.lifecyclePhase == .restarting ||
                machine.status.stage == .connected
            machine.markDisconnected(now: .now, expectedReboot: expectedReboot)
            Self.log.notice(
                "[Recovery] USB modem disappeared expectedReboot=\(expectedReboot)"
            )
            publishIfNeeded()
            if expectedReboot { ensureRecoveryTask() }
        }
        evaluate()
    }

    func updateModem(_ modem: ModemSnapshot) {
        let previous = observation.modem
        observation.modem = modem
        guard machine.status.powerPhase == .active else { return }
        if modem.lifecyclePhase == .restarting && previous.lifecyclePhase != .restarting {
            beginRecovery(trigger: .moduleReboot)
        } else if modem.state != .connected,
                  previous.state == .connected,
                  observation.usbDetected {
            beginRecovery(trigger: .healthCheckFailure)
        } else if modem.state != .disconnected,
                  previous.state == .disconnected,
                  machine.status.recoveryStartedAt == nil {
            beginRecovery(trigger: machine.status.lastDisconnectAt == nil ? .coldPlug : .usbReconnect)
        }
        evaluate()
    }

    func updateNetwork(_ network: CellularNetworkStatus) {
        let wasHealthy = observation.network.isActive &&
            observation.network.internetReachable != false
        observation.network = network
        observation.internetReachable = network.internetReachable
        guard machine.status.powerPhase == .active else { return }

        let isHealthy = network.isActive && network.internetReachable != false
        if wasHealthy && !isHealthy && observation.modem.isConnected {
            beginRecovery(trigger: .healthCheckFailure)
        }
        evaluate()
    }

    func setDataConnectionExpected(_ expected: Bool) {
        guard observation.dataConnectionExpected != expected else { return }
        observation.dataConnectionExpected = expected
        evaluate()
    }

    func requestManualRefresh() {
        guard machine.status.powerPhase == .active else { return }
        beginRecovery(trigger: .manualRefresh)
    }

    private func evaluate(now: Date = Date()) {
        let previous = machine.status
        let next = machine.observe(observation, now: now)
        if next.stage == .connected {
            recoveryTask?.cancel()
            recoveryTask = nil
            Self.log.info("[Recovery] Connection healthy")
        } else if next.needsUserAction {
            recoveryTask?.cancel()
            recoveryTask = nil
        } else if next.stage == .failed,
                  next.failure == .dataInterfaceUnavailable ||
                    next.failure == .internetUnavailable {
            beginRecovery(trigger: .healthCheckFailure)
        }
        if previous.stage != next.stage {
            let duration = now.timeIntervalSince(previous.stageStartedAt)
            let error = next.lastError ?? next.failure?.rawValue ?? "none"
            Self.log.info(
                "[Recovery] stage=\(next.stage.rawValue, privacy: .public) attempt=\(next.recoveryAttempts) previousDuration=\(duration, format: .fixed(precision: 1))s error=\(error, privacy: .public)"
            )
        }
        publishIfNeeded()
    }

    private func beginRecovery(trigger: ModemRecoveryTrigger) {
        guard machine.status.powerPhase == .active else { return }
        let hadActiveSession = machine.status.recoveryStartedAt != nil
        let sessionID = machine.beginRecovery(trigger: trigger)
        if hadActiveSession {
            Self.log.info(
                "[Recovery] Coalesced trigger=\(trigger.rawValue, privacy: .public) session=\(sessionID)"
            )
        } else {
            Self.log.notice(
                "[Recovery] Started trigger=\(trigger.rawValue, privacy: .public) session=\(sessionID)"
            )
        }
        publishIfNeeded()
        ensureRecoveryTask()
    }

    private func ensureRecoveryTask() {
        guard recoveryTask == nil,
              let startedAt = machine.status.recoveryStartedAt else { return }
        let sessionID = machine.status.sessionID
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            if self.machine.status.recoveryTrigger == .systemWake {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(ModemRecoveryPolicy.wakeGracePeriod * 1_000_000_000)
                    )
                } catch { return }
            }

            for delay in ModemRecoveryPolicy.atRetryDelays {
                if delay > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch { return }
                }
                guard self.started, self.machine.isCurrentSession(sessionID) else { return }
                self.machine.recordRecoveryAttempt(level: .refresh)
                self.publishIfNeeded()
                self.onRequestRefresh?()
            }

            for _ in 0 ..< ModemRecoveryPolicy.maximumSoftRecoveryAttempts {
                guard self.started, self.machine.isCurrentSession(sessionID) else { return }
                self.machine.recordRecoveryAttempt(level: .softRecover)
                let stage = self.machine.status.stage
                self.publishIfNeeded()
                self.onRequestSoftRecovery?(stage)
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch { return }
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            let timeout = ModemRecoveryPolicy.timeout(for: self.machine.status.stage)
            if elapsed < timeout {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            (timeout - elapsed) * 1_000_000_000
                        )
                    )
                } catch { return }
            }
            guard self.machine.isCurrentSession(sessionID) else { return }
            let failure: ModemConnectionFailure = switch self.machine.status.stage {
            case .waitingForAT, .recoveringAT: .atUnavailable
            case .waitingForEnumeration, .recoveringUSB:
                self.observation.usbDetected ? .usbEnumerationFailed : .moduleNotFound
            case .registeringNetwork: .networkRegistrationFailed
            case .establishingDataConnection, .recoveringNetwork:
                self.observation.network.isActive &&
                    self.observation.internetReachable == false
                    ? .internetUnavailable
                    : .dataInterfaceUnavailable
            default: .recoveryTimedOut
            }
            self.machine.markRecoveryFailed(failure)
            Self.log.error(
                "[Recovery] stage=timeout attempt=\(self.machine.status.recoveryAttempts) duration=\(Date().timeIntervalSince(startedAt), format: .fixed(precision: 1))s underlying=\(failure.rawValue, privacy: .public)"
            )
            self.recoveryTask = nil
            self.publishIfNeeded()
        }
    }

    private func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            ModemRecoveryPolicy.normalHealthInterval * 1_000_000_000
                        )
                    )
                } catch { return }
                guard let self, self.started else { return }
                guard self.machine.status.powerPhase == .active,
                      self.machine.status.stage == .connected else {
                    continue
                }
                self.onRequestRefresh?()
            }
        }
    }

    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemWillSleep() }
        })
        notificationTokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemDidWake() }
        })
    }

    func handleSystemWillSleep() {
        guard machine.status.powerPhase == .active else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        healthTask?.cancel()
        healthTask = nil
        machine.markSleep()
        machine.setPowerPhase(.preparingForSleep)
        publishIfNeeded()
        Self.log.notice("[Recovery] macOS sleep detected")
        onSystemWillSleep?()
    }

    func handleSystemDidWake() {
        guard machine.status.powerPhase == .preparingForSleep ||
            machine.status.powerPhase == .suspended else {
            return
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        healthTask?.cancel()
        healthTask = nil
        let sessionID = machine.markWake()
        machine.setPowerPhase(.waking)
        publishIfNeeded()
        Self.log.notice("[Recovery] macOS wake detected session=\(sessionID)")
        onSystemDidWake?()
    }

    func applyPowerStatus(_ power: ModemPowerStatus) {
        let previousPhase = machine.status.powerPhase
        machine.applyPowerStatus(power)
        if previousPhase != power.phase {
            Self.log.notice(
                "[Recovery] power phase=\(power.phase.rawValue, privacy: .public)"
            )
        }

        if power.phase == .active, previousPhase == .waking {
            startHealthMonitor()
            evaluate()
            ensureRecoveryTask()
            Self.log.notice("[Recovery] post-wake recovery resumed")
        }
        publishIfNeeded()
    }

    private func publishIfNeeded() {
        let value = machine.status
        guard value != lastPublishedStatus else { return }
        lastPublishedStatus = value
        onStatus?(value)
    }
}
