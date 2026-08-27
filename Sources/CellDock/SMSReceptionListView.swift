import AppKit
import SwiftUI

/// Read-only sheet that shows PDU-decoded SMS mirrored into `SMSManager`.
/// There is no service-state indicator because the modem always stays in PDU
/// mode (`AT+CMGF=0`); CellDock's new fan-out is a pure App-level side
/// channel that can never break the modem's SMS receiver.
@MainActor
struct SMSReceptionListView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMessage: ModemSMSMessage?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L10n.tr("收到的 SIM 卡短信"))
                .font(.headline)
            Spacer()
            Button {
                appState.clearSMSRecent()
            } label: {
                Label(L10n.tr("清空"), systemImage: "trash")
            }
            .disabled(appState.smsRecent.isEmpty)
            .controlSize(.small)

            Button(L10n.tr("完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if appState.smsRecent.isEmpty {
            emptyState
        } else {
            List(selection: $selectedMessage) {
                ForEach(appState.smsRecent) { message in
                    SMSReceptionRow(message: message)
                        .tag(message)
                        .contextMenu {
                            Button(L10n.tr("复制正文")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.body, forType: .string)
                            }
                            Button(L10n.tr("复制发件人")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.sender, forType: .string)
                            }
                        }
                }
            }
            .listStyle(.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(L10n.tr("暂无短信"))
                .font(.title3)
            Text(L10n.tr("收到的 SIM 卡短信会显示在这里。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SMSReceptionRow: View {
    let message: ModemSMSMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(displaySender)
                    .font(.headline)
                Spacer()
                Text(timestampString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(preview)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private var displaySender: String {
        message.sender.isEmpty ? L10n.tr("未知号码") : message.sender
    }

    private var preview: String {
        let trimmed = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.tr("（空短信）") : trimmed
    }

    private var timestampString: String {
        let date = message.timestamp ?? message.receivedAt
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
