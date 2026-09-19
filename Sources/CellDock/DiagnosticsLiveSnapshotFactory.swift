import Foundation

@MainActor
enum DiagnosticsLiveSnapshotFactory {
    static func make(
        appState: AppState,
        microphonePermission: String,
        contactsPermission: String,
        notificationPermission: String,
        at generatedAt: Date = .now
    ) -> DiagnosticsSnapshot {
        let module = appState.currentCommunicationModule
            ?? appState.menuBarStatusModule
            ?? appState.cellularModules.first
        let modem = module?.modem ?? ModemSnapshot()
        let network = module?.network ?? CellularNetworkStatus()
        let euicc = appState.euiccSnapshot(for: module?.id)

        var source = DiagnosticsSourceData()
        source.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        source.appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        source.macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        source.architecture = architectureName
        source.appPath = Bundle.main.bundleURL.path

        source.moduleConnected = modem.isConnected
        source.moduleName = module?.localizedDisplayName
        source.usbIdentity = modem.usbIdentity
        source.firmwareVersion = modem.firmwareVersion
        source.atPortStatus = modem.isConnected
            ? (modem.endpointDescription ?? L10n.tr("已连接"))
            : L10n.tr("未连接")
        source.activeModule = module?.localizedDisplayName

        source.simStatus = simStatus(modem.simState)
        source.operatorName = modem.operatorName
        source.networkRegistration = registrationStatus(modem.registrationState)
        source.voiceRegistration = registrationStatus(modem.voiceRegistrationState)
        source.rat = modem.accessTechnology
        source.signal = modem.signalDBm.map { "\($0) dBm" }
        source.primaryTemperature = modem.temperature.primaryCelsius
        source.sensorTemperatures = modem.temperature.isAvailable
            ? modem.temperature.sensorValuesCelsius
            : []
        source.temperatureStatus = modem.temperature.localizedLevelText
        source.temperatureUpdatedAt = modem.temperature.lastSuccessfulAt
        source.iccid = modem.simICCID
        source.imsi = modem.simIMSI
        source.phoneNumber = modem.simPhoneNumber
        source.eid = euicc.eid

        source.ecmInterface = network.bsdName
        source.ecmStatus = networkStatus(network)
        source.ipv4Address = network.ipv4Address
        source.gateway = network.ipv4Router
        source.primaryRouteStatus = network.isSystemPrimary || network.isPrioritized
            ? L10n.tr("是")
            : L10n.tr("否")

        source.callStatus = callStatus(appState.call)
        source.smsStatus = smsStatus(appState: appState, module: module)
        source.esimStatus = esimStatus(euicc.cardKind)
        source.socksStatus = socksStatus(appState.socksProxyController)
        source.voWiFiStatus = voWiFiStatus(
            moduleID: module?.id,
            controller: appState.voWiFiController
        )
        source.audioStatus = audioStatus(call: appState.call, modem: modem)
        source.pollingStatus = pollingStatus(call: appState.call, modem: modem)

        source.microphonePermission = microphonePermission
        source.contactsPermission = contactsPermission
        source.notificationPermission = notificationPermission
        source.recentErrors = [
            modem.lastError,
            modem.simLastError,
            network.lastError,
            euicc.lastError,
            appState.call.lastError
        ].compactMap { $0 }

        return DiagnosticsSnapshotBuilder.build(from: source, at: generatedAt)
    }

    private static var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        L10n.tr("未知")
        #endif
    }

    private static func simStatus(_ state: SIMState) -> String {
        switch state {
        case .unavailable: L10n.tr("不可用")
        case .initializing: L10n.tr("正在读取 SIM")
        case .absent: L10n.tr("未插入 SIM")
        case .pinRequired: L10n.tr("需要 SIM PIN")
        case .pukRequired: L10n.tr("需要 SIM PUK")
        case .ready: L10n.tr("已就绪")
        case .queryFailed: L10n.tr("查询失败")
        }
    }

    private static func registrationStatus(_ state: CellularRegistrationState) -> String {
        switch state {
        case .unavailable: L10n.tr("不可用")
        case .notRegistered: L10n.tr("未注册")
        case .registered: L10n.tr("已注册")
        case .searching: L10n.tr("正在搜索")
        case .denied: L10n.tr("被拒绝")
        case .unknown: L10n.tr("未知")
        case .roaming: L10n.tr("漫游")
        case .queryFailed: L10n.tr("查询失败")
        }
    }

    private static func networkStatus(_ network: CellularNetworkStatus) -> String {
        if !network.isHardwarePresent { return L10n.tr("不可用") }
        if network.isActive && network.isLinkActive { return L10n.tr("已启用并连接") }
        if network.isEnabled { return L10n.tr("已启用，链路未就绪") }
        return L10n.tr("未启用")
    }

    private static func callStatus(_ call: CallSnapshot) -> String {
        switch call.phase {
        case .unavailable: L10n.tr("不可用")
        case .idle: L10n.tr("空闲")
        case .incoming: L10n.tr("来电")
        case .dialing: L10n.tr("正在拨号")
        case .alerting: L10n.tr("正在振铃")
        case .active: L10n.tr("通话中")
        case .ending: L10n.tr("正在挂断")
        case .recovering: L10n.tr("正在恢复")
        case .error: L10n.tr("异常")
        }
    }

    private static func smsStatus(
        appState: AppState,
        module: CellularModuleSummary?
    ) -> String {
        guard let module, module.isCommunicationEligible else { return L10n.tr("不可用") }
        return appState.isSendingMessage(via: module.id)
            ? L10n.tr("正在发送")
            : L10n.tr("可用")
    }

    private static func esimStatus(_ kind: SubscriberCardKind) -> String {
        switch kind {
        case .unknown: L10n.tr("未知")
        case .probing: L10n.tr("检测中")
        case .physicalSIM: L10n.tr("实体 SIM")
        case .eUICC: L10n.tr("可用")
        case .unsupported: L10n.tr("不支持")
        case .failed: L10n.tr("检测失败")
        }
    }

    private static func socksStatus(_ controller: SOCKSProxyController) -> String {
        let configurations = controller.store.configurations
        guard !configurations.isEmpty else { return L10n.tr("未配置") }
        let running = controller.runtimeStates.values.count { state in
            if case .running = state { return true }
            return false
        }
        return L10n.tr("%lld 个运行中 / %lld 个配置", Int64(running), Int64(configurations.count))
    }

    private static func voWiFiStatus(
        moduleID: CellularModuleID?,
        controller: VoWiFiController
    ) -> String {
        guard let moduleID, let state = controller.states[moduleID] else {
            return L10n.tr("未运行")
        }
        switch state {
        case .checking: return L10n.tr("检测中")
        case .unsupported: return L10n.tr("不支持")
        case .stopped: return L10n.tr("未运行")
        case .egressUnavailable: return L10n.tr("网络出口不可用")
        case .starting: return L10n.tr("正在启动")
        case .authenticatingSIM: return L10n.tr("正在进行 SIM 鉴权")
        case .establishingTunnel: return L10n.tr("正在建立隧道")
        case .registeringIMS: return L10n.tr("正在注册 IMS")
        case .registered: return L10n.tr("已注册")
        case .desynchronized: return L10n.tr("状态不同步")
        case .failed: return L10n.tr("异常")
        }
    }

    private static func audioStatus(call: CallSnapshot, modem: ModemSnapshot) -> String {
        if call.audioActive { return L10n.tr("通话音频已启用") }
        switch modem.voiceCapability {
        case .supported: return L10n.tr("可用，当前未通话")
        case .unsupported: return L10n.tr("不支持")
        case .probeFailed, .initializationFailed: return L10n.tr("检测失败")
        case .unknown, .probing: return L10n.tr("尚未确认")
        }
    }

    private static func pollingStatus(call: CallSnapshot, modem: ModemSnapshot) -> String {
        guard modem.isConnected else { return L10n.tr("已停止（模组未连接）") }
        if call.hasCall { return L10n.tr("通话期间已暂停") }
        return L10n.tr("运行中（复用现有模组轮询）")
    }
}
