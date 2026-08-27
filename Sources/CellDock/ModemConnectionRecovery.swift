import Foundation

enum ModemRecoveryStage: String, Equatable, Sendable {
    case disconnected
    case usbDetected
    case checkingUSBProfile
    case waitingForAT
    case checkingSIM
    case registeringNetwork
    case establishingDataConnection
    case connected
    case recoveringUSB
    case recoveringAT
    case recoveringNetwork
    case waitingForModuleReboot
    case waitingForEnumeration
    case failed
}

enum ModemConnectionFailure: String, Equatable, Sendable {
    case moduleNotFound
    case usbEnumerationFailed
    case unsupportedUSBProfile
    case atUnavailable
    case simMissing
    case simLocked
    case simError
    case networkRegistrationFailed
    case dataInterfaceUnavailable
    case internetUnavailable
    case recoveryTimedOut
}

enum ModemDataConnectionStage: String, Equatable, Sendable {
    case waitingForInterface
    case waitingForCarrier
    case acquiringIP
    case verifyingInternet
}

enum ModemRecoveryTrigger: String, Equatable, Sendable {
    case coldPlug
    case usbReconnect
    case moduleReboot
    case systemWake
    case healthCheckFailure
    case manualRefresh
}

enum ModemRecoveryLevel: Int, Equatable, Sendable {
    case wait = 0
    case refresh = 1
    case softRecover = 2
    case userAction = 3
}

struct ModemRecoveryStatus: Equatable {
    var stage: ModemRecoveryStage = .disconnected
    var failure: ModemConnectionFailure?
    var dataStage: ModemDataConnectionStage?
    var recoveryTrigger: ModemRecoveryTrigger?
    var recoveryLevel: ModemRecoveryLevel = .wait
    var sessionID: UInt64 = 0
    var recoveryAttempts = 0
    var coalescedTriggers = 0
    var stageStartedAt = Date()
    var recoveryStartedAt: Date?
    var lastDisconnectAt: Date?
    var lastRecoveryAt: Date?
    var lastFailureStage: ModemRecoveryStage?
    var lastError: String?
    var lastSleepAt: Date?
    var lastWakeAt: Date?
    var recoveredAfterWake = false
    var lastRecoveryDuration: TimeInterval?

    /// Mac / modem power-management phase. Mirrors
    /// `ModemPowerPhase`. The default is `.active` so existing tests
    /// and consumers that do not opt into power management see no
    /// change in behavior.
    var powerPhase: ModemPowerPhase = .active
    /// Outcome of the most recent `AT+CFUN?` during Sleep. Optional
    /// so a manager that never runs still serializes cleanly.
    var sleepCFUNReported: Int?
    var sleepCFUNOutcome: ModemPowerCommandOutcome?
    /// Outcome of the most recent `AT+CFUN?` during Wake.
    var wakeCFUNReported: Int?
    var wakeCFUNOutcome: ModemPowerCommandOutcome?
    /// Whether the modem advertised `AT+QSCLK` support. Cached so
    /// the diagnostics report can tell the user.
    var supportsQSCLK: Bool?
    /// How long the Wake flow waited for the modem USB to come back.
    var modemRediscoverySeconds: TimeInterval?
    /// How long the Wake flow spent inside the AT restore sequence.
    var atRestoreSeconds: TimeInterval?
    /// How long after Wake the internet became reachable.
    var internetRestoreSeconds: TimeInterval?

    var isRecovering: Bool {
        recoveryStartedAt != nil && stage != .connected && stage != .failed
    }

    var needsUserAction: Bool {
        guard stage == .failed, let failure else { return false }
        switch failure {
        case .unsupportedUSBProfile, .simMissing, .simLocked, .simError:
            return true
        case .moduleNotFound, .usbEnumerationFailed, .atUnavailable,
             .networkRegistrationFailed, .dataInterfaceUnavailable,
             .internetUnavailable, .recoveryTimedOut:
            return false
        }
    }

    var userTitle: String {
        // Power-management phases take precedence over the connection
        // stage so the UI can tell the user "正在准备睡眠" / "模块已
        // 休眠" even while the connection stage is otherwise idle.
        switch powerPhase {
        case .preparingForSleep: return L10n.tr("正在准备睡眠…")
        case .suspended: return L10n.tr("模块已休眠")
        case .waking: return L10n.tr("正在恢复蜂窝连接")
        case .active: break
        }
        switch stage {
        case .disconnected: return L10n.tr("未连接")
        case .usbDetected: return L10n.tr("正在识别模块…")
        case .checkingUSBProfile: return L10n.tr("正在检查 USB 配置…")
        case .waitingForAT: return L10n.tr("正在等待 AT 接口…")
        case .checkingSIM: return L10n.tr("正在检测 SIM…")
        case .registeringNetwork: return L10n.tr("正在注册蜂窝网络…")
        case .establishingDataConnection: return L10n.tr("正在建立数据连接…")
        case .connected: return L10n.tr("已连接")
        case .recoveringUSB, .recoveringAT, .recoveringNetwork:
            return L10n.tr("正在恢复连接…")
        case .waitingForModuleReboot: return L10n.tr("模块正在重新连接…")
        case .waitingForEnumeration: return L10n.tr("正在等待 USB 枚举…")
        case .failed: return failureTitle
        }
    }

    var userDetail: String {
        switch powerPhase {
        case .preparingForSleep:
            return L10n.tr("Mac 合盖中，正在暂停模块的自动恢复…")
        case .suspended:
            if sleepCFUNReported == 0 || sleepCFUNOutcome == .ok {
                return L10n.tr("4G 模块已关闭 RF 与蜂窝功能，Mac 可继续睡眠")
            }
            return L10n.tr("自动恢复已暂停，模块低功耗状态未确认")
        case .waking:
            return L10n.tr("Mac 已开盖，正在重新唤醒模块并恢复蜂窝连接")
        case .active:
            break
        }
        switch stage {
        case .disconnected: return L10n.tr("插入模块后将自动连接")
        case .usbDetected: return L10n.tr("已检测到 USB 模块")
        case .checkingUSBProfile: return L10n.tr("只读取并验证当前配置，不会自动改写")
        case .waitingForAT: return L10n.tr("AT 接口可能仍在枚举，CellDock 将有限重试")
        case .checkingSIM: return L10n.tr("正在确认 SIM 卡状态")
        case .registeringNetwork: return L10n.tr("正在等待运营商完成注册")
        case .establishingDataConnection:
            switch dataStage {
            case .waitingForInterface: return L10n.tr("蜂窝已注册 · 等待网络接口")
            case .waitingForCarrier: return L10n.tr("蜂窝已注册 · 等待 ECM 载波")
            case .acquiringIP: return L10n.tr("蜂窝已注册 · 正在获取 IP")
            case .verifyingInternet: return L10n.tr("数据链路已建立 · 正在检测互联网")
            case nil: return L10n.tr("正在等待数据链路")
            }
        case .connected: return L10n.tr("网络正常")
        case .recoveringUSB: return L10n.tr("正在重新检测 USB 模块")
        case .recoveringAT: return L10n.tr("正在重新探测 AT 接口")
        case .recoveringNetwork: return L10n.tr("正在恢复 ECM 与 IP")
        case .waitingForModuleReboot: return L10n.tr("允许模块短暂消失并重新枚举")
        case .waitingForEnumeration: return L10n.tr("唤醒后为 USB 子系统预留恢复时间")
        case .failed: return lastError ?? failureDetail
        }
    }

    private var failureTitle: String {
        switch failure {
        case .moduleNotFound: return L10n.tr("未检测到模块")
        case .usbEnumerationFailed: return L10n.tr("USB 枚举失败")
        case .unsupportedUSBProfile: return L10n.tr("需要重新配置模块")
        case .atUnavailable: return L10n.tr("无法访问 AT 接口")
        case .simMissing: return L10n.tr("未检测到 SIM 卡")
        case .simLocked: return L10n.tr("SIM 卡已锁定")
        case .simError: return L10n.tr("SIM 状态异常")
        case .networkRegistrationFailed: return L10n.tr("蜂窝网络注册失败")
        case .dataInterfaceUnavailable: return L10n.tr("Mac 网络接口未就绪")
        case .internetUnavailable: return L10n.tr("蜂窝已连接 · 无互联网")
        case .recoveryTimedOut: return L10n.tr("连接恢复超时")
        case nil: return L10n.tr("连接异常")
        }
    }

    private var failureDetail: String {
        switch failure {
        case .unsupportedUSBProfile:
            return L10n.tr("自动恢复不会修改 USB / USBCFG，请由用户确认后处理")
        case .dataInterfaceUnavailable:
            return L10n.tr("模块已连接，但 Mac 网络接口未就绪")
        case .internetUnavailable:
            return L10n.tr("模块和 IP 已就绪，但互联网检测失败")
        case .recoveryTimedOut:
            return L10n.tr("有限自动恢复未成功，请检查模块连接")
        default:
            return failureTitle
        }
    }
}

struct ModemConnectionObservation: Equatable {
    var usbDetected: Bool
    var modem: ModemSnapshot
    var network: CellularNetworkStatus
    var dataConnectionExpected: Bool
    var internetReachable: Bool?

    init(
        usbDetected: Bool,
        modem: ModemSnapshot,
        network: CellularNetworkStatus = CellularNetworkStatus(),
        dataConnectionExpected: Bool = true,
        internetReachable: Bool? = nil
    ) {
        self.usbDetected = usbDetected
        self.modem = modem
        self.network = network
        self.dataConnectionExpected = dataConnectionExpected
        self.internetReachable = internetReachable
    }
}

struct ModemConnectionStateMachine {
    private(set) var status = ModemRecoveryStatus()
    private var hadConnectedSession = false
    private var isSleeping = false

    @discardableResult
    mutating func observe(
        _ observation: ModemConnectionObservation,
        now: Date = Date()
    ) -> ModemRecoveryStatus {
        let assessment = Self.assess(
            observation,
            previous: status,
            isSleeping: isSleeping,
            hadConnectedSession: hadConnectedSession,
            now: now
        )
        transition(
            to: assessment.stage,
            failure: assessment.failure,
            dataStage: assessment.dataStage,
            error: assessment.error,
            now: now
        )
        if status.stage == .connected {
            hadConnectedSession = true
            completeRecovery(now: now)
        }
        return status
    }

    @discardableResult
    mutating func beginRecovery(
        trigger: ModemRecoveryTrigger,
        now: Date = Date()
    ) -> UInt64 {
        if status.recoveryStartedAt != nil {
            status.coalescedTriggers += 1
            transitionForRecoveryTrigger(trigger, now: now)
            return status.sessionID
        }
        status.sessionID &+= 1
        status.recoveryTrigger = trigger
        status.recoveryLevel = .wait
        status.recoveryAttempts = 0
        status.coalescedTriggers = 0
        status.recoveryStartedAt = now
        status.lastError = nil
        transitionForRecoveryTrigger(trigger, now: now)
        return status.sessionID
    }

    mutating func recordRecoveryAttempt(level: ModemRecoveryLevel) {
        status.recoveryAttempts += 1
        status.recoveryLevel = level
    }

    mutating func markSleep(now: Date = Date()) {
        isSleeping = true
        status.lastSleepAt = now
    }

    @discardableResult
    mutating func markWake(now: Date = Date()) -> UInt64 {
        isSleeping = false
        status.lastWakeAt = now
        status.recoveredAfterWake = false
        return beginRecovery(trigger: .systemWake, now: now)
    }

    /// Update only the power-management phase without disturbing
    /// the recovery state machine. Used by `ModemRecoveryEngine`
    /// when it receives a phase change from `ModemPowerManager`.
    mutating func setPowerPhase(_ phase: ModemPowerPhase, now: Date = Date()) {
        status.powerPhase = phase
        if phase == .preparingForSleep { status.lastSleepAt = now }
        if phase == .waking { status.lastWakeAt = now }
    }

    /// Apply power-management diagnostics (CFUN outcomes,
    /// durations, QSCLK support) without changing the recovery
    /// stage or session ID. Idempotent: re-applying the same
    /// `ModemPowerStatus` is a no-op as far as `lastPublishedStatus`
    /// is concerned.
    mutating func applyPowerStatus(_ power: ModemPowerStatus) {
        status.powerPhase = power.phase
        status.supportsQSCLK = power.supportsQSCLK
        status.sleepCFUNReported = power.lastSleepCFUN?.reported
        status.sleepCFUNOutcome = power.lastSleepCFUN?.command
        status.wakeCFUNReported = power.lastWakeCFUN?.reported
        status.wakeCFUNOutcome = power.lastWakeCFUN?.command
        status.modemRediscoverySeconds = power.modemRediscoverySeconds
        status.atRestoreSeconds = power.atRestoreSeconds
        status.internetRestoreSeconds = power.internetRestoreSeconds
    }

    mutating func markDisconnected(now: Date = Date(), expectedReboot: Bool) {
        status.lastDisconnectAt = now
        if expectedReboot || hadConnectedSession {
            _ = beginRecovery(trigger: .moduleReboot, now: now)
        } else {
            transition(to: .disconnected, now: now)
        }
    }

    mutating func markRecoveryFailed(
        _ failure: ModemConnectionFailure = .recoveryTimedOut,
        now: Date = Date()
    ) {
        status.lastFailureStage = status.stage
        status.failure = failure
        status.lastError = nil
        status.stage = .failed
        status.stageStartedAt = now
        if let startedAt = status.recoveryStartedAt {
            status.lastRecoveryDuration = now.timeIntervalSince(startedAt)
        }
        status.recoveryStartedAt = nil
        status.recoveryLevel = .userAction
    }

    func isCurrentSession(_ sessionID: UInt64) -> Bool {
        status.sessionID == sessionID && status.recoveryStartedAt != nil
    }

    private mutating func completeRecovery(now: Date) {
        guard let startedAt = status.recoveryStartedAt else { return }
        status.lastRecoveryAt = now
        status.lastRecoveryDuration = now.timeIntervalSince(startedAt)
        status.recoveredAfterWake = status.recoveryTrigger == .systemWake
        status.recoveryStartedAt = nil
        status.recoveryTrigger = nil
        status.recoveryLevel = .wait
    }

    private mutating func transitionForRecoveryTrigger(
        _ trigger: ModemRecoveryTrigger,
        now: Date
    ) {
        switch trigger {
        case .systemWake:
            transition(to: .waitingForEnumeration, now: now)
        case .moduleReboot:
            transition(to: .waitingForModuleReboot, now: now)
        case .healthCheckFailure:
            transition(to: .recoveringNetwork, now: now)
        case .coldPlug, .usbReconnect, .manualRefresh:
            transition(to: .recoveringUSB, now: now)
        }
    }

    private mutating func transition(
        to stage: ModemRecoveryStage,
        failure: ModemConnectionFailure? = nil,
        dataStage: ModemDataConnectionStage? = nil,
        error: String? = nil,
        now: Date
    ) {
        let previousStage = status.stage
        if status.stage != stage || status.failure != failure || status.dataStage != dataStage {
            status.stageStartedAt = now
        }
        status.stage = stage
        status.failure = failure
        status.dataStage = dataStage
        status.lastError = error
        if stage == .failed {
            status.lastFailureStage = Self.failureStage(for: failure) ?? previousStage
            if status.needsUserAction { status.recoveryLevel = .userAction }
        }
    }

    private static func failureStage(
        for failure: ModemConnectionFailure?
    ) -> ModemRecoveryStage? {
        switch failure {
        case .moduleNotFound: return .disconnected
        case .usbEnumerationFailed: return .waitingForEnumeration
        case .unsupportedUSBProfile: return .checkingUSBProfile
        case .atUnavailable: return .waitingForAT
        case .simMissing, .simLocked, .simError: return .checkingSIM
        case .networkRegistrationFailed: return .registeringNetwork
        case .dataInterfaceUnavailable, .internetUnavailable: return .establishingDataConnection
        case .recoveryTimedOut, nil: return nil
        }
    }

    private struct Assessment {
        let stage: ModemRecoveryStage
        var failure: ModemConnectionFailure?
        var dataStage: ModemDataConnectionStage?
        var error: String?
    }

    private static func assess(
        _ observation: ModemConnectionObservation,
        previous: ModemRecoveryStatus,
        isSleeping: Bool,
        hadConnectedSession: Bool,
        now: Date
    ) -> Assessment {
        let modem = observation.modem
        if isSleeping {
            return Assessment(stage: .waitingForEnumeration)
        }

        if !observation.usbDetected && modem.state == .disconnected {
            if previous.recoveryTrigger == .systemWake {
                return Assessment(stage: .waitingForEnumeration)
            }
            if previous.recoveryTrigger == .moduleReboot || hadConnectedSession {
                return Assessment(stage: .waitingForModuleReboot)
            }
            return Assessment(stage: .disconnected)
        }

        switch modem.state {
        case .disconnected:
            return Assessment(stage: observation.usbDetected ? .waitingForAT : .disconnected)
        case .connecting:
            return Assessment(stage: modem.usbIdentity == nil ? .usbDetected : .waitingForAT)
        case .error:
            let failure: ModemConnectionFailure = modem.usbIdentity == nil
                ? .usbEnumerationFailed
                : .atUnavailable
            return Assessment(
                stage: .failed,
                failure: failure,
                error: modem.lastError
            )
        case .connected:
            break
        }

        guard modem.usbIdentity != nil else {
            return Assessment(stage: .checkingUSBProfile)
        }
        guard let usbConfiguration = modem.usbConfiguration else {
            return Assessment(stage: .checkingUSBProfile)
        }
        guard usbConfiguration.isRecognizedQDC507Profile else {
            return Assessment(stage: .failed, failure: .unsupportedUSBProfile)
        }
        guard modem.usbNetMode == 1 else {
            return Assessment(stage: .failed, failure: .dataInterfaceUnavailable)
        }

        switch modem.simState {
        case .unavailable, .initializing:
            return Assessment(stage: .checkingSIM)
        case .absent:
            return Assessment(stage: .failed, failure: .simMissing)
        case .pinRequired, .pukRequired:
            return Assessment(stage: .failed, failure: .simLocked)
        case .queryFailed:
            return Assessment(
                stage: .failed,
                failure: .simError,
                error: modem.simLastError
            )
        case .ready:
            break
        }

        switch modem.registrationState {
        case .registered, .roaming:
            break
        case .denied, .queryFailed:
            return Assessment(stage: .failed, failure: .networkRegistrationFailed)
        case .unavailable, .notRegistered, .searching, .unknown:
            if previous.stage == .registeringNetwork,
               now.timeIntervalSince(previous.stageStartedAt) >= ModemRecoveryPolicy.registrationTimeout {
                return Assessment(stage: .failed, failure: .networkRegistrationFailed)
            }
            return Assessment(stage: .registeringNetwork)
        }

        guard observation.dataConnectionExpected else {
            return Assessment(stage: .connected)
        }
        if let error = observation.network.lastError {
            return Assessment(
                stage: .failed,
                failure: .dataInterfaceUnavailable,
                error: error
            )
        }
        guard observation.network.isHardwarePresent else {
            return Assessment(
                stage: .establishingDataConnection,
                dataStage: .waitingForInterface
            )
        }
        guard observation.network.isLinkActive else {
            return Assessment(
                stage: .establishingDataConnection,
                dataStage: .waitingForCarrier
            )
        }
        guard observation.network.isActive,
              observation.network.ipv4Address != nil || observation.network.ipv6Address != nil else {
            return Assessment(
                stage: .establishingDataConnection,
                dataStage: .acquiringIP
            )
        }
        if observation.internetReachable == false {
            return Assessment(stage: .failed, failure: .internetUnavailable)
        }
        if observation.internetReachable == nil {
            return Assessment(
                stage: .establishingDataConnection,
                dataStage: .verifyingInternet
            )
        }
        return Assessment(stage: .connected)
    }
}

enum ModemRecoveryAction: String, Equatable, Sendable {
    case wait
    case refreshUSBInventory
    case readUSBProfile
    case probeAT
    case readSIM
    case readRegistration
    case refreshDataInterface
    case verifyInternet
    case restartModule
    case requestUserConfiguration
}

enum ModemRecoveryPolicy {
    static let atRetryDelays: [TimeInterval] = [0, 1, 2, 3, 5]
    static let wakeGracePeriod: TimeInterval = 2
    static let enumerationTimeout: TimeInterval = 45
    static let registrationTimeout: TimeInterval = 90
    static let dataConnectionTimeout: TimeInterval = 60
    static let normalHealthInterval: TimeInterval = 30
    static let internetProbeInterval: TimeInterval = 60
    static let maximumSoftRecoveryAttempts = 3

    static func timeout(for stage: ModemRecoveryStage) -> TimeInterval {
        switch stage {
        case .registeringNetwork: return registrationTimeout
        case .establishingDataConnection, .recoveringNetwork: return dataConnectionTimeout
        default: return enumerationTimeout
        }
    }

    static func actions(for level: ModemRecoveryLevel) -> [ModemRecoveryAction] {
        switch level {
        case .wait:
            return [.wait]
        case .refresh:
            return [
                .refreshUSBInventory, .readUSBProfile, .probeAT,
                .readSIM, .readRegistration, .refreshDataInterface,
                .verifyInternet,
            ]
        case .softRecover:
            return [.refreshDataInterface, .restartModule]
        case .userAction:
            return [.requestUserConfiguration]
        }
    }

    /// Commands issued by automatic detection are deliberately read-only.
    /// Persistent configuration writes are excluded and guarded by tests.
    static let automaticATCommands = [
        "AT",
        "AT+QCFG=\"USBCFG\"",
        "AT+QCFG=\"usbnet\"",
        "AT+CPIN?",
        "AT+CEREG?",
        "AT+CREG?",
        "AT+COPS?",
        "AT+QCSQ",
    ]

    static func changesPersistentConfiguration(_ rawCommand: String) -> Bool {
        let command = rawCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
        if command.hasPrefix("AT+QCFG=\"USBCFG\",") { return true }
        if command.hasPrefix("AT+QPRTPARA") { return true }
        if command.contains("FACTORY") || command.contains("RESTORE") { return true }
        return false
    }
}

enum ModemConnectionDiagnosticsReport {
    static func make(
        status: ModemRecoveryStatus,
        modem: ModemSnapshot,
        network: CellularNetworkStatus,
        appVersion: String,
        timestamp: Date = Date()
    ) -> String {
        let date = ISO8601DateFormatter()
        let profile: String
        switch modem.usbConfiguration?.usbProfile {
        case .djiOriginal: profile = "djiOriginal"
        case .cellDockCompatible: profile = "cellDockCompatible"
        case .unsupported: profile = "unsupported"
        case nil: profile = "unknown"
        }
        let uac = modem.usbConfiguration.map { $0.audioEnabled ? "enabled" : "disabled" }
            ?? "unknown"
        let atAvailable = modem.state == .connected ? "yes" : "no"
        let internet = network.internetReachable.map { $0 ? "yes" : "no" } ?? "unknown"
        let recoveryDuration = status.lastRecoveryDuration.map {
            String(format: "%.1fs", $0)
        } ?? "none"
        return """
        CellDock Diagnostics
        Timestamp: \(date.string(from: timestamp))
        App Version: \(appVersion)
        Connection State: \(status.stage.rawValue)
        Recovery State: \(status.isRecovering ? "active" : "idle")
        USB:
        - Device detected: \(modem.usbIdentity == nil ? "no" : "yes")
        - VID/PID: \(modem.usbIdentity ?? "unknown")
        - USB Profile: \(profile)
        - UAC: \(uac)
        - Network interface: \(network.bsdName ?? "none")
        - AT interface: \(modem.endpointDescription ?? "none")
        Modem:
        - AT available: \(atAvailable)
        - SIM: \(String(describing: modem.simState))
        - Operator: \(modem.operatorName ?? "unknown")
        - RAT: \(modem.accessTechnology ?? "unknown")
        - Registration: \(String(describing: modem.registrationState))
        - Signal dBm: \(modem.signalDBm.map(String.init) ?? "unknown")
        - RSRP/RSRQ/SINR: \(modem.signalDetail ?? "unknown")
        Network:
        - Interface: \(network.bsdName ?? "none")
        - IP: \(network.ipv4Address ?? network.ipv6Address ?? "none")
        - Route: \(network.ipv4Router ?? "none")
        - Internet reachable: \(internet)
        Recovery:
        - Last disconnect: \(status.lastDisconnectAt.map(date.string(from:)) ?? "none")
        - Last recovery: \(status.lastRecoveryAt.map(date.string(from:)) ?? "none")
        - Recovery attempts: \(status.recoveryAttempts)
        - Last failure stage: \(status.lastFailureStage?.rawValue ?? "none")
        - Last error: \(status.lastError ?? "none")
        Sleep/Wake:
        - Last sleep: \(status.lastSleepAt.map(date.string(from:)) ?? "none")
        - Last wake: \(status.lastWakeAt.map(date.string(from:)) ?? "none")
        - Recovered after wake: \(status.recoveredAfterWake ? "yes" : "no")
        - Recovery duration: \(recoveryDuration)
        Power Management:
        - Power phase: \(status.powerPhase.rawValue)
        - Sleep CFUN: \(status.sleepCFUNReported.map(String.init) ?? "unknown") outcome=\(status.sleepCFUNOutcome?.rawValue ?? "n/a")
        - Wake CFUN: \(status.wakeCFUNReported.map(String.init) ?? "unknown") outcome=\(status.wakeCFUNOutcome?.rawValue ?? "n/a")
        - QSCLK support: \(status.supportsQSCLK.map { $0 ? "yes" : "no" } ?? "unknown")
        - Modem rediscovery: \(status.modemRediscoverySeconds.map { String(format: "%.1fs", $0) } ?? "n/a")
        - AT restore: \(status.atRestoreSeconds.map { String(format: "%.1fs", $0) } ?? "n/a")
        - Internet restore: \(status.internetRestoreSeconds.map { String(format: "%.1fs", $0) } ?? "n/a")
        """
    }
}
