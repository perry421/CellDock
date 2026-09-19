import Foundation

struct ModemTemperatureSnapshot: Equatable {
    enum Level: Equatable {
        case normal
        case warm
        case high
        case severe
        case extreme
    }

    var sensorValuesCelsius: [Int] = []
    var lastSuccessfulAt: Date?
    var isAvailable = false

    var primaryCelsius: Int? {
        isAvailable ? sensorValuesCelsius.first : nil
    }

    var level: Level? {
        primaryCelsius.map(Self.level(for:))
    }

    var localizedLevelText: String? {
        switch level {
        case .normal: return L10n.tr("正常")
        case .warm: return L10n.tr("偏热")
        case .high: return L10n.tr("高温")
        case .severe: return L10n.tr("严重高温警告")
        case .extreme: return L10n.tr("极高温 / 可能导致模块断网")
        case nil: return nil
        }
    }

    var menuBarSymbolName: String {
        switch level {
        case .severe, .extreme: return "exclamationmark.triangle.fill"
        case .high: return "thermometer.high"
        case .normal, .warm, nil: return "thermometer.medium"
        }
    }

    func sensorCelsius(at index: Int) -> Int? {
        guard isAvailable, sensorValuesCelsius.indices.contains(index) else { return nil }
        return sensorValuesCelsius[index]
    }

    mutating func markUnavailable() {
        isAvailable = false
    }

    static func level(for temperatureCelsius: Int) -> Level {
        switch temperatureCelsius {
        case 115...: return .extreme
        case 105...: return .severe
        case 90...: return .high
        case 70...: return .warm
        default: return .normal
        }
    }
}
