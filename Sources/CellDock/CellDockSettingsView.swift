import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct CellDockSettingsView: View {
    private enum Category: String, CaseIterable {
        case general = "通用"
        case communications = "蜂窝与通信"
        case permissions = "通知与权限"
        case updates = "软件更新"

        var title: String { L10n.tr(rawValue) }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .communications: return "antenna.radiowaves.left.and.right"
            case .permissions: return "bell.badge"
            case .updates: return "arrow.triangle.2.circlepath"
            }
        }

        var detail: String {
            switch self {
            case .general: return L10n.tr("启动、外观与菜单栏行为")
            case .communications: return L10n.tr("查看模块状态并管理通话与短信处理")
            case .permissions: return L10n.tr("检查 CellDock 的系统访问权限")
            case .updates: return L10n.tr("检查版本并选择更新频道")
            }
        }

        var sidebarDetail: String {
            switch self {
            case .general: return L10n.tr("外观、语言与启动")
            case .communications: return L10n.tr("声音、通话与短信")
            case .permissions: return L10n.tr("通知与系统访问权限")
            case .updates: return L10n.tr("版本与更新频道")
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var contacts = SystemContactStore.shared
    @ObservedObject private var alertSounds = AlertSoundService.shared
    @ObservedObject private var languageController = AppLanguageController.shared
    @ObservedObject private var updaterManager = UpdaterManager.shared
    @Binding private var sidebarWidth: CGFloat
    private let focusFirstItemRequest: Bool
    private let didHandleFocusFirstItemRequest: () -> Void
    @AppStorage(AppAppearanceMode.defaultsKey) private var appearanceModeRawValue =
        AppAppearanceMode.system.rawValue
    @AppStorage("CallRecordingConsentAcknowledged.v1") private var recordingConsent = false
    @State private var selectedCategory: Category = .general
    @State private var didResolveInitialCategory = false
    @State private var isConfirmingVerificationAutoDelete = false
    @State private var isConfirmingAutomaticRecording = false
    @State private var isPresentingSMSReceptionList = false
    @State private var soundImportError: String?
    @State private var microphoneAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .audio)
    @FocusState private var listFocused: Bool

    init(
        sidebarWidth: Binding<CGFloat> = .constant(CommunicationUI.sidebarWidth),
        focusFirstItemRequest: Bool = false,
        didHandleFocusFirstItemRequest: @escaping () -> Void = {}
    ) {
        _sidebarWidth = sidebarWidth
        self.focusFirstItemRequest = focusFirstItemRequest
        self.didHandleFocusFirstItemRequest = didHandleFocusFirstItemRequest
    }

    var body: some View {
        ResizableCommunicationSplit(sidebarWidth: $sidebarWidth) {
            settingsSidebar
        } detail: {
            settingsContent
        }
        .frame(
            minWidth: 560,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .onAppear {
            refreshSettingsState()
            resolveInitialSettingsCategoryIfNeeded()
            handleFocusFirstItemRequest()
        }
        .onChange(of: focusFirstItemRequest) { _, requested in
            if requested { handleFocusFirstItemRequest() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            refreshSystemPermissionState()
        }
        .alert("开启验证码自动删除？", isPresented: $isConfirmingVerificationAutoDelete) {
            Button("取消", role: .cancel) { }
            Button("开启", role: .destructive) {
                appState.setAutoDeleteReadVerificationMessages(true)
            }
        } message: {
            Text("验证码短信被标记已读 30 分钟后，将从模块/SIM 和本地永久删除，无法撤销。")
        }
        .alert("开启通话自动录音？", isPresented: $isConfirmingAutomaticRecording) {
            Button("取消", role: .cancel) { }
            Button("同意并开启") {
                recordingConsent = true
                appState.setAutomaticallyRecordCalls(true)
            }
        } message: {
            Text("通话接通后会自动录制双方的声音。请先确认已取得通话参与者同意，并遵守所在地法律法规。录音仅保存在这台 Mac。")
        }
        .alert(
            "无法使用音频文件",
            isPresented: Binding(
                get: { soundImportError != nil },
                set: { if !$0 { soundImportError = nil } }
            )
        ) {
            Button("好", role: .cancel) { soundImportError = nil }
        } message: {
            Text(soundImportError ?? L10n.tr("请选择其他音频文件。"))
        }
    }

    private var settingsSidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.tr("设置"))
                        .font(.title2.bold())
                        .padding(.horizontal, 14)

                    settingsSidebarGroup(
                        L10n.tr("偏好设置"),
                        categories: [.general, .communications]
                    )
                    settingsSidebarGroup(
                        L10n.tr("系统"),
                        categories: [.permissions, .updates]
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .communicationSidebarScrollEdgeEffect()

            Text(verbatim: "CellDock · \(updaterManager.currentVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .accessibilityLabel("CellDock \(updaterManager.currentVersion)")
        }
        .communicationInitialListFocus($listFocused)
        .communicationSidebarColumnStyle()
    }

    private func settingsSidebarGroup(
        _ title: String,
        categories: [Category]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            VStack(spacing: 2) {
                ForEach(categories, id: \.self) { category in
                    settingsSidebarRow(category)
                }
            }
        }
    }

    private func settingsSidebarRow(_ category: Category) -> some View {
        let isSelected = selectedCategory == category

        return Button {
            selectSettingsCategory(category)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    Text(category.sidebarDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if category == .permissions, allSettingsPermissionsAllowed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.7)
                    }
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectSettingsCategory(_ category: Category) {
        didResolveInitialCategory = true
        selectedCategory = category
        if category == .communications {
            appState.refresh()
        } else if category == .permissions {
            refreshSystemPermissionState()
        }
    }

    private func handleFocusFirstItemRequest() {
        guard focusFirstItemRequest else { return }
        resolveInitialSettingsCategoryIfNeeded()
        didHandleFocusFirstItemRequest()
        listFocused = false
        DispatchQueue.main.async {
            listFocused = true
        }
    }

    private func resolveInitialSettingsCategoryIfNeeded() {
        guard !didResolveInitialCategory else { return }
        selectedCategory = .general
        didResolveInitialCategory = true
    }

    private var settingsContent: some View {
        ScrollView {
            AdaptiveGlassContainer(spacing: 16) {
                VStack(alignment: .leading, spacing: 20) {
                    settingsHeader
                    settingsCards
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .communicationDetailColumnStyle()
    }

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedCategory.title)
                .font(.largeTitle.bold())
            Text(selectedCategory.detail)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var settingsCards: some View {
        switch selectedCategory {
        case .general:
            generalSettings
        case .communications:
            communicationSettings
        case .permissions:
            permissionSettings
        case .updates:
            updateSettings
        }
    }

    private var usbModeSettingsSection: some View {
        settingsSection(title: L10n.tr("DJI 4G 模块 · USB 模式")) {
            VStack(alignment: .leading, spacing: 12) {
                switch appState.usbModeState {
                case .mac:
                    usbModeStatusRow(
                        title: L10n.tr("Mac / CellDock 模式"),
                        status: L10n.tr("UAC=1"),
                        icon: "desktopcomputer"
                    )
                    mainUSBModeAction(
                        title: L10n.tr("Prepare for iPhone"),
                        systemImage: "iphone.badge.minus",
                        action: { appState.prepareForiPhone() }
                    )
                    usbConfigurationFooter(switchHint: L10n.tr("切换到 Mobile 会关闭 UAC，断开前请确认已选好 iPhone 目标。"))
                case .mobile:
                    usbModeStatusRow(
                        title: L10n.tr("iPhone / Mobile 模式"),
                        status: L10n.tr("UAC=0"),
                        icon: "iphone"
                    )
                    mainUSBModeAction(
                        title: L10n.tr("Switch to Mac / CellDock"),
                        systemImage: "desktopcomputer.arrow.left",
                        action: { appState.switchToMacUSBMode() }
                    )
                    inlineCallout(
                        L10n.tr("已为 iPhone 关闭 UAC，可安全拔下并接入 iPhone。"),
                        systemImage: "checkmark.circle",
                        color: .green
                    )
                    usbConfigurationFooter(switchHint: L10n.tr("切换到 Mac 模式会重新开启 UAC。"))
                case .switching:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在切换 USB 模式…"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                case .unsupported:
                    usbModeStatusRow(
                        title: L10n.tr("USB 模式未知"),
                        status: L10n.tr("配置不支持"),
                        icon: "exclamationmark.triangle.fill"
                    )
                    inlineCallout(
                        L10n.tr("未识别到受支持的 DJI 4G 模块配置，不会自动修改模块。"),
                        systemImage: "prohibited",
                        color: .red
                    )
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在读取 USB 配置…"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                case let .error(message):
                    usbModeStatusRow(
                        title: L10n.tr("USB 模式不可用"),
                        status: L10n.tr("未连接"),
                        icon: "cable.connector.slash"
                    )
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    @State private var isUSBModeTestPresented = false

    /// Minimal live-hardware test surface for the UAC/audio ON↔OFF switch.
    private var usbModeTestSection: some View {
        settingsSection(title: L10n.tr("USB 模式实机测试")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("通过已验证的 USBCFG 链路执行 Audio ON/OFF 切换；写入前自动备份，回读校验失败自动回滚。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    isUSBModeTestPresented = true
                } label: {
                    Label("打开 USB 模式实机测试", systemImage: "wrench.and.screwdriver")
                }
                .adaptiveGlassButton()
            }
            .padding(16)
        }
        .sheet(isPresented: $isUSBModeTestPresented) {
            USBModeTestView()
                .environmentObject(appState)
        }
    }

    @ViewBuilder
    private func usbModeStatusRow(title: String, status: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Spacer()
            Text(status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func mainUSBModeAction(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
    }

    @ViewBuilder
    private func usbConfigurationFooter(switchHint: String) -> some View {
        if let usbConfiguration = appState.modem.usbConfiguration {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    format: "USB VID: %04X · PID: %04X",
                    usbConfiguration.vendorID,
                    usbConfiguration.productID
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(switchHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var generalSettings: some View {
        VStack(spacing: 16) {
            usbModeSettingsSection

            usbModeTestSection

            settingsSection(title: L10n.tr("隐私保护")) {
                VStack(spacing: 12) {
                    settingRow(
                        title: L10n.tr("演示隐私保护"),
                        status: appState.isPresentationPrivacyEnabled ? L10n.tr("已开启") : nil,
                        statusColor: .green,
                        detail: L10n.tr("在界面与系统通知中隐藏联系人、电话号码、短信内容和验证码")
                    ) {
                        Toggle("演示隐私保护", isOn: Binding(
                            get: { appState.isPresentationPrivacyEnabled },
                            set: { appState.setPresentationPrivacyEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }

                    if appState.isPresentationPrivacyEnabled {
                        inlineCallout(
                            L10n.tr("原始数据不会被修改；复制、导出、在访达中显示和编辑联系人暂不可用。"),
                            systemImage: "checkmark.shield.fill",
                            color: .green
                        )
                    }
                }
                .padding(16)
            }

            settingsSection(title: L10n.tr("外观与语言")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: L10n.tr("主题模式")
                    ) {
                        Picker("主题模式", selection: appearanceModeBinding) {
                            ForEach(AppAppearanceMode.allCases) { mode in
                                Text(mode.title)
                                    .lineLimit(1)
                                    .tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 276)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("应用语言"),
                        detail: L10n.tr("切换后立即应用，无需重新启动")
                    ) {
                        Picker("应用语言", selection: languageBinding) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(verbatim: language.nativeName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 142)
                    }
                    .padding(16)
                }
            }

            settingsSection(title: L10n.tr("启动与菜单栏")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: L10n.tr("登录时启动"),
                        detail: launchAtLoginDetail
                    ) {
                        if appState.isChangingLaunchAtLogin {
                            ProgressView().controlSize(.small)
                        } else {
                            Toggle("登录时启动", isOn: Binding(
                                get: { appState.launchAtLoginStatus.isRegistered },
                                set: { appState.setLaunchAtLogin($0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.adaptiveGlass)
                            .disabled(appState.launchAtLoginStatus == .unavailable)
                        }
                    }
                    .padding(16)

                    if let error = appState.launchAtLoginError {
                        inlineMessage(
                            error,
                            systemImage: "exclamationmark.triangle.fill",
                            color: .red
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                    }

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("后台连接恢复"),
                        detail: appState.isBackgroundRecoveryServiceRunning
                            ? L10n.tr("关闭窗口后继续监测 USB、AT、SIM 与蜂窝数据")
                            : L10n.tr("恢复服务未运行")
                    ) {
                        Label(
                            appState.isBackgroundRecoveryServiceRunning
                                ? L10n.tr("运行中")
                                : L10n.tr("已停止"),
                            systemImage: appState.isBackgroundRecoveryServiceRunning
                                ? "checkmark.circle.fill"
                                : "xmark.circle"
                        )
                        .foregroundStyle(
                            appState.isBackgroundRecoveryServiceRunning ? .green : .secondary
                        )
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("未连接模块时隐藏菜单栏图标"),
                        detail: appState.hideMenuBarIconWhenDisconnected
                            ? L10n.tr("重新连接模块后自动显示")
                            : L10n.tr("模块断开后继续显示状态图标")
                    ) {
                        Toggle("未连接模块时隐藏菜单栏图标", isOn: Binding(
                            get: { appState.hideMenuBarIconWhenDisconnected },
                            set: { appState.setHideMenuBarIconWhenDisconnected($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("Mac 睡眠时降低 4G 模块功耗"),
                        detail: appState.sleepPowerReductionEnabled
                            ? L10n.tr("合盖时将模块切到低功耗，开盖后自动恢复 4G")
                            : L10n.tr("合盖时模块保持常驻耗电，仅在明确禁用时选择")
                    ) {
                        Toggle("Mac 睡眠时降低 4G 模块功耗", isOn: Binding(
                            get: { appState.sleepPowerReductionEnabled },
                            set: { appState.setSleepPowerReductionEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }
                    .padding(16)
                }
            }

            settingsSection(title: L10n.tr("应用操作")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: L10n.tr("复制连接诊断报告"),
                        detail: L10n.tr("不包含 ICCID、IMSI、IMEI 或电话号码")
                    ) {
                        Button {
                            appState.copyModemConnectionDiagnostics()
                        } label: {
                            Label("复制诊断报告", systemImage: "doc.on.doc")
                        }
                        .adaptiveGlassButton()
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("完全退出 CellDock"),
                        detail: L10n.tr("关闭窗口不会停止短信、来电和模块监测")
                    ) {
                        Button(role: .destructive) {
                            appState.quit()
                        } label: {
                            Label("完全退出 CellDock", systemImage: "power")
                        }
                        .adaptiveGlassButton()
                        .tint(.red)
                        .help("完全退出 CellDock，并停止后台短信、来电和模块监测")
                    }
                    .padding(16)
                }
            }
        }
    }

    private var updateSettings: some View {
        VStack(spacing: 16) {
            settingsSection(title: L10n.tr("软件更新")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: L10n.tr("自动检查更新"),
                        detail: updaterManager.currentVersion
                    ) {
                        Toggle("自动检查更新", isOn: Binding(
                            get: { updaterManager.automaticallyChecksForUpdates },
                            set: { updaterManager.automaticallyChecksForUpdates = $0 }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("更新频道"),
                        detail: updaterManager.channel == .stable
                            ? L10n.tr("仅接收经过验证的正式版本")
                            : L10n.tr("提前体验新功能，可能不够稳定")
                    ) {
                        Picker("更新频道", selection: $updaterManager.channel) {
                            ForEach(UpdateChannel.allCases) { channel in
                                Text(channel.title).tag(channel)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("立即检查"),
                        detail: L10n.tr("从 CellDock 官方服务器检查并验证更新")
                    ) {
                        Button("检查更新…") {
                            updaterManager.checkForUpdates()
                        }
                        .adaptiveGlassButton()
                        .disabled(!updaterManager.canCheckForUpdates)
                    }
                    .padding(16)
                }
            }
        }
    }

    private var communicationSettings: some View {
        VStack(spacing: 16) {
            moduleStatusPanel

            settingsSection(title: L10n.tr("声音")) {
                VStack(spacing: 0) {
                    soundSettingRow(.message)
                        .padding(16)

                    Divider().padding(.horizontal, 16)

                    soundSettingRow(.incomingCall)
                        .padding(16)
                }
            }

            settingsSection(title: L10n.tr("通话录音")) {
                settingRow(
                    title: L10n.tr("通话时自动录音"),
                    detail: L10n.tr("通话接通且音频就绪后自动开始，录音仅保存在这台 Mac")
                ) {
                    Toggle("通话时自动录音", isOn: Binding(
                        get: { appState.automaticallyRecordCalls },
                        set: { enabled in
                            if enabled, !recordingConsent {
                                isConfirmingAutomaticRecording = true
                            } else {
                                appState.setAutomaticallyRecordCalls(enabled)
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.adaptiveGlass)
                }
                .padding(16)
            }

            settingsSection(title: L10n.tr("短信处理")) {
                VStack(spacing: 12) {
                    settingRow(
                        title: L10n.tr("已读验证码自动删除"),
                        detail: L10n.tr("标记已读 30 分钟后，从模块/SIM 与本地永久删除")
                    ) {
                        Toggle("已读验证码自动删除", isOn: Binding(
                            get: { appState.autoDeleteReadVerificationMessages },
                            set: { enabled in
                                if enabled {
                                    isConfirmingVerificationAutoDelete = true
                                } else {
                                    appState.setAutoDeleteReadVerificationMessages(false)
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }

                    inlineCallout(
                        L10n.tr("删除后无法恢复，开启时需要确认。"),
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                }
                .padding(16)
            }

            settingsSection(title: L10n.tr("收到的 SIM 卡短信")) {
                VStack(spacing: 12) {
                    settingRow(
                        title: L10n.tr("SIM 短信列表"),
                        detail: L10n.tr("在设置中显示通过 PDU 接收到的 SIM 短信最近列表")
                    ) {
                        Toggle("", isOn: Binding(
                            get: { appState.smsReceptionEnabled },
                            set: { appState.setSMSReceptionEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                    }

                    settingRow(
                        title: L10n.tr("收到短信时通知"),
                        detail: L10n.tr("Mac 系统通知横幅、声音与最近短信列表")
                    ) {
                        Toggle("", isOn: Binding(
                            get: { appState.smsNotificationsEnabled },
                            set: { appState.setSMSNotificationsEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                        .disabled(!appState.smsReceptionEnabled)
                    }

                    settingRow(
                        title: L10n.tr("自动转发到 iMessage"),
                        detail: L10n.tr("第一阶段默认关闭，后续版本接入 AppleScript / Shortcuts")
                    ) {
                        Toggle("", isOn: Binding(
                            get: { appState.smsIMessageRelayEnabled },
                            set: { appState.setSMSIMessageRelayEnabled($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.adaptiveGlass)
                        .disabled(true)
                    }

                    Button {
                        isPresentingSMSReceptionList = true
                    } label: {
                        Label(
                            appState.smsRecent.isEmpty
                                ? L10n.tr("查看短信列表")
                                : L10n.tr("查看短信列表（%lld 条）", Int64(appState.smsRecent.count)),
                            systemImage: "tray.full"
                        )
                    }
                    .adaptiveGlassButton()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .sheet(isPresented: $isPresentingSMSReceptionList) {
                SMSReceptionListView()
                    .environmentObject(appState)
            }
        }
    }

    private func soundSettingRow(_ kind: AlertSoundKind) -> some View {
        settingRow(
            title: kind.title,
            detail: alertSounds.displayName(for: kind)
        ) {
            HStack(spacing: 8) {
                Button {
                    previewSound(kind)
                } label: {
                    Label(
                        alertSounds.previewingKind == kind ? L10n.tr("停止") : L10n.tr("试听"),
                        systemImage: alertSounds.previewingKind == kind
                            ? "stop.fill"
                            : "play.fill"
                    )
                }
                .adaptiveGlassButton()
                .controlSize(.small)

                Button("选择…") {
                    chooseCustomSound(kind)
                }
                .adaptiveGlassButton()
                .controlSize(.small)

                if !alertSounds.isUsingDefault(kind) {
                    Button {
                        alertSounds.restoreDefault(for: kind)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .adaptiveGlassButton()
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .help("恢复默认")
                    .accessibilityLabel(L10n.tr("恢复默认%@", kind.title))
                }
            }
        }
    }

    private func previewSound(_ kind: AlertSoundKind) {
        do {
            try alertSounds.togglePreview(for: kind)
        } catch {
            soundImportError = error.localizedDescription
        }
    }

    private func chooseCustomSound(_ kind: AlertSoundKind) {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("选择%@", kind.title)
        panel.prompt = L10n.tr("选择")
        panel.message = L10n.tr("音频将复制到 CellDock 的应用支持目录，原文件可以安全移动或删除。")
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let sourceURL = panel.url else { return }
            Task { @MainActor in
                do {
                    try alertSounds.installCustomSound(from: sourceURL, for: kind)
                } catch {
                    soundImportError = error.localizedDescription
                }
            }
        }
    }

    /// The full DJI 4G module status panel. All values are derived by
    /// `ModemModuleStatusPresentation` from the existing state model — this view
    /// only spells out display strings and never re-judges USB composition.
    private var moduleStatusPanel: some View {
        let present = ModemModuleStatusPresentation.derive(snapshot: appState.modem)
        let statusColor = moduleStatusColor(for: present.status)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(verbatim: "DJI 4G Module")
                    .font(.headline)
                Spacer()
                Text(verbatim: statusName(present.status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            Divider()

            panelRow(title: "Device", value: "QDC507")
            panelRow(title: "USB", value: usbIdentityText)
            panelRow(title: "Profile", value: profileName(present.profile))
            panelRow(
                title: "Configuration",
                value: configurationText(present.configuration),
                valueColor: configurationColor(present.configuration)
            )
            if case let .needsRepair(issue) = present.configuration {
                Text(verbatim: issueText(issue))
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer().frame(height: 0)
            }
            panelRow(title: "AT", value: interfaceText(present.at), valueColor: interfaceColor(present.at))
            panelRow(title: "Network", value: interfaceText(present.network), valueColor: interfaceColor(present.network))
            panelRow(title: "ADB", value: interfaceText(present.adb), valueColor: interfaceColor(present.adb))
            panelRow(title: "Audio / UAC", value: audioText(present.audio))
            panelRow(title: "USB Mode", value: usbModeText(present.usbMode))

            modulePrimaryAction(for: present.usbMode)

            if let configuration = appState.modem.usbConfiguration,
               present.profile == .unsupported {
                Divider()
                Text(verbatim: "USBCFG  \(configuration.compactDescription)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .adaptiveGlassSurface(cornerRadius: 18, treatment: .regular)
        .accessibilityElement(children: .combine)
    }

    private func panelRow(title: String, value: String, valueColor: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(.callout.weight(.medium))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }

    private var usbIdentityText: String {
        guard let configuration = appState.modem.usbConfiguration else { return "—" }
        return String(format: "%04X:%04X", configuration.vendorID, configuration.productID)
    }

    /// The primary USB-mode action associated with the module's current UAC
    /// flag. UAC=1 → "Prepare for iPhone"; UAC=0 → "Switch to Mac / CellDock".
    /// Either flag is a *valid* composition; this is a mode, never a repair.
    @ViewBuilder
    private func modulePrimaryAction(for usbMode: ModemModuleStatusPresentation.USBMode) -> some View {
        switch usbMode {
        case .mac:
            mainUSBModeAction(
                title: L10n.tr("Prepare for iPhone"),
                systemImage: "iphone.badge.minus",
                action: { appState.prepareForiPhone() }
            )
            Text(verbatim: L10n.tr("切换到 Mobile 会关闭 UAC，断开前请确认已选好 iPhone 目标。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .mobile:
            mainUSBModeAction(
                title: L10n.tr("Switch to Mac / CellDock"),
                systemImage: "desktopcomputer.arrow.left",
                action: { appState.switchToMacUSBMode() }
            )
            Text(verbatim: L10n.tr("切换到 Mac 模式会重新开启 UAC。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unknown:
            EmptyView()
        }
    }

    private func statusName(_ status: ModemModuleStatusPresentation.Status) -> String {
        switch status {
        case .disconnected: return "Disconnected"
        case .detecting: return "Detecting"
        case .initializing: return "Initializing"
        case .ready: return "Ready"
        case .configurationRequired: return "Configuration Required"
        case .error: return "Error"
        }
    }

    private func profileName(_ profile: ModemModuleStatusPresentation.Profile) -> String {
        switch profile {
        case .djiOriginal: return "DJI Original"
        case .cellDockCompatible: return "CellDock Compatible"
        case .unsupported: return "Unsupported"
        }
    }

    private func configurationText(
        _ configuration: ModemModuleStatusPresentation.Configuration
    ) -> String {
        switch configuration {
        case .valid: return "Valid"
        case .needsRepair: return "Needs Repair"
        }
    }

    private func configurationColor(
        _ configuration: ModemModuleStatusPresentation.Configuration
    ) -> Color {
        switch configuration {
        case .valid: return .green
        case .needsRepair: return .orange
        }
    }

    private func issueText(
        _ issue: ModemModuleStatusPresentation.RepairIssue
    ) -> String {
        switch issue {
        case .diagDisabled: return "DIAG interface disabled"
        case .nmeaDisabled: return "NMEA interface disabled"
        case .atDisabled: return "AT interface disabled"
        case .modemDisabled: return "Modem interface disabled"
        case .networkDisabled: return "Network interface disabled"
        case .adbDisabled: return "ADB interface disabled"
        case let .unsupportedIdentity(identity): return "Unsupported VID/PID: \(identity)"
        case .malformed: return "USBCFG 无法读取，需要重新检测。"
        }
    }

    private func interfaceText(_ interface: ModemModuleStatusPresentation.Interface) -> String {
        switch interface {
        case .available: return "Ready"
        case .unavailable: return "Unavailable"
        case .notApplicable: return "—"
        }
    }

    private func interfaceColor(
        _ interface: ModemModuleStatusPresentation.Interface
    ) -> Color {
        switch interface {
        case .available: return .green
        case .unavailable: return .orange
        case .notApplicable: return .secondary
        }
    }

    private func audioText(_ audio: ModemModuleStatusPresentation.Audio) -> String {
        switch audio {
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .notApplicable: return "—"
        }
    }

    private func usbModeText(_ usbMode: ModemModuleStatusPresentation.USBMode) -> String {
        switch usbMode {
        case .mac: return "Mac / CellDock"
        case .mobile: return "iPhone / Mobile"
        case .unknown: return "—"
        }
    }

    private func moduleStatusColor(for status: ModemModuleStatusPresentation.Status) -> Color {
        switch status {
        case .ready: return .green
        case .configurationRequired: return .orange
        case .error: return .red
        case .detecting, .initializing: return .blue
        case .disconnected: return .secondary
        }
    }

    private var permissionSettings: some View {
        VStack(spacing: 16) {
            settingsSection(title: L10n.tr("通知")) {
                settingRow(
                    title: L10n.tr("系统通知"),
                    status: notificationPermissionStatus.text,
                    statusColor: notificationPermissionStatus.color,
                    detail: L10n.tr("用于来电、新短信和未接来电提醒")
                ) {
                    notificationPermissionAccessory
                }
                .padding(16)
            }

            settingsSection(title: L10n.tr("隐私权限")) {
                VStack(spacing: 0) {
                    settingRow(
                        title: L10n.tr("麦克风"),
                        status: microphonePermissionStatus.text,
                        statusColor: microphonePermissionStatus.color,
                        detail: L10n.tr("用于通话时传输本机音频")
                    ) {
                        Button(microphonePermissionButtonTitle) {
                            handleMicrophonePermissionAction()
                        }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .frame(width: 112)
                    }
                    .padding(16)

                    Divider().padding(.horizontal, 16)

                    settingRow(
                        title: L10n.tr("通讯录"),
                        status: contactPermissionStatus.text,
                        statusColor: contactPermissionStatus.color,
                        detail: L10n.tr("用于识别来电、短信联系人和拨号")
                    ) {
                        Button(contactPermissionButtonTitle) {
                            handleContactPermissionAction()
                        }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .frame(width: 112)
                    }
                    .padding(16)
                }
            }

            inlineMessage(
                L10n.tr("权限由 macOS 管理，可随时在系统设置中更改。"),
                systemImage: "checkmark.shield",
                color: .secondary
            )
            .padding(4)
            .adaptiveGlassSurface(
                cornerRadius: 18,
                padding: 13,
                treatment: .clear
            )
        }
    }

    @ViewBuilder
    private var notificationPermissionAccessory: some View {
        if appState.isRequestingNotificationAuthorization ||
            appState.notificationAuthorizationStatus == .unknown {
            ProgressView()
                .controlSize(.small)
                .frame(width: 112)
        } else {
            Button(notificationPermissionButtonTitle) {
                if appState.notificationAuthorizationStatus == .notDetermined {
                    appState.requestNotificationAuthorization()
                } else {
                    appState.openNotificationSettings()
                }
            }
            .adaptiveGlassButton()
            .controlSize(.small)
            .frame(width: 112)
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider().padding(.horizontal, 16)
            content()
        }
        .adaptiveGlassSurface(
            cornerRadius: 18,
            treatment: .regular
        )
    }

    private func settingRow<Accessory: View>(
        title: String,
        status: String? = nil,
        statusColor: Color = .secondary,
        detail: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if let status {
                        Text(status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            accessory()
        }
    }

    private func inlineMessage(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(color)
    }

    private func inlineCallout(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        inlineMessage(text, systemImage: systemImage, color: color)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .adaptiveGlassSurface(
                cornerRadius: 10,
                treatment: .clear,
                tint: color.opacity(0.08)
            )
    }

    private var selectedAppearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    private var appearanceModeBinding: Binding<AppAppearanceMode> {
        Binding(
            get: { selectedAppearanceMode },
            set: { mode in
                appearanceModeRawValue = mode.rawValue
                mode.apply()
            }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { languageController.selectedLanguage },
            set: { languageController.select($0) }
        )
    }

    private var launchAtLoginDetail: String {
        switch appState.launchAtLoginStatus {
        case .disabled: return L10n.tr("登录 Mac 后可在后台自动运行 CellDock")
        case .enabled: return L10n.tr("登录 Mac 后在后台运行 CellDock")
        case .unavailable: return L10n.tr("当前应用位置或用户会话不支持登录启动")
        }
    }

    private var notificationPermissionStatus: (text: String, color: Color) {
        switch appState.notificationAuthorizationStatus {
        case .unknown: return (L10n.tr("读取中"), .secondary)
        case .notDetermined: return (L10n.tr("未请求"), .secondary)
        case .denied: return (L10n.tr("未允许"), .orange)
        case .authorized: return (L10n.tr("已允许"), .green)
        }
    }

    private var allSettingsPermissionsAllowed: Bool {
        appState.notificationAuthorizationStatus == .authorized &&
            microphoneAuthorizationStatus == .authorized &&
            contacts.authorizationState == .authorized
    }

    private var notificationPermissionButtonTitle: String {
        appState.notificationAuthorizationStatus == .notDetermined
            ? L10n.tr("允许通知")
            : L10n.tr("通知设置…")
    }

    private var microphonePermissionStatus: (text: String, color: Color) {
        switch microphoneAuthorizationStatus {
        case .notDetermined: return (L10n.tr("未请求"), .secondary)
        case .restricted: return (L10n.tr("受限制"), .orange)
        case .denied: return (L10n.tr("未允许"), .orange)
        case .authorized: return (L10n.tr("已允许"), .green)
        @unknown default: return (L10n.tr("未知"), .secondary)
        }
    }

    private var microphonePermissionButtonTitle: String {
        microphoneAuthorizationStatus == .notDetermined
            ? L10n.tr("请求权限")
            : L10n.tr("系统设置…")
    }

    private var contactPermissionStatus: (text: String, color: Color) {
        switch contacts.authorizationState {
        case .notDetermined: return (L10n.tr("未请求"), .secondary)
        case .authorized: return (L10n.tr("已允许"), .green)
        case .denied: return (L10n.tr("未允许"), .orange)
        case .restricted: return (L10n.tr("受限制"), .orange)
        }
    }

    private var contactPermissionButtonTitle: String {
        contacts.authorizationState == .notDetermined
            ? L10n.tr("请求权限")
            : L10n.tr("系统设置…")
    }

    private func handleMicrophonePermissionAction() {
        if microphoneAuthorizationStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    microphoneAuthorizationStatus =
                        AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        } else {
            openPrivacySettings(anchor: "Privacy_Microphone")
        }
    }

    private func handleContactPermissionAction() {
        if contacts.authorizationState == .notDetermined {
            contacts.requestAccess()
        } else {
            contacts.openPrivacySettings()
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshSettingsState() {
        appState.refresh()
        refreshSystemPermissionState()
    }

    private func refreshSystemPermissionState() {
        appState.refreshSystemSettingsStatus()
        contacts.reload()
        microphoneAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }
}
