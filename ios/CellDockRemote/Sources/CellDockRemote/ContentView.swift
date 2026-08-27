import Network
import SwiftUI

/// Entry point lives in CellDockRemoteApp.swift; this file only contains views.
struct ContentView: View {
    @EnvironmentObject var client: BridgeClient

    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("状态", systemImage: "iphone") }
            DialerView()
                .tabItem { Label("拨号", systemImage: "phone.fill") }
        }
        .overlay(alignment: .top) {
            if client.callState == .incoming, let number = client.callNumber {
                IncomingCallBanner(number: number)
                    .transition(.move(edge: .top))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let err = client.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
                    .padding()
            }
        }
    }
}

// MARK: - Status

struct StatusView: View {
    @EnvironmentObject var client: BridgeClient
    var service: NWBrowser.Result? {
        client.discoveredServices.first
    }

    var body: some View {
        VStack(spacing: 20) {
            header
            Divider()
            deviceInfo
            if client.callState != .idle && client.callState != .incoming {
                callStatus
            }
            Spacer()
            connectSection
        }
        .padding()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("CellDock Bridge")
                    .font(.title2)
                    .bold()
                Text("iPhone remote control")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            connectionDot
        }
    }

    private var connectionDot: some View {
        Circle()
            .fill(client.isConnected ? Color.green : Color.gray)
            .frame(width: 10, height: 10)
    }

    private var deviceInfo: some View {
        GroupBox(label: Label("模块状态", systemImage: "cpu")) {
            VStack(spacing: 10) {
                detailRow(title: "在线", value: client.moduleOnline ? "是" : "否")
                detailRow(title: "运营商", value: client.operatorName ?? "—")
                detailRow(title: "SIM", value: client.simReady ? "就绪" : "未就绪")
                signalBarsRow
                detailRow(title: "本机号码", value: client.phoneNumber ?? "—")
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
        }
    }

    private var signalBarsRow: some View {
        HStack {
            Text("信号")
                .foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Rectangle()
                        .fill(i < client.signalBars ? Color.blue : Color.secondary.opacity(0.3))
                        .frame(height: CGFloat(8 + i * 4))
                }
            }
            .frame(width: 50)
            Text("\(client.signalBars)/4")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var callStatus: some View {
        GroupBox(label: Label("通话状态", systemImage: "phone.arrow.up.right")) {
            CallStateRow(state: client.callState, number: client.callNumber)
        }
    }

    private var connectSection: some View {
        GroupBox(label: Label("连接", systemImage: "wifi")) {
            if let svc = service,
               case .hostPort(let host, let port) = svc.endpoint {
                VStack(alignment: .leading, spacing: 6) {
                    Text("发现设备: \(host):\(port)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                Text("手动输入 IP:Port 见设置页")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct CallStateRow: View {
    let state: BridgeCallState
    let number: String?

    var label: String {
        switch state {
        case .idle: return "空闲"
        case .incoming: return "来电"
        case .dialing: return "拨号中"
        case .ringing: return "对方响铃"
        case .connected: return "通话中"
        case .ended: return "已结束"
        case .error: return "错误"
        }
    }

    var icon: String {
        switch state {
        case .idle: return "phone.down.fill"
        case .incoming: return "phone.arrow.down.inbound.fill"
        case .dialing: return "phone.badge.plus"
        case .ringing: return "phone.ringing"
        case .connected: return "phone.fill"
        case .ended: return "phone.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(stateColor)
            Text(label)
            if let number {
                Spacer()
                Text(number)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var stateColor: Color {
        switch state {
        case .idle: return .secondary
        case .incoming: return .blue
        case .dialing: return .orange
        case .ringing: return .purple
        case .connected: return .green
        case .ended: return .secondary
        case .error: return .red
        }
    }
}

// MARK: - Incoming call banner

struct IncomingCallBanner: View {
    let number: String
    @EnvironmentObject var client: BridgeClient

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("来电")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                Text(number.isEmpty ? "未知号码" : number)
                    .font(.title3)
                    .bold()
            }
            Spacer()
            Button {
                client.hangup()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.red)
                    .clipShape(Circle())
            }
            Button {
                client.answer()
            } label: {
                Image(systemName: "phone.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.green)
                    .clipShape(Circle())
            }
        }
        .padding()
        .background(Color.black.opacity(0.85))
        .foregroundColor(.white)
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

// MARK: - Dialer

struct DialerView: View {
    @EnvironmentObject var client: BridgeClient
    @State private var numberText = ""

    var body: some View {
        VStack(spacing: 24) {
            NumberDisplay(text: numberText)
            KeypadView(onDigit: { numberText += $0 })
            ActionRow(
                dial: {
                    guard !numberText.isEmpty else { return }
                    client.dial(numberText)
                },
                clear: { numberText = "" },
                call: {
                    guard !numberText.isEmpty else { return }
                    client.dial(numberText)
                },
                hangup: client.callState.hasCall ? { client.hangup() } : nil
            )
        }
        .padding()
    }
}

struct NumberDisplay: View {
    let text: String
    var body: some View {
        Text(text.isEmpty ? "输入号码" : text)
            .font(.title)
            .foregroundColor(text.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray),
                alignment: .bottom
            )
    }
}

struct KeypadView: View {
    let onDigit: (String) -> Void
    private let digits = ["1","2","3","4","5","6","7","8","9","*","0","#"]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { col in
                        let idx = row * 3 + col
                        DigitButton(digit: digits[idx]) { onDigit(digits[idx]) }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct DigitButton: View {
    let digit: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(digit)
                .font(.title2)
                .frame(width: 72, height: 72)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct ActionRow: View {
    let dial: () -> Void
    let clear: () -> Void
    let call: () -> Void
    let hangup: (() -> Void)?

    var body: some View {
        HStack(spacing: 24) {
            Button(action: clear) {
                Text("清除")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let hangup {
                callAction(icon: "phone.down.fill", color: .red, action: hangup)
            } else {
                callAction(icon: "phone.fill", color: .green, action: call)
            }
        }
    }

    private func callAction(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(.white)
                .frame(width: 68, height: 68)
                .background(color)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

extension BridgeCallState {
    var hasCall: Bool {
        switch self {
        case .dialing, .ringing, .connected, .incoming: return true
        case .idle, .ended, .error: return false
        }
    }
}
