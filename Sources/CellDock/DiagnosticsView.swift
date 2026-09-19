import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @ObservedObject private var appState: AppState
    @ObservedObject private var contacts = SystemContactStore.shared
    @ObservedObject private var socksProxyController: SOCKSProxyController
    @ObservedObject private var voWiFiController: VoWiFiController
    @State private var feedbackMessage: String?

    init(appState: AppState) {
        _appState = ObservedObject(wrappedValue: appState)
        _socksProxyController = ObservedObject(wrappedValue: appState.socksProxyController)
        _voWiFiController = ObservedObject(wrappedValue: appState.voWiFiController)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            actionBar

            ForEach(snapshot.sections) { section in
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title)
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)

                    Divider().padding(.horizontal, 16)

                    VStack(spacing: 0) {
                        ForEach(section.items.indices, id: \.self) { index in
                            let item = section.items[index]
                            LabeledContent(item.label) {
                                Text(item.value)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)

                            if index < section.items.count - 1 {
                                Divider().padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .adaptiveGlassSurface(cornerRadius: 18, treatment: .regular)
            }
        }
        .onAppear {
            contacts.reload()
            appState.refreshSystemSettingsStatus()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(L10n.tr("生成诊断报告"), systemImage: "square.and.arrow.down", action: saveReport)
                .adaptiveGlassButton(.prominent)

            Button(L10n.tr("复制到剪贴板"), systemImage: "doc.on.doc", action: copyReport)
                .adaptiveGlassButton()

            Spacer(minLength: 12)

            if let feedbackMessage {
                Text(feedbackMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .adaptiveGlassSurface(
            cornerRadius: 18,
            padding: 13,
            treatment: .clear
        )
    }

    private var snapshot: DiagnosticsSnapshot {
        DiagnosticsLiveSnapshotFactory.make(
            appState: appState,
            microphonePermission: microphonePermission,
            contactsPermission: contactsPermission,
            notificationPermission: notificationPermission
        )
    }

    private var microphonePermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: L10n.tr("未请求")
        case .restricted: L10n.tr("受限制")
        case .denied: L10n.tr("未允许")
        case .authorized: L10n.tr("已允许")
        @unknown default: L10n.tr("未知")
        }
    }

    private var contactsPermission: String {
        switch contacts.authorizationState {
        case .notDetermined: L10n.tr("未请求")
        case .authorized: L10n.tr("已允许")
        case .denied: L10n.tr("未允许")
        case .restricted: L10n.tr("受限制")
        }
    }

    private var notificationPermission: String {
        switch appState.notificationAuthorizationStatus {
        case .unknown: L10n.tr("读取中")
        case .notDetermined: L10n.tr("未请求")
        case .denied: L10n.tr("未允许")
        case .authorized: L10n.tr("已允许")
        }
    }

    private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.reportText, forType: .string)
        feedbackMessage = L10n.tr("诊断报告已复制。")
    }

    private func saveReport() {
        let report = snapshot
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = report.suggestedFilename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try report.reportText.write(to: url, atomically: true, encoding: .utf8)
                feedbackMessage = L10n.tr("诊断报告已保存。")
            } catch {
                feedbackMessage = L10n.error("保存诊断报告失败：%@", underlying: error)
            }
        }
    }
}
