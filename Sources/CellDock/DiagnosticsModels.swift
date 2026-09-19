import Foundation

struct DiagnosticsItem: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}

struct DiagnosticsSection: Identifiable, Equatable {
    let title: String
    let items: [DiagnosticsItem]

    var id: String { title }
}

struct DiagnosticsSourceData: Equatable {
    var appVersion = ""
    var appBuild = ""
    var macOSVersion = ""
    var architecture = ""
    var appPath = ""

    var moduleConnected = false
    var moduleName: String?
    var usbIdentity: String?
    var firmwareVersion: String?
    var atPortStatus: String?
    var activeModule: String?

    var simStatus: String?
    var operatorName: String?
    var networkRegistration: String?
    var voiceRegistration: String?
    var rat: String?
    var signal: String?
    var primaryTemperature: Int?
    var sensorTemperatures: [Int] = []
    var temperatureStatus: String?
    var temperatureUpdatedAt: Date?
    var iccid: String?
    var imsi: String?
    var phoneNumber: String?
    var eid: String?

    var ecmInterface: String?
    var ecmStatus: String?
    var ipv4Address: String?
    var gateway: String?
    var primaryRouteStatus: String?

    var callStatus: String?
    var smsStatus: String?
    var esimStatus: String?
    var socksStatus: String?
    var voWiFiStatus: String?
    var audioStatus: String?
    var pollingStatus: String?

    var microphonePermission: String?
    var contactsPermission: String?
    var notificationPermission: String?

    var recentErrors: [String] = []
}

struct DiagnosticsSnapshot: Equatable {
    let generatedAt: Date
    let version: String
    let build: String
    let sections: [DiagnosticsSection]

    var reportText: String {
        var lines = [
            L10n.tr("CellDock 诊断"),
            "\(L10n.tr("生成时间")): \(Self.iso8601.string(from: generatedAt))",
            "\(L10n.tr("版本")): \(version)",
            "\(L10n.tr("构建版本")): \(build)",
            ""
        ]
        for section in sections {
            lines.append("[\(section.title)]")
            lines.append(contentsOf: section.items.map { "\($0.label): \($0.value)" })
            lines.append("")
        }
        lines.append("[\(L10n.tr("隐私"))]")
        lines.append(L10n.tr("敏感标识符已脱敏，报告不会自动上传。"))
        return lines.joined(separator: "\n") + "\n"
    }

    var suggestedFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "CellDock-Diagnostics-\(formatter.string(from: generatedAt)).txt"
    }

    private static let iso8601 = ISO8601DateFormatter()
}

enum DiagnosticsSnapshotBuilder {
    static func build(from source: DiagnosticsSourceData, at generatedAt: Date = .now) -> DiagnosticsSnapshot {
        let unavailable = L10n.tr("不可用")
        let temperatureUnavailable = L10n.tr("温度不可用")
        let sensorValues = source.sensorTemperatures

        let sections = [
            DiagnosticsSection(title: L10n.tr("App"), items: [
                item(L10n.tr("版本"), source.appVersion),
                item(L10n.tr("构建版本"), source.appBuild),
                item(L10n.tr("macOS 版本"), source.macOSVersion),
                item(L10n.tr("架构"), source.architecture),
                item(L10n.tr("应用路径"), DiagnosticsRedactor.redactPath(source.appPath))
            ]),
            DiagnosticsSection(title: L10n.tr("模组"), items: [
                item(L10n.tr("连接状态"), source.moduleConnected ? L10n.tr("已连接") : L10n.tr("未连接")),
                item(L10n.tr("模组名称"), source.moduleName ?? unavailable),
                item(L10n.tr("USB 标识"), source.usbIdentity ?? unavailable),
                item(L10n.tr("固件版本"), source.firmwareVersion ?? unavailable),
                item(L10n.tr("AT 端口"), source.atPortStatus ?? unavailable),
                item(L10n.tr("当前活动模组"), source.activeModule ?? unavailable)
            ]),
            DiagnosticsSection(title: L10n.tr("SIM 与蜂窝网络"), items: [
                item(L10n.tr("SIM 状态"), source.simStatus ?? unavailable),
                item(L10n.tr("运营商"), source.operatorName ?? unavailable),
                item(L10n.tr("LTE 注册"), source.networkRegistration ?? unavailable),
                item(L10n.tr("语音注册"), source.voiceRegistration ?? unavailable),
                item(L10n.tr("RAT"), source.rat ?? unavailable),
                item(L10n.tr("信号"), source.signal ?? unavailable),
                item(L10n.tr("主温度"), source.primaryTemperature.map { "\($0)°C" } ?? temperatureUnavailable),
                item(L10n.tr("传感器 2"), sensorValues.indices.contains(1) ? "\(sensorValues[1])°C" : temperatureUnavailable),
                item(L10n.tr("传感器 3"), sensorValues.indices.contains(2) ? "\(sensorValues[2])°C" : temperatureUnavailable),
                item(L10n.tr("温度状态"), source.temperatureStatus ?? temperatureUnavailable),
                item(L10n.tr("温度更新时间"), source.temperatureUpdatedAt.map(Self.iso8601.string) ?? unavailable),
                item("ICCID", DiagnosticsRedactor.maskIdentifier(source.iccid) ?? unavailable),
                item("IMSI", DiagnosticsRedactor.maskIdentifier(source.imsi) ?? unavailable),
                item(L10n.tr("本机号码"), DiagnosticsRedactor.maskIdentifier(source.phoneNumber) ?? unavailable),
                item("EID", DiagnosticsRedactor.maskIdentifier(source.eid) ?? unavailable)
            ]),
            DiagnosticsSection(title: L10n.tr("网络"), items: [
                item(L10n.tr("ECM 接口"), source.ecmInterface ?? unavailable),
                item(L10n.tr("接口状态"), source.ecmStatus ?? unavailable),
                item("IPv4", source.ipv4Address ?? unavailable),
                item(L10n.tr("网关"), source.gateway ?? unavailable),
                item(L10n.tr("主上网路径"), source.primaryRouteStatus ?? unavailable)
            ]),
            DiagnosticsSection(title: L10n.tr("CellDock 服务"), items: [
                item(L10n.tr("电话"), source.callStatus ?? unavailable),
                item(L10n.tr("短信"), source.smsStatus ?? unavailable),
                item("eSIM", source.esimStatus ?? unavailable),
                item("SOCKS5", source.socksStatus ?? unavailable),
                item("VoWiFi", source.voWiFiStatus ?? unavailable),
                item(L10n.tr("音频"), source.audioStatus ?? unavailable),
                item(L10n.tr("后台轮询"), source.pollingStatus ?? unavailable)
            ]),
            DiagnosticsSection(title: L10n.tr("macOS 权限"), items: [
                item(L10n.tr("麦克风"), source.microphonePermission ?? unavailable),
                item(L10n.tr("通讯录"), source.contactsPermission ?? unavailable),
                item(L10n.tr("通知"), source.notificationPermission ?? unavailable)
            ]),
            DiagnosticsSection(title: L10n.tr("最近错误"), items: recentErrorItems(source.recentErrors, unavailable: unavailable))
        ]

        return DiagnosticsSnapshot(
            generatedAt: generatedAt,
            version: source.appVersion,
            build: source.appBuild,
            sections: sections
        )
    }

    private static func item(_ label: String, _ value: String) -> DiagnosticsItem {
        DiagnosticsItem(label: label, value: value)
    }

    private static func recentErrorItems(_ errors: [String], unavailable: String) -> [DiagnosticsItem] {
        let sanitized = errors
            .map(DiagnosticsRedactor.redactFreeText)
            .filter { !$0.isEmpty }
            .prefix(10)
        guard !sanitized.isEmpty else {
            return [item(L10n.tr("状态"), L10n.tr("无近期错误"))]
        }
        return sanitized.enumerated().map { index, error in
            item(L10n.tr("错误 %lld", Int64(index + 1)), error)
        }
    }

    private static let iso8601 = ISO8601DateFormatter()
}

enum DiagnosticsRedactor {
    static func maskIdentifier(_ value: String?, visibleSuffix: Int = 4) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let suffixCount = min(max(visibleSuffix, 0), value.count)
        let suffix = value.suffix(suffixCount)
        return String(repeating: "*", count: max(4, value.count - suffixCount)) + suffix
    }

    static func redactPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty else { return path }
        return path.replacingOccurrences(of: home, with: "~")
    }

    static func redactFreeText(_ text: String) -> String {
        var result = redactPath(text)
        result = replacingMatches(
            in: result,
            pattern: #"(?i)LPA:1\$\S+"#,
            template: "[REDACTED ACTIVATION CODE]"
        )
        result = replacingMatches(
            in: result,
            pattern: #"(?i)(api[_-]?key|token|password)\s*[:=]\s*\S+"#,
            template: "$1=[REDACTED]"
        )
        result = replacingMatches(
            in: result,
            pattern: #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            template: "[REDACTED EMAIL]"
        )
        result = replacingMatches(
            in: result,
            pattern: #"~/\S+"#,
            template: "~/[REDACTED PATH]"
        )

        guard let expression = try? NSRegularExpression(pattern: #"(?<!\d)\+?\d{7,32}(?!\d)"#) else {
            return result
        }
        let mutable = NSMutableString(string: result)
        let range = NSRange(location: 0, length: mutable.length)
        for match in expression.matches(in: result, range: range).reversed() {
            let raw = mutable.substring(with: match.range)
            let masked = maskIdentifier(raw) ?? "[REDACTED]"
            mutable.replaceCharacters(in: match.range, with: masked)
        }
        return mutable as String
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
