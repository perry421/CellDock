import Foundation

enum CallPhase: String, Equatable {
    case unavailable
    case idle
    case incoming
    case dialing
    case alerting
    case active
    case ending
    case recovering
    case error
}

enum CallDirection: String, Codable, Equatable {
    case outgoing
    case incoming
}

enum CallEndReason: String, Codable, Equatable {
    case localHangup
    case remoteHangup
    case busy
    case noAnswer
    case noDialTone
    case deviceDisconnected
    case failed

    var localizedDescription: String {
        switch self {
        case .localHangup: return L10n.tr("通话已结束")
        case .remoteHangup: return L10n.tr("对方已挂断")
        case .busy: return L10n.tr("对方忙线")
        case .noAnswer: return L10n.tr("无人接听")
        case .noDialTone: return L10n.tr("网络未提供拨号音")
        case .deviceDisconnected: return L10n.tr("模块已拔出，通话结束")
        case .failed: return L10n.tr("通话失败")
        }
    }
}

struct UACMediaSnapshot: Equatable {
    var inputFrames: UInt64 = 0
    var outputFrames: UInt64 = 0
    var inputTotalSamples: UInt64 = 0
    var inputSignalSamples: UInt64 = 0
    var inputPeakPCM16: UInt32 = 0
    var inputSignalThresholdPCM16: UInt32 = 0
}

struct CallSnapshot: Equatable {
    var moduleID: CellularModuleID?
    var phase: CallPhase = .unavailable
    var direction: CallDirection?
    var number: String?
    var voiceOverUSBSupported = false
    var audioActive = false
    var muted = false
    var startedAt: Date?
    var lastEndReason: CallEndReason?
    var lastError: String?
    var controlInterfaceBusy = false
    var mediaCleanupPending = false
    var uacMedia: UACMediaSnapshot?

    var hasCall: Bool {
        switch phase {
        case .incoming, .dialing, .alerting, .active, .ending, .recovering:
            return true
        case .unavailable, .idle, .error:
            return false
        }
    }

    /// Whether the AT call-control path is ready to place a call.
    ///
    /// Call control (ATD/ATA/ATH) is deliberately decoupled from audio-media
    /// readiness. A module whose AT channel is up, SIM ready and network
    /// registered can dial/answer/hang up even if its UAC audio path is not yet
    /// usable — in that case we still permit dialing and surface "音频未就绪"
    /// via `lastError` instead of refusing the call. `voiceOverUSBSupported`
    /// therefore no longer gates dialing; it only reflects whether the media
    /// backend is known-good.
    var canDial: Bool {
        phase == .idle && !mediaCleanupPending
    }

    var canSendDTMF: Bool {
        phase == .active
    }
}

enum ModemCallStatus: Int, Equatable {
    case active = 0
    case held = 1
    case dialing = 2
    case alerting = 3
    case incoming = 4
    case waiting = 5
}

struct ModemCallInfo: Equatable {
    let index: Int
    let direction: CallDirection
    let status: ModemCallStatus
    let isVoice: Bool
    let isMultiparty: Bool
    let number: String?
}

enum ModemCallEvent: Equatable {
    case ring
    case callerID(String)
    case callInfo(ModemCallInfo)
    case connected
    case ended(CallEndReason)
    case pcmFlowReady(Bool)
}
