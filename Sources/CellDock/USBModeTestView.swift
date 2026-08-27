import SwiftUI

/// Minimal live-hardware test surface for the Mac ↔ Mobile USB-mode switch.
///
/// This is deliberately *not* a polished feature UI. It exists so the UAC
/// (audio) ON/OFF transition can be exercised against a real QDC507 module
/// through the already-verified chain — `USBConfiguration` parse/serialize and
/// `USBModeController` read → validate → backup → write → re-enumerate →
/// verify → rollback-on-mismatch — while showing every raw AT response.
///
/// Hard rules encoded here:
/// - The target composition is always derived from the *live* `AT+QCFG=
///   "usbcfg"` reply; no VID/PID or flag value is ever hardcoded.
/// - Before any write, the computed diff must be exactly one field: UAC/audio.
///   Any other delta aborts before the modem is touched.
/// - The original composition is persisted via `USBConfigBackupStore` before
///   writing, so "Restore Mac Phone Mode" can always replay it verbatim.
/// - After re-enumeration, the post-state is re-read and compared field by
///   field; success requires AT alive, audio == target, network preserved,
///   and every protected field unchanged.
struct USBModeTestView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // MARK: - Result model

    struct CommandLogEntry: Identifiable, Equatable {
        let id = UUID()
        let command: String
        let output: String
        let isSuccess: Bool
    }

    enum Phase: Equatable {
        case idle
        case reading
        case writing
        case succeeded(String)
        case failed(String)
    }

    enum TestError: LocalizedError {
        case notConnected
        case readFailed
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .notConnected: return "模块未连接。"
            case .readFailed: return "读取 USBCFG 失败。"
            case .parseFailed: return "USBCFG 返回无法解析（字段数或取值异常）。"
            }
        }
    }

    // MARK: - State

    @State private var phase: Phase = .idle
    @State private var log: [CommandLogEntry] = []
    @State private var currentConfiguration: ModemUSBConfiguration?
    @State private var originalBeforeLastWrite: ModemUSBConfiguration?
    @State private var pendingWriteCommand: String?

    /// Created lazily once the AppState reference is available; the transport
    /// closure keeps the bridge decoupled from any single ModemService handle.
    @State private var controllerHolder: USBModeController?

    private var controller: USBModeController? {
        if controllerHolder == nil {
            let appStateReference = appState
            controllerHolder = USBModeController(
                transport: LiveATTransport { command, timeoutMS, completion in
                    appStateReference.executeDiagnosticATViaPrimaryModule(
                        command,
                        timeoutMS: timeoutMS,
                        completion: completion
                    )
                }
            )
        }
        return controllerHolder
    }

    private var isBusy: Bool {
        switch phase {
        case .reading, .writing: return true
        case .idle, .succeeded, .failed: return false
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            AdaptiveGlassBackdrop()
                .ignoresSafeArea()

            AdaptiveGlassContainer(spacing: 14) {
                content
            }
            .padding(22)
        }
        .frame(width: 720, height: 640)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            actionRow
            configurationSummary
            logArea
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "usb")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)
                .adaptiveGlassSurface(cornerRadius: 12, treatment: .clear)
            VStack(alignment: .leading, spacing: 2) {
                Text("USB 模式实机测试")
                    .font(.title2.weight(.semibold))
                Text("仅翻转 USBCFG 的 audio/UAC 位；其余字段以模块实际返回为准")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .adaptiveGlassButton()
            .controlSize(.small)
            .disabled(isBusy)
            .accessibilityLabel(L10n.tr("关闭 USB 模式测试"))
        }
    }

    static let iPhoneSuccessMessage = [
        L10n.tr("iPhone Mode 已配置成功。"),
        L10n.tr("现在拔下 DJI 4G 模块并插入 iPhone，测试："),
        L10n.tr("1. 4G 是否正常"),
        L10n.tr("2. 音乐/视频是否从 iPhone 扬声器播放")
    ].joined(separator: "\n")

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    runRead()
                } label: {
                    if phase == .reading {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("正在读取…")
                        }
                    } else {
                        Label("读取当前 USB 配置", systemImage: "arrow.clockwise")
                    }
                }
                .adaptiveGlassButton(.prominent)
                .disabled(isBusy)

                Button(role: .destructive) {
                    runSwitch(targetAudio: false, successMessage: Self.iPhoneSuccessMessage)
                } label: {
                    Label("切换到 iPhone Mode", systemImage: "iphone")
                }
                .adaptiveGlassButton()
                .disabled(isBusy || !canOfferSwitch(targetAudio: false))

                Button {
                    runSwitch(
                        targetAudio: true,
                        successMessage: L10n.tr(
                            "Mac Phone Mode 已恢复（audio/UAC=1）。可以拔下模块重新插回 Mac 使用。"
                        )
                    )
                } label: {
                    Label("恢复 Mac Phone Mode", systemImage: "desktopcomputer")
                }
                .adaptiveGlassButton()
                .disabled(isBusy || !canOfferSwitch(targetAudio: true))
            }

            if let pendingWriteCommand {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本次切换将写入的完整 AT 命令（基于实时读回值生成）：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(pendingWriteCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .adaptiveGlassSurface(cornerRadius: 10, treatment: .clear, tint: Color.orange.opacity(0.08))
            }

            if isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase == .reading ? "正在读取当前配置…" : "正在执行切换流程…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            switch phase {
            case let .succeeded(message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case let .failed(message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
        .adaptiveGlassCard()
    }

    @ViewBuilder
    private var configurationSummary: some View {
        if let configuration = currentConfiguration {
            VStack(alignment: .leading, spacing: 6) {
                summaryRow("VID:PID", configuration.identity)
                summaryRow("diag", configuration.diagnosticEnabled ? "1" : "0")
                summaryRow("nmea", configuration.nmeaEnabled ? "1" : "0")
                summaryRow("atPort", configuration.atPortEnabled ? "1" : "0")
                summaryRow("modem", configuration.modemEnabled ? "1" : "0")
                summaryRow("network", configuration.networkEnabled ? "1" : "0")
                summaryRow("adb", configuration.adbEnabled ? "1" : "0")
                summaryRow(
                    "audio / uac",
                    configuration.audioEnabled ? "1" : "0",
                    highlighted: true
                )
                if let original = originalBeforeLastWrite, original != configuration {
                    Divider()
                    Text("上次写入前的原始配置：\(original.usbcfgValueDescription)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .adaptiveGlassCard()
        }
    }

    private func summaryRow(_ label: String, _ value: String, highlighted: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(highlighted ? Color.orange : Color.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospaced().weight(highlighted ? .bold : .regular))
                .foregroundStyle(highlighted ? Color.orange : Color.primary)
                .textSelection(.enabled)
        }
    }

    private var logArea: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("原始 AT 记录", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                if !log.isEmpty {
                    Button("清空") { log.removeAll() }
                        .adaptiveGlassButton()
                        .controlSize(.small)
                        .disabled(isBusy)
                }
            }

            if log.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("尚未执行命令")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(log) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(entry.isSuccess ? Color.green : Color.red)
                                        .frame(width: 7, height: 7)
                                    Text("> \(entry.command)")
                                        .font(.subheadline.monospaced().weight(.semibold))
                                        .textSelection(.enabled)
                                }
                                Text(entry.output.isEmpty ? L10n.tr("（模块没有返回文本）") : entry.output)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .adaptiveGlassSurface(
                                cornerRadius: 10,
                                treatment: .clear,
                                tint: (entry.isSuccess ? Color.green : Color.red).opacity(0.04)
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .defaultScrollAnchor(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .adaptiveGlassCard()
    }

    private var footer: some View {
        HStack {
            Label("写入前自动备份到磁盘；回读校验失败会立即用原始配置回写。", systemImage: "externaldrive.badge.timemachine")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            Button("关闭") { close() }
                .adaptiveGlassButton()
                .disabled(isBusy)
        }
    }

    // MARK: - Actions

    private func canOfferSwitch(targetAudio: Bool) -> Bool {
        guard appState.modem.isConnected else { return false }
        guard let configuration = currentConfiguration ?? appState.modem.usbConfiguration else {
            return false
        }
        return configuration.audioEnabled != targetAudio
    }

    /// Operation 1 — read-only probe: AT / AT+QCFG="usbcfg" / AT+QCFG="usbnet".
    private func runRead() {
        phase = .reading
        runSequential(commands: [
            ("AT", 3_000),
            ("AT+QCFG=\"USBCFG\"", 5_000),
            ("AT+QCFG=\"usbnet\"", 5_000)
        ]) { results in
            defer { phase = .idle }
            guard results.allSatisfy({ $0.isSuccess }) else {
                phase = .failed(L10n.tr("读取未全部成功，请检查模块连接后重试。"))
                return
            }
            guard let usbcfgResult = results.first(where: {
                $0.command.contains("USBCFG")
            }), let parsed = ATResponseParser.parseUSBConfiguration(usbcfgResult.output) else {
                phase = .failed(TestError.parseFailed.localizedDescription)
                return
            }
            currentConfiguration = parsed
            appState.refresh()
        }
    }

    /// Operation 2/3 — live switch to the requested UAC state.
    ///
    /// Sequence per spec: fresh read → derive target from the *actual* value →
    /// verify the diff is exactly one audio bit → hand off to
    /// `USBModeController.transitionUSBMode` (which re-validates via its own
    /// diff check, persists a disk backup, writes, waits for re-enumeration,
    /// reads back and rolls back on any mismatch) → post-verify AT + usbnet +
    /// field-by-field comparison.
    private func runSwitch(targetAudio: Bool, successMessage: String) {
        guard appState.modem.isConnected else {
            phase = .failed(TestError.notConnected.localizedDescription)
            return
        }
        guard let modeController = controller else {
            phase = .failed(L10n.tr("测试桥接尚未就绪。"))
            return
        }
        phase = .writing
        pendingWriteCommand = nil

        // Step 1 — live read of the current composition.
        executeATViaBridge("AT+QCFG=\"USBCFG\"", timeoutMS: 5_000) { output, code in
            appendLog(command: "AT+QCFG=\"USBCFG\"", output: output, isSuccess: code == 0)
            guard code == 0 else {
                failSwitch(TestError.readFailed.localizedDescription)
                return
            }
            guard let current = ATResponseParser.parseUSBConfiguration(output) else {
                failSwitch(TestError.parseFailed.localizedDescription)
                return
            }

            // Step 2 — target derived strictly from the live value.
            let desired = current.switchingUSBMode(to: targetAudio ? .mac : .mobile)

            // Step 3 — diff must be exactly one field: audio/uac.
            guard desired.vendorID == current.vendorID,
                  desired.productID == current.productID,
                  desired.diagnosticEnabled == current.diagnosticEnabled,
                  desired.nmeaEnabled == current.nmeaEnabled,
                  desired.atPortEnabled == current.atPortEnabled,
                  desired.modemEnabled == current.modemEnabled,
                  desired.networkEnabled == current.networkEnabled,
                  desired.adbEnabled == current.adbEnabled,
                  desired.audioEnabled == targetAudio,
                  current.audioEnabled != targetAudio else {
                failSwitch(L10n.tr("差异校验失败：除 audio 外检测到其他字段变化，已停止写入。"))
                return
            }

            // Show exactly what will be written before touching the modem.
            pendingWriteCommand = desired.usbcfgWriteCommand
            originalBeforeLastWrite = current

            // Steps 4–7 inside USBModeController: validateDiff (only-UAC),
            // persistent backup of `current`, write, re-enumeration wait,
            // readback verification, automatic rollback on mismatch.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = modeController.transitionUSBMode(to: targetAudio ? .mac : .mobile)

                DispatchQueue.main.async {
                    guard result == .completed else {
                        failSwitch(L10n.tr("切换链路返回：%@。模块配置未确认为目标状态。", describe(result)))
                        return
                    }
                    // Step 8 — post-verification after re-enumeration.
                    verifyPostState(original: current, targetAudio: targetAudio) { postOK, postMessage in
                        if postOK {
                            pendingWriteCommand = nil
                            appState.refresh()
                            phase = .succeeded(successMessage)
                        } else {
                            phase = .failed(postMessage)
                        }
                    }
                }
            }
        }
    }

    private func describe(_ state: USBModeTransitionState) -> String {
        switch state {
        case .completed: return "completed"
        case .failed(let message): return message
        default: return "\(state)"
        }
    }

    private func failSwitch(_ message: String) {
        pendingWriteCommand = nil
        phase = .failed(message)
    }

    /// Post-state verification: AT alive, usbnet unchanged vs. pre-switch
    /// snapshot, USBCFG re-parsed with audio == target and all protected
    /// fields identical to the original.
    private func verifyPostState(
        original: ModemUSBConfiguration,
        targetAudio: Bool,
        completion: @escaping (_ ok: Bool, _ message: String) -> Void
    ) {
        let preNetMode = appState.modem.usbNetMode
        runSequential(commands: [
            ("AT", 3_000),
            ("AT+QCFG=\"USBCFG\"", 5_000),
            ("AT+QCFG=\"usbnet\"", 5_000)
        ]) { results in
            guard results.first(where: { $0.command == "AT" })?.isSuccess == true else {
                completion(false, L10n.tr("复验失败：AT 端口未恢复。"))
                return
            }
            guard let usbcfgResult = results.first(where: { $0.command.contains("USBCFG") }),
                  usbcfgResult.isSuccess,
                  let actual = ATResponseParser.parseUSBConfiguration(usbcfgResult.output) else {
                completion(false, L10n.tr("复验失败：无法回读 USBCFG。"))
                return
            }
            guard actual.audioEnabled == targetAudio else {
                completion(false, L10n.tr(
                    "复验失败：audio 位未达到目标状态（期望 %d，实际 %d）。",
                    targetAudio ? 1 : 0,
                    actual.audioEnabled ? 1 : 0
                ))
                return
            }
            guard actual.vendorID == original.vendorID,
                  actual.productID == original.productID,
                  actual.diagnosticEnabled == original.diagnosticEnabled,
                  actual.nmeaEnabled == original.nmeaEnabled,
                  actual.atPortEnabled == original.atPortEnabled,
                  actual.modemEnabled == original.modemEnabled,
                  actual.networkEnabled == original.networkEnabled,
                  actual.adbEnabled == original.adbEnabled else {
                completion(false, L10n.tr("复验失败：protected fields 与原配置不一致，请立即检查模块状态。"))
                return
            }
            guard let netModeResult = results.first(where: { $0.command.contains("usbnet") }),
                  netModeResult.isSuccess else {
                completion(false, L10n.tr("复验失败：AT+QCFG=\"usbnet\" 未返回成功。"))
                return
            }
            if let preNetMode,
               let postNetMode = ATResponseParser.parseUSBNetMode(netModeResult.output),
               preNetMode != postNetMode {
                completion(false, L10n.tr("复验失败：usbnet 从 %d 变为 %d。", preNetMode, postNetMode))
                return
            }
            currentConfiguration = actual
            completion(true, "")
        }
    }

    // MARK: - AT plumbing

    /// Runs commands one-by-one through the diagnostic bridge, appending each
    /// raw exchange to the log, then hands the full result list back.
    private func runSequential(
        commands: [(command: String, timeoutMS: Int)],
        completion: @escaping ([CommandLogEntry]) -> Void
    ) {
        var collected: [CommandLogEntry] = []
        func next(_ index: Int) {
            guard index < commands.count else {
                completion(collected)
                return
            }
            let item = commands[index]
            executeATViaBridge(item.command, timeoutMS: item.timeoutMS) { output, code in
                collected.append(CommandLogEntry(
                    command: item.command,
                    output: output,
                    isSuccess: code == 0
                ))
                next(index + 1)
            }
        }
        next(0)
    }

    private func executeATViaBridge(
        _ command: String,
        timeoutMS: Int,
        completion: @escaping (_ output: String, _ code: Int32) -> Void
    ) {
        appState.executeDiagnosticATViaPrimaryModule(command, timeoutMS: timeoutMS, completion: completion)
    }

    private func appendLog(command: String, output: String, isSuccess: Bool) {
        log.insert(CommandLogEntry(command: command, output: output, isSuccess: isSuccess), at: 0)
    }

    private func close() {
        dismiss()
    }
}

// MARK: - Transport bridge

/// Adapts CellDock's existing AT channel to `USBModemTransport`.
///
/// Commands are forwarded verbatim through the injected AppState bridge; no
/// new AT vocabulary is introduced. Reconnect detection polls whether the
/// primary module's AT port has reopened after re-enumeration instead of
/// opening any new handle.
final class LiveATTransport: USBModemTransport {
    typealias DiagnosticExecutor = (
        _ command: String,
        _ timeoutMS: Int,
        _ completion: @escaping (_ output: String, _ code: Int32) -> Void
    ) -> Void

    private let executor: DiagnosticExecutor

    init(executor: @escaping DiagnosticExecutor) {
        self.executor = executor
    }

    func execute(command: String, timeoutMS: Int) -> (output: String, code: Int32) {
        let semaphore = DispatchSemaphore(value: 0)
        var boxed: (output: String, code: Int32)?
        executor(command, timeoutMS) { output, code in
            boxed = (output, code)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .milliseconds(timeoutMS + 5_000))
        return boxed ?? ("", Int32(-1))
    }

    func waitForReconnect(timeoutMS: Int) -> Bool {
        // Re-enumeration takes seconds; poll on a background-safe cadence.
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1_000)
        Thread.sleep(forTimeInterval: 1.5)
        while Date() < deadline {
            // The next USBCFG readback doubles as the liveness probe: it runs
            // through the same channel, so success implies the port is back.
            let probe = execute(command: "AT", timeoutMS: 2_000)
            if probe.code == 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    var isConnected: Bool { true }
}