import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func value(_ label: String, in snapshot: DiagnosticsSnapshot) -> String? {
    snapshot.sections
        .flatMap(\.items)
        .first { $0.label == label }?
        .value
}

let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
var source = DiagnosticsSourceData()
source.appVersion = "0.3.2"
source.appBuild = "106"
source.macOSVersion = "macOS Test"
source.architecture = "arm64"
source.appPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications/CellDock.app")
    .path
source.moduleConnected = true
source.moduleName = "模组 1 · 中国电信"
source.usbIdentity = "2C7C:0125"
source.atPortStatus = "AT #2"
source.activeModule = "模组 1"
source.simStatus = "已就绪"
source.operatorName = "中国电信"
source.networkRegistration = "已注册"
source.voiceRegistration = "已注册"
source.rat = "LTE"
source.signal = "-101 dBm"
source.primaryTemperature = 41
source.sensorTemperatures = [41, 38, 37]
source.temperatureStatus = "正常"
source.temperatureUpdatedAt = generatedAt
source.iccid = "89860312345678901234"
source.imsi = "460031234567890"
source.phoneNumber = "+8613800138000"
source.eid = "89049032123456789012345678901234"
source.ecmInterface = "en7"
source.ecmStatus = "已启用并连接"
source.ipv4Address = "192.168.225.28"
source.gateway = "192.168.225.1"
source.primaryRouteStatus = "是"
source.callStatus = "空闲"
source.smsStatus = "可用"
source.esimStatus = "实体 SIM"
source.socksStatus = "未配置"
source.voWiFiStatus = "未运行"
source.audioStatus = "尚未确认"
source.pollingStatus = "运行中（复用现有模组轮询）"
source.microphonePermission = "已允许"
source.contactsPermission = "未允许"
source.notificationPermission = "已允许"
source.recentErrors = [
    "dial +8613800138000 failed token=secret-token",
    "LPA:1$smdp.example.com$ACTIVATION-CODE",
    "log at \(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Logs/CellDock",
    "Apple account user@example.com unavailable"
]

let snapshot = DiagnosticsSnapshotBuilder.build(from: source, at: generatedAt)
expect(snapshot.version == "0.3.2", "Snapshot must retain the app version")
expect(snapshot.build == "106", "Snapshot must retain the build number")
expect(value("主温度", in: snapshot) == "41°C", "Primary temperature must be reported")
expect(value("传感器 2", in: snapshot) == "38°C", "Second sensor must be reported")
expect(value("传感器 3", in: snapshot) == "37°C", "Third sensor must be reported")
expect(value("应用路径", in: snapshot) == "~/Applications/CellDock.app", "Home directory must be redacted")
expect(value("ICCID", in: snapshot) == "****************1234", "ICCID must expose only its suffix")
expect(value("IMSI", in: snapshot) == "***********7890", "IMSI must expose only its suffix")
expect(value("本机号码", in: snapshot) == "**********8000", "Phone number must expose only its suffix")
expect(value("EID", in: snapshot) == "****************************1234", "EID must expose only its suffix")

let report = snapshot.reportText
for secret in [
    "89860312345678901234",
    "460031234567890",
    "+8613800138000",
    "secret-token",
    "ACTIVATION-CODE",
    "user@example.com",
    FileManager.default.homeDirectoryForCurrentUser.path
] {
    expect(!report.contains(secret), "Diagnostics report leaked sensitive data: \(secret)")
}
expect(report.contains("中国电信"), "UTF-8 Chinese content must survive report generation")
expect(report.contains("[REDACTED ACTIVATION CODE]"), "Activation codes must be redacted")
expect(report.contains("token=[REDACTED]"), "Token values must be redacted")
expect(report.contains("[隐私]"), "Report must include the localized privacy notice")
expect(snapshot.suggestedFilename.hasPrefix("CellDock-Diagnostics-"), "Export filename must be stable")
expect(snapshot.suggestedFilename.hasSuffix(".txt"), "Export must use a text filename")

var unavailable = DiagnosticsSourceData()
unavailable.appVersion = "0.3.2"
unavailable.appBuild = "106"
let unavailableSnapshot = DiagnosticsSnapshotBuilder.build(from: unavailable, at: generatedAt)
expect(value("连接状态", in: unavailableSnapshot) == "未连接", "Disconnected modules must be explicit")
expect(value("主温度", in: unavailableSnapshot) == "温度不可用", "Missing temperature must not become 0°C")
expect(value("SIM 状态", in: unavailableSnapshot) == "不可用", "Missing SIM data must be safe")
expect(value("ECM 接口", in: unavailableSnapshot) == "不可用", "Missing ECM data must be safe")
expect(value("状态", in: unavailableSnapshot) == "无近期错误", "No-error state must be explicit")

let manyErrors = (1...12).map { "error \($0)" }
unavailable.recentErrors = manyErrors
let capped = DiagnosticsSnapshotBuilder.build(from: unavailable, at: generatedAt)
let errorSection = capped.sections.first { $0.title == "最近错误" }
expect(errorSection?.items.count == 10, "Only the 10 most recent diagnostic errors may be exported")

print("Diagnostics self-tests passed")
