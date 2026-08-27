import Darwin
import Foundation

enum SelfTestFailure: Error {
    case failed(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelfTestFailure.failed(message) }
}

/// Parses the given AT outcome, throwing a test failure if it was nil.
func expectNonNil<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw SelfTestFailure.failed(message) }
    return value
}

func expectDecodeFailure(_ pdu: String, _ message: String) throws {
    do {
        _ = try SMSPDUDecoder.decode(pdu)
        throw SelfTestFailure.failed(message)
    } catch is SMSPDUDecoderError {
        return
    } catch {
        throw error
    }
}

do {
    try expect(
        AppLanguage.preferredSystemLanguage(from: ["zh-Hans-CN"]) == .simplifiedChinese &&
            AppLanguage.preferredSystemLanguage(from: ["en-US"]) == .english &&
            AppLanguage.preferredSystemLanguage(from: ["ja-JP"]) == .japanese &&
            AppLanguage.preferredSystemLanguage(from: ["fr-FR"]) == .french,
        "supported system language was not selected on first launch"
    )
    try expect(
        AppLanguage.preferredSystemLanguage(from: ["zh-Hant-TW", "en-US"]) == .english &&
            AppLanguage.preferredSystemLanguage(from: ["de-DE"]) == .english,
        "unsupported system language did not fall back to English"
    )

    let privatePresentation = PrivacyPresentation(
        isEnabled: true,
        aliasSalt: "self-test-salt"
    )
    let publicPresentation = PrivacyPresentation(
        isEnabled: false,
        aliasSalt: "self-test-salt"
    )
    let protectedIdentity = privatePresentation.identity(
        contactName: "张三",
        number: "13800138000"
    )
    try expect(
        !protectedIdentity.contains("张三") &&
            !protectedIdentity.contains("13800138000") &&
            protectedIdentity.hasPrefix("联系人 "),
        "privacy presentation exposed a contact identity"
    )
    try expect(
        protectedIdentity == privatePresentation.identity(
            contactName: "张三",
            number: "+86 138-0013-8000"
        ),
        "privacy alias was not stable across equivalent phone formats"
    )
    try expect(
        publicPresentation.identity(
            contactName: "张三",
            number: "13800138000"
        ) == "张三",
        "disabled privacy presentation changed a contact identity"
    )
    try expect(
        privatePresentation.phoneNumber("13800138000") == "号码已隐藏" &&
            privatePresentation.messageText("验证码是 482913") == "短信内容已隐藏" &&
            privatePresentation.verificationCode("482913") == "验证码已隐藏" &&
            privatePresentation.simIdentifier("89860312345678901234") == "标识已隐藏",
        "privacy presentation exposed protected detail values"
    )
    try expect(
        privatePresentation.recordingTitle(
            customTitle: "与张三的通话",
            contactName: "张三",
            number: "13800138000"
        ).hasPrefix("通话录音 "),
        "privacy presentation exposed a recording title"
    )

    let payloadURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/self-tests/ModuleVoice.payload")
    let voicePackage = try ModuleVoicePayload.loadPayload(at: payloadURL)
    try expect(
        voicePackage.manifest.modules.map(\.file) == [
            "qdc507_aprv3.ko",
            "qdc507_voice.ko",
        ],
        "ModuleVoice payload changed kernel module order"
    )
    try expect(
        Set(voicePackage.components.keys) == Set([
            "qdc507_aprv3.ko",
            "qdc507_voice.ko",
            "celldock-pcm-bridge.armv7",
        ]),
        "ModuleVoice payload component set"
    )

    var tamperedPayload = try Data(contentsOf: payloadURL)
    tamperedPayload[tamperedPayload.index(before: tamperedPayload.endIndex)] ^= 0x01
    let tamperedPayloadURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CellDock-ModuleVoice-\(UUID().uuidString).payload")
    try tamperedPayload.write(to: tamperedPayloadURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: tamperedPayloadURL) }
    var rejectedTamperedPayload = false
    do {
        _ = try ModuleVoicePayload.loadPayload(at: tamperedPayloadURL)
    } catch {
        rejectedTamperedPayload = true
    }
    try expect(rejectedTamperedPayload, "tampered ModuleVoice payload was accepted")

    let tombstoneRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("CellDock-message-tombstone-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tombstoneRoot) }
    let tombstoneDate = Date(timeIntervalSince1970: 1_700_000_000)
    let tombstoneID = "stable-pdu-sha256"
    let tombstoneURL = tombstoneRoot.appendingPathComponent("deleted-message-ids.json")
    var tombstoneRegistry = DeletedMessageRegistry(fileURL: tombstoneURL)
    try expect(!tombstoneRegistry.contains(tombstoneID), "new deletion registry was not empty")
    tombstoneRegistry.insert(tombstoneID, at: tombstoneDate)
    try expect(tombstoneRegistry.contains(tombstoneID), "deletion registry lost current entry")
    let reloadedTombstoneRegistry = DeletedMessageRegistry(fileURL: tombstoneURL)
    try expect(
        reloadedTombstoneRegistry.contains(tombstoneID),
        "deletion registry lost entry after persistent reload"
    )

    let launchAgentPropertyList = LaunchAtLoginController.propertyList(
        appBundlePath: "/Users/test/Applications/CellDock.app"
    )
    try expect(
        launchAgentPropertyList["Label"] as? String == "app.celldock.mac.launch-at-login",
        "LaunchAgent label"
    )
    try expect(
        launchAgentPropertyList["ProgramArguments"] as? [String] == [
            "/usr/bin/open", "-g", "/Users/test/Applications/CellDock.app", "--args",
            "--background-connection-service",
        ],
        "LaunchAgent app path and background recovery argument"
    )
    try expect(
        launchAgentPropertyList["RunAtLoad"] as? Bool == true &&
            launchAgentPropertyList["KeepAlive"] == nil,
        "LaunchAgent must run once per login without relaunching after a manual quit"
    )
    try expect(
        !CellDockLaunchContext.shouldShowInitialWindow(arguments: [
            "/Applications/CellDock.app/Contents/MacOS/CellDock",
            "--background-connection-service",
        ]) &&
            CellDockLaunchContext.shouldShowInitialWindow(arguments: [
                "/Applications/CellDock.app/Contents/MacOS/CellDock",
            ]),
        "background login launch did not suppress only the initial window"
    )
    _ = try PropertyListSerialization.data(
        fromPropertyList: launchAgentPropertyList,
        format: .xml,
        options: 0
    )

    let missedCallDate = Date(timeIntervalSince1970: 1_700_000_100)
    let unacknowledgedMissedCall = CallHistoryRecord(
        id: UUID(),
        direction: .incoming,
        number: "10086",
        startedAt: missedCallDate.addingTimeInterval(-20),
        connectedAt: nil,
        endedAt: missedCallDate,
        endReason: .remoteHangup,
        recordingID: nil,
        missedCallAcknowledged: false
    )
    var acknowledgedMissedCall = unacknowledgedMissedCall
    acknowledgedMissedCall.missedCallAcknowledged = true
    let answeredIncomingCall = CallHistoryRecord(
        id: UUID(),
        direction: .incoming,
        number: "10010",
        startedAt: missedCallDate,
        connectedAt: missedCallDate.addingTimeInterval(2),
        endedAt: missedCallDate.addingTimeInterval(12),
        endReason: .remoteHangup,
        recordingID: nil
    )
    try expect(
        unacknowledgedMissedCall.isUnacknowledgedMissed,
        "new missed call did not request attention"
    )
    try expect(
        !acknowledgedMissedCall.isUnacknowledgedMissed &&
            !answeredIncomingCall.isUnacknowledgedMissed,
        "acknowledged or answered call requested missed-call attention"
    )
    var legacyMissedCall = unacknowledgedMissedCall
    legacyMissedCall.missedCallAcknowledged = nil
    let callEncoder = JSONEncoder()
    callEncoder.dateEncodingStrategy = .iso8601
    let callDecoder = JSONDecoder()
    callDecoder.dateDecodingStrategy = .iso8601
    let decodedLegacyCall = try callDecoder.decode(
        CallHistoryRecord.self,
        from: callEncoder.encode(legacyMissedCall)
    )
    try expect(
        !decodedLegacyCall.isUnacknowledgedMissed,
        "legacy missed call was incorrectly surfaced as a new notification"
    )
    var moduleAttributedCall = answeredIncomingCall
    moduleAttributedCall.moduleID = CellularModuleID(rawValue: "usb-location:03100000")
    let decodedModuleAttributedCall = try callDecoder.decode(
        CallHistoryRecord.self,
        from: callEncoder.encode(moduleAttributedCall)
    )
    try expect(
        decodedModuleAttributedCall.moduleID == moduleAttributedCall.moduleID,
        "call history lost its modem route during persistence"
    )

    func conversationMessage(
        id: String,
        address: String,
        body: String,
        timestamp: Date,
        isRead: Bool,
        direction: SMSDirection = .incoming,
        moduleID: CellularModuleID? = nil
    ) -> SMSMessage {
        SMSMessage(
            id: id,
            moduleID: moduleID,
            modemIndices: [],
            sender: address,
            body: body,
            timestamp: timestamp,
            rawPDUs: [],
            isRead: isRead,
            readAt: isRead ? timestamp : nil,
            firstSeenAt: timestamp,
            direction: direction,
            deliveryState: direction == .outgoing ? .sent : nil
        )
    }

    let conversationDate = Date(timeIntervalSince1970: 1_700_001_000)
    let groupedConversations = MessageConversation.grouped(from: [
        conversationMessage(
            id: "mobile-unread",
            address: "+86 138-0013-8000",
            body: "较早的未读短信",
            timestamp: conversationDate,
            isRead: false
        ),
        conversationMessage(
            id: "mobile-read",
            address: "0086 138 0013 8000",
            body: "同一号码的已读短信",
            timestamp: conversationDate.addingTimeInterval(10),
            isRead: true
        ),
        conversationMessage(
            id: "mobile-latest",
            address: "138 0013 8000",
            body: "最新的已发送短信",
            timestamp: conversationDate.addingTimeInterval(30),
            isRead: true,
            direction: .outgoing
        ),
        conversationMessage(
            id: "carrier",
            address: "10086",
            body: "运营商通知",
            timestamp: conversationDate.addingTimeInterval(20),
            isRead: true
        ),
        conversationMessage(
            id: "bank-unread",
            address: "BANK",
            body: "较早的银行通知",
            timestamp: conversationDate.addingTimeInterval(5),
            isRead: false
        ),
        conversationMessage(
            id: "bank-latest",
            address: " bank ",
            body: "最新的银行通知",
            timestamp: conversationDate.addingTimeInterval(25),
            isRead: true
        ),
    ])
    try expect(groupedConversations.count == 3, "message conversations were not grouped by address")
    let mobileConversation = groupedConversations.first {
        $0.id == "13800138000"
    }
    try expect(
        mobileConversation?.messages.count == 3 &&
            mobileConversation?.latestMessage?.id == "mobile-latest" &&
            mobileConversation?.address == "138 0013 8000" &&
            mobileConversation?.unreadCount == 1 &&
            mobileConversation?.hasUnread == true,
        "mobile conversation lost its latest message or unread state"
    )
    try expect(
        groupedConversations.map(\.latestMessage?.id) == [
            "mobile-latest", "bank-latest", "carrier",
        ],
        "message conversations were not sorted by latest message"
    )
    try expect(
        groupedConversations.first(where: { $0.id == "bank" })?.unreadCount == 1,
        "alphanumeric sender variants were not grouped or retained as unread"
    )

    let firstSIM = CellularModuleID(rawValue: "usb-location:00100000")
    let secondSIM = CellularModuleID(rawValue: "usb-location:03100000")
    let perModuleConversations = MessageConversation.grouped(from: [
        conversationMessage(
            id: "same-peer-first-sim",
            address: "10000",
            body: "模组一",
            timestamp: conversationDate,
            isRead: true,
            moduleID: firstSIM
        ),
        conversationMessage(
            id: "same-peer-second-sim",
            address: "10000",
            body: "模组二",
            timestamp: conversationDate.addingTimeInterval(1),
            isRead: true,
            moduleID: secondSIM
        ),
    ])
    try expect(
        perModuleConversations.count == 2 &&
            Set(perModuleConversations.compactMap(\.moduleID)) == [firstSIM, secondSIM],
        "messages from the same peer on different modules were merged together"
    )
    var namespacedMessage = conversationMessage(
        id: "physical-message-id",
        address: "10000",
        body: "测试",
        timestamp: conversationDate,
        isRead: true
    )
    namespacedMessage.assignModule(secondSIM)
    try expect(
        namespacedMessage.moduleID == secondSIM &&
            namespacedMessage.id.hasPrefix("\(secondSIM.rawValue)|"),
        "incoming SMS identity was not namespaced by module"
    )

    try expect(
        SMSVerificationCodeExtractor.extract(from: "【CellDock】您的验证码为 482913，5 分钟内有效。") == "482913",
        "Chinese verification code extraction"
    )
    try expect(
        SMSVerificationCodeExtractor.extract(from: "7315 是您的登录验证码，请勿告诉他人。") == "7315",
        "verification code before keyword"
    )
    try expect(
        SMSVerificationCodeExtractor.extract(from: "Your verification code is A7K9Q2. Do not share it.") == "A7K9Q2",
        "alphanumeric verification code extraction"
    )
    try expect(
        SMSVerificationCodeExtractor.extract(from: "订单号 482913 已发货，预计明天送达。") == nil,
        "ordinary order number classified as verification code"
    )
    try expect(
        SMSVerificationCodeExtractor.extract(from: "订单 123456 的验证码是 654321。") == "654321",
        "nearby order number took precedence over verification code"
    )
    let verificationReadDate = Date(timeIntervalSince1970: 1_000)
    let readVerificationMessage = SMSMessage(
        id: "verification-read",
        modemIndices: [],
        sender: "CellDock",
        body: "您的验证码为 482913。",
        timestamp: verificationReadDate,
        rawPDUs: [],
        isRead: true,
        readAt: verificationReadDate,
        firstSeenAt: verificationReadDate
    )
    try expect(
        VerificationMessageAutoDeletePolicy.deletionDate(
            for: readVerificationMessage,
            enabled: true
        ) == Date(timeIntervalSince1970: 2_800),
        "verification auto-delete deadline"
    )
    var unreadVerificationMessage = readVerificationMessage
    unreadVerificationMessage.isRead = false
    unreadVerificationMessage.readAt = nil
    try expect(
        VerificationMessageAutoDeletePolicy.deletionDate(
            for: unreadVerificationMessage,
            enabled: true
        ) == nil,
        "unread verification message scheduled for deletion"
    )
    let ordinaryReadMessage = SMSMessage(
        id: "ordinary-read",
        modemIndices: [],
        sender: "Shop",
        body: "订单号 482913 已发货。",
        timestamp: verificationReadDate,
        rawPDUs: [],
        isRead: true,
        readAt: verificationReadDate,
        firstSeenAt: verificationReadDate
    )
    try expect(
        VerificationMessageAutoDeletePolicy.deletionDate(
            for: ordinaryReadMessage,
            enabled: true
        ) == nil,
        "ordinary read message scheduled for verification deletion"
    )
    try expect(
        VerificationMessageAutoDeletePolicy.deletionDate(
            for: readVerificationMessage,
            enabled: false
        ) == nil,
        "disabled verification auto-delete policy scheduled a message"
    )
    var outgoingVerificationMessage = readVerificationMessage
    outgoingVerificationMessage.direction = .outgoing
    try expect(
        VerificationMessageAutoDeletePolicy.deletionDate(
            for: outgoingVerificationMessage,
            enabled: true
        ) == nil,
        "outgoing verification text was scheduled for automatic deletion"
    )
    var refreshedVerificationMessage = readVerificationMessage
    refreshedVerificationMessage.isRead = false
    refreshedVerificationMessage.readAt = nil
    let preservedReadState = SMSMessageMerger.merge(
        existing: [readVerificationMessage],
        incoming: [refreshedVerificationMessage]
    ).messages.first
    try expect(
        preservedReadState?.isRead == true && preservedReadState?.readAt == verificationReadDate,
        "message refresh erased verification read time"
    )

    let adbPayload = Data("host::CellDock\0".utf8)
    let adbHeader = ADBWire.encodeHeader(
        command: ADBWire.cnxn,
        argument0: 0x01000001,
        argument1: 4_096,
        payload: adbPayload
    )
    let adbMessage = try ADBWire.decodeHeader(adbHeader, payload: adbPayload)
    try expect(adbHeader.count == 24, "ADB header size")
    try expect(adbMessage.command == ADBWire.cnxn, "ADB CNXN command encoding")
    try expect(adbMessage.payload == adbPayload, "ADB payload round trip")
    let syncData = ADBWire.syncPacket(identifier: "DATA", payload: Data([1, 2, 3]))
    try expect(
        syncData == Data([0x44, 0x41, 0x54, 0x41, 3, 0, 0, 0, 1, 2, 3]),
        "ADB sync DATA frame"
    )
    let checkedCommand = ADBWire.checkedShellCommand("id", token: "ABC123")
    try expect(
        checkedCommand.hasPrefix("( id; );"),
        "checked shell commands isolate early exit in a subshell"
    )
    try expect(
        checkedCommand.contains("__CELLDOCK_STATUS_ABC123_"),
        "ADB checked shell marker"
    )
    let checkedResult = try ADBWire.parseCheckedShellOutput(
        "uid=0(root)\r\n__CELLDOCK_STATUS_ABC123_0__\r\n",
        token: "ABC123"
    )
    try expect(checkedResult.output == "uid=0(root)", "ADB checked shell output")
    try expect(checkedResult.status == 0, "ADB checked shell status")

    try expect(
        CallATParser.normalizedDialNumber("+86 (138) 0013-8000") == "+8613800138000",
        "formatted dial number normalization"
    )
    try expect(CallATParser.normalizedDialNumber("13800138000;ATH") == nil, "AT dial injection accepted")
    try expect(CallATParser.normalizedDialNumber("13800138000\r") == nil, "dial CR injection accepted")
    try expect(CallATParser.normalizedDialNumber("١٣٨٠٠١٣٨٠٠٠") == nil, "non-ASCII dial digits accepted")
    for tone in ["0", "9", "*", "#"] {
        try expect(CallATParser.normalizedDTMFTone(tone) == tone, "valid DTMF tone rejected: \(tone)")
        try expect(
            CallATParser.dtmfCommand(for: tone) == "AT+VTS=\"\(tone)\"",
            "DTMF command did not use the documented quoted syntax: \(tone)"
        )
    }
    for invalidTone in ["", "12", "A", "１", "1;ATH", "\r", "\n"] {
        try expect(
            CallATParser.normalizedDTMFTone(invalidTone) == nil &&
                CallATParser.dtmfCommand(for: invalidTone) == nil,
            "invalid DTMF tone accepted: \(invalidTone.debugDescription)"
        )
    }

    let trimmedATCommand = try ATConsoleCommandValidator.validate("  at+csq  ")
    try expect(trimmedATCommand == "at+csq", "AT console trimming")
    for invalidCommand in ["", "CSQ", "AT+CSQ\r\nATD10000;", "AT+中文"] {
        do {
            _ = try ATConsoleCommandValidator.validate(invalidCommand)
            throw SelfTestFailure.failed("AT console accepted invalid input: \(invalidCommand.debugDescription)")
        } catch is ATConsoleCommandError {
            // Expected.
        }
    }
    for managedCommand in ["ATD10000;", "ATA", "ATH", "AT+VTS=1"] {
        do {
            _ = try ATConsoleCommandValidator.validate(managedCommand)
            throw SelfTestFailure.failed("AT console accepted app-managed call command: \(managedCommand)")
        } catch ATConsoleCommandError.managedCallCommand {
            // Expected.
        }
    }
    do {
        _ = try ATConsoleCommandValidator.validate("AT+CMGS=23")
        throw SelfTestFailure.failed("AT console accepted prompt-based CMGS")
    } catch ATConsoleCommandError.interactivePrompt {
        // Expected.
    }
    let cmgsCapabilityQuery = try ATConsoleCommandValidator.validate("AT+CMGS=?")
    try expect(
        cmgsCapabilityQuery == "AT+CMGS=?",
        "AT console rejected non-interactive capability query"
    )

    try expect(
        ATResponseParser.parseSubscriberNumber("\r\n+CNUM: \"\",\"13800138000\",129\r\nOK\r\n") ==
            "13800138000",
        "CNUM national subscriber number"
    )
    try expect(
        ATResponseParser.parseSubscriberNumber("+CNUM: \"Voice\",\"8613800138000\",145") ==
            "+8613800138000",
        "CNUM international subscriber number"
    )
    try expect(
        ATResponseParser.parseSubscriberNumber("+CNUM: \"\",\"\",129\r\nOK") == nil,
        "empty CNUM response produced a number"
    )
    try expect(
        ATResponseParser.parseSubscriberNumber(
            "+CNUM: \"Data\",\"106491234567\",129,,3\r\n" +
                "+CNUM: \"Voice\",\"13800138000\",129,,4\r\nOK"
        ) == "13800138000",
        "CNUM did not prefer the voice MSISDN over a packet-service number"
    )
    try expect(
        ATResponseParser.parseSubscriberNumber(
            "+CNUM: \"Data\",\"106491234567\",129,,3\r\nOK"
        ) == nil,
        "packet-service CNUM was exposed as a voice phone number"
    )
    try expect(
        ATResponseParser.parseSubscriberNumber(
            "+CNUM: \"Voice\",\"008613800138000\",145,,4\r\nOK"
        ) == "+8613800138000",
        "international CNUM with 00 prefix was not normalized"
    )
    try expect(
        ATResponseParser.parseSubscriberNumber(
            "+CNUM: \"\",\"89860312345678901234\",129\r\nOK"
        ) == nil,
        "ICCID-shaped CNUM payload was exposed as a phone number"
    )
    try expect(
        ATResponseParser.parseICCID("\r\n+QCCID: 89860312345678901234\r\nOK\r\n") ==
            "89860312345678901234",
        "Quectel ICCID parsing"
    )
    try expect(
        ATResponseParser.parseICCID("\r\n8986112233445566778\r\nOK\r\n") ==
            "8986112233445566778",
        "standard bare ICCID parsing"
    )
    try expect(
        ATResponseParser.parseIMSI("\r\n460001234567890\r\nOK\r\n") ==
            "460001234567890",
        "IMSI parsing"
    )

    var voiceConditioner = VoiceCaptureConditioner()
    let dcInput = [Float](repeating: 0.5, count: 48_000)
    let dcOutput = voiceConditioner.process(dcInput, sampleRate: 48_000)
    try expect(
        abs(dcOutput.suffix(1_000).reduce(0, +) / 1_000) < 0.001,
        "voice conditioner did not remove microphone DC"
    )
    voiceConditioner.reset()
    let highFrequency = (0 ..< 4_800).map { index in
        Float(sin(2 * Double.pi * 10_000 * Double(index) / 48_000))
    }
    let filteredHighFrequency = voiceConditioner.process(highFrequency, sampleRate: 48_000)
    let filteredPeak = filteredHighFrequency.suffix(2_400).map(abs).max() ?? 1
    try expect(filteredPeak < 0.2, "voice conditioner did not attenuate alias-prone audio")

    let singleSubmit = try SMSPDUEncoder.encode(
        destination: "+1234567890",
        body: "你好",
        concatenationReference: 0xAA
    )
    try expect(singleSubmit.count == 1, "short UCS-2 SMS was segmented")
    try expect(
        singleSubmit[0].pdu == "0001000A9121436587090008044F60597D",
        "short UCS-2 SMS-SUBMIT PDU"
    )
    try expect(singleSubmit[0].tpduLength == 16, "CMGS TPDU length included SMSC octet")
    try expect(SMSPDUEncoder.isValidDestination("+86 138-0013-8000"), "reply number validation")
    try expect(!SMSPDUEncoder.isValidDestination("China Telecom"), "alphanumeric sender reply validation")
    let oddDestinationSubmit = try SMSPDUEncoder.encode(
        destination: "10086",
        body: "A",
        concatenationReference: 0xAA
    )
    try expect(
        oddDestinationSubmit[0].pdu.contains("05810180F60008020041"),
        "odd-length destination semi-octet encoding"
    )
    let multipartSubmit = try SMSPDUEncoder.encode(
        destination: "10086",
        body: String(repeating: "你", count: 71),
        concatenationReference: 0xAA
    )
    try expect(multipartSubmit.count == 2, "long UCS-2 SMS segment count")
    try expect(
        multipartSubmit[0].pdu.contains("050003AA0201") &&
            multipartSubmit[1].pdu.contains("050003AA0202"),
        "multipart SMS UDH sequence"
    )
    try expect(
        multipartSubmit[0].sequence == 1 && multipartSubmit[1].sequence == 2,
        "multipart SMS sequence metadata"
    )
    let surrogateBoundary = try SMSPDUEncoder.encode(
        destination: "10086",
        body: String(repeating: "a", count: 66) + "😀" + String(repeating: "b", count: 4),
        concatenationReference: 0x55
    )
    try expect(surrogateBoundary.count == 2, "surrogate boundary SMS segment count")
    try expect(
        surrogateBoundary[1].pdu.contains("D83DDE00"),
        "multipart SMS split a UTF-16 surrogate pair"
    )
    do {
        _ = try SMSPDUEncoder.encode(
            destination: "10086;AT+CFUN=1",
            body: "blocked",
            concatenationReference: 0
        )
        throw SelfTestFailure.failed("SMS destination accepted AT injection")
    } catch is SMSPDUEncoderError {
        // Expected.
    }
    var readyCall = CallSnapshot(phase: .idle, voiceOverUSBSupported: true)
    try expect(readyCall.canDial, "clean idle call state cannot dial")
    readyCall.lastError = "last recoverable error"
    try expect(readyCall.canDial, "ordinary display error permanently blocked dialing")
    readyCall.mediaCleanupPending = true
    try expect(!readyCall.canDial, "confirmed media cleanup pending did not block a new call")
    var activeCall = CallSnapshot(phase: .active, voiceOverUSBSupported: true, audioActive: false)
    try expect(activeCall.canSendDTMF, "active call could not send network DTMF while audio was recovering")
    activeCall.mediaCleanupPending = true
    try expect(activeCall.canSendDTMF, "owned active media route incorrectly blocked DTMF")
    activeCall = CallSnapshot(phase: .alerting, voiceOverUSBSupported: true, audioActive: true)
    try expect(!activeCall.canSendDTMF, "DTMF was enabled before active CLCC")
    let outgoingCLCC = CallATParser.parseCLCC("+CLCC: 1,0,3,0,0,\"13800138000\",129")
    try expect(outgoingCLCC?.direction == .outgoing, "outgoing CLCC direction")
    try expect(outgoingCLCC?.status == .alerting, "outgoing CLCC status")
    try expect(outgoingCLCC?.number == "13800138000", "outgoing CLCC number")
    let incomingCLCC = CallATParser.parseCLCC("+CLCC: 2,1,4,0,0,\"10000\",129")
    try expect(incomingCLCC?.direction == .incoming, "incoming CLCC direction")
    try expect(incomingCLCC?.status == .incoming, "incoming CLCC status")
    try expect(
        AppNotificationRouter.route(
            actionIdentifier: AppNotificationIdentifier.answerCallAction,
            categoryIdentifier: AppNotificationIdentifier.incomingCallCategory,
            messageID: nil,
            callRecordID: nil,
            defaultActionIdentifier: "default",
            dismissActionIdentifier: "dismiss"
        ) == .answerCall,
        "incoming-call notification answer action"
    )
    try expect(
        AppNotificationRouter.route(
            actionIdentifier: AppNotificationIdentifier.rejectCallAction,
            categoryIdentifier: AppNotificationIdentifier.incomingCallCategory,
            messageID: nil,
            callRecordID: nil,
            defaultActionIdentifier: "default",
            dismissActionIdentifier: "dismiss"
        ) == .rejectCall,
        "incoming-call notification reject action"
    )
    try expect(
        AppNotificationRouter.route(
            actionIdentifier: "default",
            categoryIdentifier: AppNotificationIdentifier.messageCategory,
            messageID: "message-1",
            callRecordID: nil,
            defaultActionIdentifier: "default",
            dismissActionIdentifier: "dismiss"
        ) == .openMessage("message-1"),
        "message notification default action"
    )
    try expect(
        AppNotificationRouter.route(
            actionIdentifier: "default",
            categoryIdentifier: AppNotificationIdentifier.missedCallCategory,
            messageID: nil,
            callRecordID: "call-1",
            defaultActionIdentifier: "default",
            dismissActionIdentifier: "dismiss"
        ) == .openMissedCall("call-1"),
        "missed-call notification default action"
    )
    try expect(
        AppNotificationRouter.route(
            actionIdentifier: AppNotificationIdentifier.openCallWindowAction,
            categoryIdentifier: AppNotificationIdentifier.missedCallCategory,
            messageID: nil,
            callRecordID: "call-1",
            defaultActionIdentifier: "default",
            dismissActionIdentifier: "dismiss"
        ) == .openMissedCall("call-1"),
        "missed-call notification open action"
    )
    try expect(
        CallATParser.testResponseSupportsRawPCM("+QPCMV: (0,1),(0-2)\r\nOK\r\n"),
        "QPCMV option 0 capability"
    )
    try expect(
        CallATParser.testResponseSupportsRawPCM("+QPCMV: (0,1),(0,2)\r\nOK\r\n"),
        "QPCMV enumerated option 0 capability"
    )
    try expect(
        CallATParser.preferredMediaBackend(
            firmwareIdentity: "QDC507GLEFM21_01.001.01.007",
            supportsRawPCM: true,
            hasUSBLocation: true
        ) == .qdcModuleBridge,
        "QDC507 must take priority over its misleading QPCMV capability response"
    )
    try expect(
        CallATParser.preferredMediaBackend(
            firmwareIdentity: "EC25EFAR06A06M4G",
            supportsRawPCM: true,
            hasUSBLocation: true
        ) == .qpcmv,
        "standard EC25 raw PCM backend selection"
    )
    try expect(
        CallATParser.isQDCVoiceFirmware("QDC507GLEFM21_01.001.01.007"),
        "QDC507 firmware not recognised as UAC voice firmware"
    )
    try expect(
        CallATParser.isQDCVoiceFirmware("EG25G_QDC507"),
        "EG25-G firmware variant not recognised as UAC voice firmware"
    )
    try expect(
        !CallATParser.isQDCVoiceFirmware("EC25EFAR06A06M4G"),
        "standard EC25 misclassified as UAC voice firmware"
    )
    var callFramer = CallURCStreamFramer()
    try expect(callFramer.consume("\r\n+CLI").isEmpty, "partial CLIP emitted")
    try expect(
        callFramer.consume("P: \"10000\",129\r\n") == [.callerID("10000")],
        "split CLIP framing"
    )
    try expect(
        callFramer.consume("+QPCMV: 0,0\r\n+QPCMV: 1\r\n") == [
            .pcmFlowReady(false),
            .pcmFlowReady(true),
        ],
        "QPCMV flow-control formats"
    )
    try expect(
        callFramer.consume("RING\r\nNO CARRIER\r\n") == [.ring, .ended(.remoteHangup)],
        "call terminal URCs"
    )

    let ucs2PDU = "00040A912143658709000862702110203023044F60597D"
    let ucs2 = try SMSPDUDecoder.decode(ucs2PDU)
    try expect(ucs2.sender == "+1234567890", "UCS2 sender")
    try expect(ucs2.body == "你好", "UCS2 body")
    try expect(ucs2.concatenation == nil, "unexpected UDH")

    let gsm7PDU = "00040A91214365870900006270211020302305E8329BFD06"
    let gsm7 = try SMSPDUDecoder.decode(gsm7PDU)
    try expect(gsm7.sender == "+1234567890", "GSM-7 sender")
    try expect(gsm7.body == "hello", "GSM-7 body")

    let alphaSenderPDU = "000407D0C2A0730900006270211020302305E8329BFD06"
    let alphaSender = try SMSPDUDecoder.decode(alphaSenderPDU)
    try expect(alphaSender.sender == "BANK", "alphanumeric sender")
    try expect(alphaSender.body == "hello", "alphanumeric sender body alignment")

    let udhPDU = "00400A9121436587090000627021102030230C050003CC0201D06536FB0D"
    let udh = try SMSPDUDecoder.decode(udhPDU)
    try expect(udh.body == "hello", "GSM-7 UDH fill bits")
    try expect(udh.concatenation?.reference == 204, "8-bit concat reference")
    try expect(udh.concatenation?.referenceBits == 8, "8-bit concat width")
    try expect(udh.concatenation?.total == 2 && udh.concatenation?.sequence == 1, "concat sequence")

    try expectDecodeFailure(
        "00040A91214365870900006270211020302305E832",
        "truncated GSM-7 user data was accepted"
    )
    try expectDecodeFailure(
        "00040A912143658709000862702110203023044F60",
        "truncated UCS2 user data was accepted"
    )
    let paddedUCS2 = try SMSPDUDecoder.decode(
        "00040A912143658709000862702110203023044F60597D574F"
    )
    try expect(paddedUCS2.body == "你好", "TP-UDL did not trim extra UCS2 bytes")
    let invalidDate = try SMSPDUDecoder.decode(
        "00040A912143658709000862201310203023044F60597D"
    )
    try expect(invalidDate.timestamp == nil, "invalid SCTS date was normalized instead of rejected")
    let invalidTimezone = try SMSPDUDecoder.decode(
        "00040A9121436587090008627021102030FF044F60597D"
    )
    try expect(invalidTimezone.timestamp == nil, "invalid SCTS timezone was accepted")

    let response = "+CMGL: 7,0,,22\r\n\(ucs2PDU)FFFF\r\nOK\r\n"
    let entries = ATResponseParser.parseCMGL(response)
    try expect(entries.count == 1, "CMGL entry count")
    try expect(entries[0].index == 7, "CMGL index")
    try expect(entries[0].status == 0, "CMGL status")
    try expect(entries[0].rawPDU == ucs2PDU, "CMGL length trimming")

    let shortCMGL = ATResponseParser.parseCMGL(
        "+CMGL: 7,0,,30\r\n\(ucs2PDU)\r\nOK\r\n"
    )
    try expect(shortCMGL.isEmpty, "CMGL accepted data shorter than declared TPDU length")
    let textStatus = ATResponseParser.parseCMGL(
        "+CMGL: 8,\"REC UNREAD\",,22\r\n\(ucs2PDU)\r\nOK\r\n"
    )
    try expect(textStatus.first?.status == 0, "quoted CMGL status")
    let missingLength = ATResponseParser.parseCMGL(
        "+CMGL: 9,0\r\n\(ucs2PDU)\r\nOK\r\n"
    )
    try expect(missingLength.isEmpty, "CMGL header without TPDU length was accepted")
    try expect(
        ATResponseParser.parseCMGR("+CMGR: 0,,22\r\n\(ucs2PDU)\r\nOK\r\n") == ucs2PDU,
        "CMGR PDU"
    )
    let cmti = ATResponseParser.parseCMTI("\r\n+CMTI: \"SM\",17\r\n")
    try expect(cmti.count == 1 && cmti[0].storage == "SM" && cmti[0].index == 17, "CMTI")
    try expect(
        ATResponseParser.parseDirectCMT("+CMT: ,22\r\n\(ucs2PDU)\r\n").first == ucs2PDU,
        "direct CMT PDU"
    )
    try expect(
        ATResponseParser.parseCPMSStorage("+CPMS: \"ME\",1,255,\"ME\",1,255\r\nOK") == "ME",
        "CPMS storage"
    )
    try expect(
        ModemMessageStorageCapabilities.readableStorages(
            from: "+CPMS: (\"SM\",\"ME\",\"MT\"),(\"SM\"),(\"SM\",\"ME\")\r\nOK"
        ) == ["SM", "ME", "MT"],
        "CPMS readable storage capabilities"
    )

    var framer = ModemURCStreamFramer()
    try expect(framer.consume("\r\n+CM").messageLocations.isEmpty, "partial CMTI prefix emitted")
    let splitCMTI = framer.consume("TI: \"SM\",17\r\n")
    try expect(
        splitCMTI.messageLocations == [ModemMessageLocation(storage: "SM", index: 17)],
        "split CMTI framing"
    )

    let directPrefix = "+CMT: ,22\r\n\(ucs2PDU)\r\n+CMT: ,22\r\n"
    let firstAndPartialSecond = framer.consume(directPrefix + String(ucs2PDU.prefix(12)))
    try expect(firstAndPartialSecond.directPDUs == [ucs2PDU], "complete CMT before partial CMT was lost")
    let secondCMT = framer.consume(String(ucs2PDU.dropFirst(12)) + "\r\n")
    try expect(secondCMT.directPDUs == [ucs2PDU], "partial second CMT was not retained")

    try expect(
        framer.consume("+CMT: ,22\r\nOK\r\n+CSQ: 20,99\r\n").directPDUs.isEmpty,
        "interleaved command response emitted a direct CMT"
    )
    try expect(
        framer.consume("\(ucs2PDU)\r\n").directPDUs == [ucs2PDU],
        "interleaved command response discarded a pending direct CMT"
    )

    // Text-mode `+CMT:` deliveries — used when CellDock opts into SMS
    // reception. The header carries the originating address + SCTS, the
    // following line is the raw body (UTF-8, possibly empty or Chinese).
    try expect(
        ATResponseParser.isTextModeCMTHeader("+CMT: \"+8613812345678\",\"\",\"26/08/26,12:15:23+32\""),
        "text-mode +CMT header misclassified as PDU mode"
    )
    try expect(
        !ATResponseParser.isTextModeCMTHeader("+CMT: ,22"),
        "PDU-mode +CMT header misclassified as text mode"
    )
    let parsedTimestamp = ATResponseParser.parseSCTSTimestamp("26/08/26,12:15:23+32")
    try expect(
        parsedTimestamp != nil &&
            parsedTimestamp.map { Int($0.timeIntervalSince1970) } != nil,
        "SCTS year parsing"
    )
    try expect(
        ATResponseParser.parseSCTSTimestamp("garbage") == nil,
        "SCTS accepted garbage"
    )

    var textFramer = ModemURCStreamFramer()
    let headerLine = "+CMT: \"+8613812345678\",\"\",\"26/08/26,12:15:23+32\""
    let bodyLine = "测试短信 Hello"
    let first = textFramer.consume("\(headerLine)\r\n\(bodyLine)\r\n")
    try expect(
        first.textModeCMTs.count == 1 &&
            first.textModeCMTs.first?.message.sender == "+8613812345678" &&
            first.textModeCMTs.first?.message.body == "测试短信 Hello" &&
            first.textModeCMTs.first?.message.timestamp != nil,
        "text-mode +CMT delivery was not framed"
    )

    // Empty bodies must not crash and must still be reported as a message.
    let empty = textFramer.consume("+CMT: \"+8613800000000\",\"\",\"26/08/26,12:20:00+32\"\r\n\r\n")
    try expect(
        empty.textModeCMTs.first?.message.body == "",
        "empty text-mode body was dropped or misread"
    )

    // Malformed header — must not crash, must not emit.
    let malformed = textFramer.consume("+CMT: \r\nbroken\r\n")
    try expect(malformed.textModeCMTs.isEmpty, "malformed text-mode +CMT emitted a message")

    // Coexistence with a normal AT command response in the same buffer.
    var mixedFramer = ModemURCStreamFramer()
    let mixed = mixedFramer.consume(
        "AT+CSQ\r\n+CSQ: 20,99\r\nOK\r\n\(headerLine)\r\n\(bodyLine)\r\n"
    )
    try expect(
        mixed.textModeCMTs.first?.message.sender == "+8613812345678",
        "text-mode +CMT interleaved with AT command response was lost"
    )

    // Two consecutive text-mode deliveries must not be merged.
    let secondHeader = "+CMT: \"BANK\",\"\",\"26/08/26,12:30:00+32\""
    let secondBody = "您的验证码为 123456"
    let consecutive = textFramer.consume("\(secondHeader)\r\n\(secondBody)\r\n")
    try expect(
        consecutive.textModeCMTs.count == 1 &&
            consecutive.textModeCMTs.first?.message.body == secondBody,
        "consecutive text-mode +CMT deliveries collided"
    )

    let commandTail = framer.consume("\r\nOK\r\n+CMTI: \"ME\",")
    try expect(commandTail.messageLocations.isEmpty, "partial command-tail CMTI emitted")
    try expect(
        framer.consume("9\r\n").messageLocations == [ModemMessageLocation(storage: "ME", index: 9)],
        "command-tail CMTI was not retained"
    )

    let udhPart2PDU = udhPDU.replacingOccurrences(of: "050003CC0201", with: "050003CC0202")
    var bufferedAssembler = BufferedSMSAssembler()
    let bufferedPart1 = bufferedAssembler.ingest([
        ModemStoredPDU(
            index: -1,
            status: 0,
            declaredLength: nil,
            rawPDU: udhPDU,
            storage: nil
        )
    ])
    try expect(bufferedPart1.isEmpty, "incomplete direct multipart SMS was emitted")
    let bufferedComplete = bufferedAssembler.ingest([
        ModemStoredPDU(
            index: -1,
            status: 0,
            declaredLength: nil,
            rawPDU: udhPart2PDU,
            storage: nil
        )
    ])
    try expect(bufferedComplete.count == 1, "multipart SMS did not assemble across URC batches")
    try expect(bufferedComplete.first?.body == "hellohello", "cross-batch multipart SMS body")

    var crossStorageAssembler = BufferedSMSAssembler()
    try expect(
        crossStorageAssembler.ingest([
            ModemStoredPDU(index: 1, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM")
        ]).isEmpty,
        "cross-storage multipart emitted before completion"
    )
    let crossStorageComplete = crossStorageAssembler.ingest([
        ModemStoredPDU(index: 2, status: 0, declaredLength: nil, rawPDU: udhPart2PDU, storage: "ME")
    ])
    try expect(crossStorageComplete.count == 1, "cross-storage multipart did not assemble")
    try expect(
        Set(crossStorageComplete[0].effectiveModemReferences.map(\.storage)) == Set(["SM", "ME"]),
        "cross-storage multipart references were lost"
    )

    var duplicateAssembler = BufferedSMSAssembler()
    let duplicateComplete = duplicateAssembler.ingest([
        ModemStoredPDU(index: 1, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM"),
        ModemStoredPDU(index: 3, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM"),
        ModemStoredPDU(index: 2, status: 0, declaredLength: nil, rawPDU: udhPart2PDU, storage: "SM")
    ])
    try expect(
        duplicateComplete.first?.effectiveModemReferences.count == 3,
        "duplicate physical multipart reference was overwritten"
    )

    let deletionOrder = SMSDeletionPlanner.orderedTargets(
        from: duplicateComplete.first?.effectiveModemReferences ?? []
    )
    try expect(
        deletionOrder.map(\.index) == [3, 2, 1],
        "multipart deletion did not order storage indexes from highest to lowest"
    )
    try expect(
        SMSDeletionPlanner.orderedTargets(from: deletionOrder + deletionOrder).count == 3,
        "multipart deletion did not remove duplicate physical references"
    )
    try expect(
        SMSDeletionPlanner.isBareEmptyCMGR(["AT+CMGR=3", "OK"], index: 3),
        "QDC507 bare-OK empty CMGR response was not recognized"
    )
    try expect(
        !SMSDeletionPlanner.isBareEmptyCMGR(["+CMGR: 1,,23", "00AA", "OK"], index: 3),
        "CMGR response containing a PDU was misclassified as empty"
    )

    var expiringAssembler = BufferedSMSAssembler()
    let firstReceipt = Date(timeIntervalSince1970: 1_000)
    _ = expiringAssembler.ingest([
        ModemStoredPDU(index: 8, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM")
    ], now: firstReceipt)
    let afterRetention = firstReceipt.addingTimeInterval(25 * 60 * 60)
    _ = expiringAssembler.ingest([
        ModemStoredPDU(index: 8, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM")
    ], now: afterRetention)
    try expect(
        expiringAssembler.ingest([
            ModemStoredPDU(index: 9, status: 0, declaredLength: nil, rawPDU: udhPart2PDU, storage: "SM")
        ], now: afterRetention).isEmpty,
        "expired fragment was revived by a periodic CMGL poll"
    )

    let threePart1 = udhPDU.replacingOccurrences(of: "050003CC0201", with: "050003CC0301")
    let threePart2 = udhPDU.replacingOccurrences(of: "050003CC0201", with: "050003CC0302")
    let threePart3 = udhPDU.replacingOccurrences(of: "050003CC0201", with: "050003CC0303")
    var rollingExpiryAssembler = BufferedSMSAssembler()
    _ = rollingExpiryAssembler.ingest([
        ModemStoredPDU(index: 20, status: 0, declaredLength: nil, rawPDU: threePart1, storage: "SM")
    ], now: firstReceipt)
    _ = rollingExpiryAssembler.ingest([
        ModemStoredPDU(index: 21, status: 0, declaredLength: nil, rawPDU: threePart2, storage: "SM")
    ], now: firstReceipt.addingTimeInterval(23 * 60 * 60))
    try expect(
        rollingExpiryAssembler.ingest([
            ModemStoredPDU(index: 22, status: 0, declaredLength: nil, rawPDU: threePart3, storage: "SM")
        ], now: afterRetention).isEmpty,
        "a newer fragment kept an expired older fragment alive"
    )

    let duplicateSingles = SMSPDUDecoder.assemble([
        ModemStoredPDU(index: 11, status: 0, declaredLength: nil, rawPDU: ucs2PDU, storage: "SM"),
        ModemStoredPDU(index: 12, status: 0, declaredLength: nil, rawPDU: ucs2PDU, storage: "SM")
    ])
    let mergedDuplicateSingles = SMSMessageMerger.merge(existing: [], incoming: duplicateSingles)
    try expect(mergedDuplicateSingles.messages.count == 1, "duplicate physical single SMS was shown twice")
    try expect(
        mergedDuplicateSingles.messages[0].effectiveModemReferences.count == 2,
        "duplicate physical single SMS reference was lost"
    )

    let storedMessage = SMSMessage(
        id: "stored",
        modemIndices: [7],
        modemStorage: "SM",
        sender: "+123",
        body: "kept",
        timestamp: Date(timeIntervalSince1970: 100),
        rawPDUs: [ucs2PDU],
        isRead: false,
        firstSeenAt: Date(timeIntervalSince1970: 100)
    )
    var deletionConfirmation = SMSDeletionConfirmationState()
    deletionConfirmation.request(storedMessage)
    try expect(
        deletionConfirmation.pendingMessageID == storedMessage.id,
        "delete request lost message identity"
    )
    var refreshedStoredMessage = storedMessage
    refreshedStoredMessage.replaceModemReferences(with: [
        ModemPDUReference(
            storedPDU: ModemStoredPDU(
                index: 19,
                status: 1,
                declaredLength: nil,
                rawPDU: ucs2PDU,
                storage: "MT"
            )
        )!,
    ])
    try expect(
        deletionConfirmation.resolve(in: [refreshedStoredMessage])?
            .effectiveModemReferences.first?.index == 19,
        "delete confirmation retained a stale message snapshot"
    )
    deletionConfirmation.cancel()
    try expect(!deletionConfirmation.isPresented, "delete cancel left confirmation presented")
    try expect(
        deletionConfirmation.takeConfirmedMessageID(id: storedMessage.id) == nil,
        "delete cancel still returned an identity"
    )
    deletionConfirmation.request(storedMessage)
    try expect(
        deletionConfirmation.takeConfirmedMessageID(id: storedMessage.id) == storedMessage.id,
        "delete confirm did not return the requested identity"
    )
    try expect(
        deletionConfirmation.takeConfirmedMessageID(id: storedMessage.id) == nil,
        "delete confirmation could be submitted twice"
    )
    deletionConfirmation.request(storedMessage)
    deletionConfirmation.reconcile(with: [])
    try expect(
        !deletionConfirmation.isPresented,
        "delete confirmation survived removal of its message"
    )
    let unrelatedMessage = SMSMessage(
        id: "new",
        modemIndices: [3],
        modemStorage: "ME",
        sender: "+456",
        body: "new",
        timestamp: Date(timeIntervalSince1970: 200),
        rawPDUs: [gsm7PDU],
        isRead: false,
        firstSeenAt: Date(timeIntervalSince1970: 200)
    )
    let merged = SMSMessageMerger.merge(existing: [storedMessage], incoming: [unrelatedMessage])
    try expect(
        merged.messages.first(where: { $0.id == "stored" })?.modemIndices == [7],
        "incremental merge erased another storage's modem reference"
    )
    let emptyReferenceRefresh = SMSMessage(
        id: "stored",
        modemIndices: [],
        modemStorage: nil,
        sender: storedMessage.sender,
        body: storedMessage.body,
        timestamp: storedMessage.timestamp,
        rawPDUs: storedMessage.rawPDUs,
        isRead: true,
        firstSeenAt: Date(timeIntervalSince1970: 300)
    )
    let refreshed = SMSMessageMerger.merge(existing: [storedMessage], incoming: [emptyReferenceRefresh])
    try expect(refreshed.messages.first?.modemIndices == [7], "empty incremental reference erased stored index")
    try expect(refreshed.messages.first?.modemStorage == "SM", "empty incremental reference erased storage")

    let legacyMessageJSON = """
    {
      "id": "legacy",
      "modemIndices": [7],
      "modemStorage": "SM",
      "sender": "+123",
      "body": "legacy",
      "timestamp": 0,
      "rawPDUs": ["\(ucs2PDU)"],
      "isRead": false,
      "firstSeenAt": 0
    }
    """
    let legacyMessage = try JSONDecoder().decode(
        SMSMessage.self,
        from: Data(legacyMessageJSON.utf8)
    )
    try expect(legacyMessage.modemReferences == nil, "legacy JSON synthesized missing references")
    try expect(legacyMessage.readAt == nil, "legacy JSON synthesized a read timestamp")
    try expect(legacyMessage.direction == nil, "legacy JSON synthesized a message direction")
    try expect(legacyMessage.deliveryState == nil, "legacy JSON synthesized a delivery state")
    try expect(legacyMessage.effectiveModemReferences.count == 1, "legacy JSON reference fallback")

    var storageSync = MessageStorageSyncTracker()
    try expect(storageSync.markSuccessfulPoll(of: "SM"), "first SM poll was not initial")
    try expect(!storageSync.markSuccessfulPoll(of: "sm"), "second SM poll was treated as initial")
    try expect(storageSync.markSuccessfulPoll(of: "ME"), "first delayed ME poll was not initial")
    storageSync.reset()
    try expect(storageSync.markSuccessfulPoll(of: "SM"), "storage sync reset did not restore initial state")

    let qcsq = ATResponseParser.parseQCSQ("\r\n+QCSQ: \"LTE\",-65,-96,140,-11\r\nOK\r\n")
    try expect(qcsq?.dbm == -96, "QCSQ RSRP")
    try expect(qcsq?.technology == "LTE", "QCSQ RAT")
    try expect(qcsq?.detail.contains("SINR raw 140") == true, "QCSQ SINR diagnostics")
    try expect(ModemSnapshot().initialSetupState == .insertModule, "setup did not request module")
    let djiUSBConfiguration = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,0\r\nOK"
    )
    try expect(djiUSBConfiguration?.isSafeDJISource == true, "recorded DJI USBCFG parsing")
    try expect(djiUSBConfiguration?.audioEnabled == false, "DJI source audio flag")
    let transitionalUSBConfiguration = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2C7C,0x125,1,1,1,1,1,0,1\r\nOK"
    )
    try expect(
        transitionalUSBConfiguration?.isSafeIdentityConversionSource == true,
        "CellDock ADB-disabled transition tuple was not accepted as a safe conversion source"
    )
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2CA3:4006",
            usbNetMode: 1,
            usbConfiguration: transitionalUSBConfiguration
        ).initialSetupState == .needsIdentityConversion,
        "physical DJI identity with the exact transition tuple could not resume conversion"
    )
    let maVoUSBConfiguration = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2C7C,0x125,1,1,1,1,1,1,1\r\nOK"
    )
    try expect(maVoUSBConfiguration?.isCellDockTarget == true, "CellDock target USBCFG parsing")
    try expect(maVoUSBConfiguration?.adbEnabled == true, "CellDock target ADB flag")
    try expect(
        ModemUSBConfiguration.maVoTarget.usbcfgWriteCommand ==
            "AT+QCFG=\"USBCFG\",0x2C7C,0x0125,1,1,1,1,1,1,1",
        "CellDock target USBCFG write command"
    )
    // Test 1 — DJI original (audio/UAC=1) is a legal profile.
    let djiOriginalProfile = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1,1\r\nOK"
    )
    try expect(djiOriginalProfile?.usbProfile == .djiOriginal, "audio=1 QDC507 was not DJI original")
    try expect(djiOriginalProfile?.isRecognizedQDC507Profile == true, "DJI original profile was not recognized")
    // Test 2 — CellDock compatible (audio/UAC=0) is a legal profile.
    let cellDockCompatibleProfile = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1,0\r\nOK"
    )
    try expect(
        cellDockCompatibleProfile?.usbProfile == .cellDockCompatible,
        "audio=0 QDC507 was not CellDock compatible"
    )
    try expect(
        cellDockCompatibleProfile?.isRecognizedQDC507Profile == true,
        "CellDock compatible audio=0 profile was incorrectly marked needs configuration"
    )
    // Test 3 — NET disabled should not be an acceptable VoWiFi-ready profile.
    let netDisabled = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,0,1,0\r\nOK"
    )
    try expect(netDisabled?.usbProfile == .unsupported, "net=0 was not classified as unsupported")
    // Test 4 — AT disabled should not be an acceptable VoWiFi-ready profile.
    let atDisabled = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,0,1,1,1,0\r\nOK"
    )
    try expect(atDisabled?.usbProfile == .unsupported, "at=0 was not classified as unsupported")
    // Test 5 — only the audio/UAC field differs between original and compatible.
    try expect(
        djiOriginalProfile != nil && cellDockCompatibleProfile != nil &&
            djiOriginalProfile!.vendorID == cellDockCompatibleProfile!.vendorID &&
            djiOriginalProfile!.productID == cellDockCompatibleProfile!.productID &&
            djiOriginalProfile!.diagnosticEnabled == cellDockCompatibleProfile!.diagnosticEnabled &&
            djiOriginalProfile!.nmeaEnabled == cellDockCompatibleProfile!.nmeaEnabled &&
            djiOriginalProfile!.atPortEnabled == cellDockCompatibleProfile!.atPortEnabled &&
            djiOriginalProfile!.modemEnabled == cellDockCompatibleProfile!.modemEnabled &&
            djiOriginalProfile!.networkEnabled == cellDockCompatibleProfile!.networkEnabled &&
            djiOriginalProfile!.adbEnabled == cellDockCompatibleProfile!.adbEnabled &&
            djiOriginalProfile!.audioEnabled != cellDockCompatibleProfile!.audioEnabled,
        "original vs compatible diffs went beyond the audio/UAC field"
    )
    // Test 6 — VoWiFi preflight uses cellDockCompatible audio=0 without a USB
    // config guard blocking it: the snapshot must not be "needs configuration".
    let compatibleReady = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        usbNetMode: 1,
        usbConfiguration: cellDockCompatibleProfile
    )
    try expect(
        compatibleReady.usbConfiguration?.usbProfile == .cellDockCompatible,
        "compatible profile not recognized before preflight check"
    )
    try expect(
        compatibleReady.initialSetupState != .unsupportedUSBConfiguration(compatibleReady.usbConfiguration!.compactDescription),
        "audio=0 profile was gated by USB configuration validation"
    )
    try expect(
        compatibleReady.initialSetupState == .ready,
        "audio=0 usbnet=1 QDC507 was not classified as ready"
    )
    try expect(
        compatibleReady.operationalState == .ready,
        "audio=0 QDC507 did not reach a ready operational state"
    )
    // adb=0 must remain a Configuration Required / unsupported profile.
    let adbDisabled = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,0,0\r\nOK"
    )
    try expect(adbDisabled?.usbProfile == .unsupported, "adb=0 was not classified as unsupported")
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2C7C:0125",
            usbNetMode: 1,
            usbConfiguration: adbDisabled
        ).operationalState == .configurationRequired,
        "adb=0 QDC507 was not marked configuration required"
    )
    // Wrong VID/PID identity must be unsupported, never a valid profile.
    let wrongIdentity = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2C7C,0x9999,1,1,1,1,1,1,0\r\nOK"
    )
    try expect(wrongIdentity?.usbProfile == .unsupported, "unrecognized product ID was not unsupported")
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2C7C:9999",
            usbNetMode: 1,
            usbConfiguration: wrongIdentity
        ).operationalState == .configurationRequired,
        "unrecognized identity was not classified as needing configuration"
    )
    // Malformed USBCFG must fail to parse (→ error path, never ready).
    try expect(
        ATResponseParser.parseUSBConfiguration("+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1\r\nOK") == nil,
        "malformed USBCFG was parsed as a valid configuration"
    )
    // VoWiFi unavailable + a valid module must still be Ready: the module's
    // operational state is decoupled from optional VoWiFi / Voice runtimes.
    let voWiFiDisabledButModuleValid = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        voiceRegistrationState: .notRegistered,
        usbNetMode: 1,
        volteSessionAvailable: false,
        usbConfiguration: cellDockCompatibleProfile
    )
    try expect(
        voWiFiDisabledButModuleValid.operationalState == ModemOperationalState.ready,
        "optional VoWiFi/Voice unavailability incorrectly blocked module Ready"
    )

    // ---- Module status UI presentation mapping ----
    // ready + cellDockCompatible (audio=0) → Ready / Valid / Mobile.
    let compatiblePanel = ModemModuleStatusPresentation.derive(snapshot: compatibleReady)
    try expect(compatiblePanel.status == .ready, "compatible module status was not ready")
    try expect(compatiblePanel.configuration == .valid, "compatible module config was not valid")
    try expect(compatiblePanel.profile == .cellDockCompatible, "compatible module profile mismatch")
    try expect(compatiblePanel.usbMode == .mobile, "compatible audio=0 was not mobile mode")
    try expect(compatiblePanel.audio == .disabled, "compatible audio was not disabled")
    try expect(compatiblePanel.at == .available, "compatible AT was not available")
    try expect(compatiblePanel.network == .available, "compatible NET was not available")
    try expect(compatiblePanel.adb == .available, "compatible ADB was not available")
    // ready + djiOriginal (audio=1) → Ready / Valid / Mac.
    let originalReady = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        usbNetMode: 1,
        usbConfiguration: djiOriginalProfile
    )
    let originalPanel = ModemModuleStatusPresentation.derive(snapshot: originalReady)
    try expect(originalPanel.status == .ready, "original module status was not ready")
    try expect(originalPanel.configuration == .valid, "original module config was not valid")
    try expect(originalPanel.profile == .djiOriginal, "original module profile mismatch")
    try expect(originalPanel.usbMode == .mac, "original audio=1 was not mac mode")
    try expect(originalPanel.audio == .enabled, "original audio was not enabled")
    // unsupported net=0 → Configuration Required / network unavailable.
    let netOffReady = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        usbNetMode: 1,
        usbConfiguration: netDisabled
    )
    let netOffPanel = ModemModuleStatusPresentation.derive(snapshot: netOffReady)
    try expect(netOffPanel.status == .configurationRequired, "net=0 status was not configuration required")
    try expect(netOffPanel.network == .unavailable, "net=0 network was not unavailable")
    try expect(
        netOffPanel.configuration == .needsRepair(.networkDisabled),
        "net=0 did not report a concrete network interface problem"
    )
    try expect(netOffPanel.usbMode == .unknown, "unsupported profile should not imply a USB mode")
    // Disconnected → Disconnected.
    let disconnectedPanel = ModemModuleStatusPresentation.derive(snapshot: ModemSnapshot())
    try expect(disconnectedPanel.status == .disconnected, "empty modem was not disconnected")
    try expect(
        disconnectedPanel.configuration == .needsRepair(.malformed),
        "empty modem did not report malformed/missing USBCFG"
    )
    try expect(
        ATResponseParser.parseQADBKeyChallenge("\r\n+QADBKEY: 10827907\r\n\r\nOK\r\n") == "10827907",
        "QADBKEY challenge parsing"
    )
    try expect(
        ATResponseParser.parseQADBKeyChallenge("+QADBKEY: 1082790X\r\nOK") == nil,
        "QADBKEY parser accepted a malformed challenge"
    )
    let qadbKeyVectors = [
        "42790187": "cQfD.paNjDkltja",
        "17115309": "uWwxCQMVOz9IcTW",
        "33000465": "dhbXHZ/9doGNS4T"
    ]
    for (challenge, expected) in qadbKeyVectors {
        try expect(
            QADBKeyDeriver.response(for: challenge) == expected,
            "QADBKEY MD5-crypt vector \(challenge)"
        )
    }
    try expect(QADBKeyDeriver.response(for: "1234") == nil, "short QADBKEY challenge was accepted")
    try expect(ATResponseParser.parseSIMState("+CPIN: READY\r\nOK") == .ready, "SIM ready parsing")
    try expect(ATResponseParser.parseSIMState("+CPIN: SIM PIN\r\nOK") == .pinRequired, "SIM PIN parsing")
    try expect(ATResponseParser.parseSIMState("+CPIN: SIM PUK\r\nOK") == .pukRequired, "SIM PUK parsing")
    try expect(ATResponseParser.parseSIMState("+CME ERROR: 10") == .absent, "numeric SIM absent parsing")
    try expect(
        ATResponseParser.parseSIMState("+CME ERROR: SIM not inserted") == .absent,
        "text SIM absent parsing"
    )
    try expect(ATResponseParser.parseSIMState("ERROR") == nil, "generic SIM error was classified as a card state")
    try expect(
        ATResponseParser.parseRegistrationState("+CEREG: 2,1,\"1234\",\"5678\",7\r\nOK") == .registered,
        "CEREG registered parsing"
    )
    try expect(
        ATResponseParser.parseRegistrationState("+CEREG: 5\r\nOK") == .roaming,
        "CEREG roaming short-form parsing"
    )
    try expect(
        ATResponseParser.parseRegistrationState("+CEREG: 2,3\r\nOK") == .denied,
        "CEREG denied parsing"
    )
    try expect(
        ATResponseParser.parseRegistrationState("+CREG: 2,5\r\nOK", prefix: "+CREG") == .roaming,
        "CREG roaming parsing"
    )
    try expect(ModemSnapshot().operationalState == .absent, "empty modem was not absent")
    try expect(
        ModemSnapshot(state: .connecting).operationalState == .enumerating,
        "connecting modem without USB identity was not enumerating"
    )
    try expect(
        ModemSnapshot(state: .connecting, usbIdentity: "2C7C:0125").operationalState == .initializing,
        "connecting modem with USB identity was not initializing"
    )
    try expect(
        ModemSnapshot(
            state: .connecting,
            lifecyclePhase: .restarting,
            usbIdentity: "2C7C:0125"
        ).operationalState == .restarting,
        "planned restart did not override the low-level connection state"
    )
    try expect(
        ModemSnapshot(
            state: .connecting,
            lifecyclePhase: .reconnecting,
            usbIdentity: "2C7C:0125"
        ).operationalState == .reconnecting,
        "planned reconnect did not override the low-level connection state"
    )
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2C7C:0125",
            usbNetMode: 0,
            usbConfiguration: .maVoTarget
        ).initialSetupState == .needsECM,
        "QDC507 usbnet=0 was not classified as needing initialization"
    )
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2C7C:0125",
            usbNetMode: 1,
            usbConfiguration: .maVoTarget
        ).initialSetupState == .ready,
        "QDC507 usbnet=1 was not classified as ready"
    )
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2C7C:0125",
            usbNetMode: 1,
            usbConfiguration: .maVoTargetWithoutADB
        ).operationalState == .configurationRequired,
        "ADB-disabled target identity was incorrectly marked ready"
    )
    let registeredModem = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        simState: .ready,
        registrationState: .registered,
        usbNetMode: 1,
        usbConfiguration: .maVoTarget
    )
    var likelyDataOnlyModem = registeredModem
    likelyDataOnlyModem.voiceRegistrationState = .notRegistered
    likelyDataOnlyModem.volteSessionAvailable = false
    try expect(
        likelyDataOnlyModem.voiceServiceAvailability == .likelyDataOnly,
        "packet-only registration was not classified as likely data-only"
    )
    likelyDataOnlyModem.voiceRegistrationState = .roaming
    try expect(
        likelyDataOnlyModem.voiceServiceAvailability == .likelyDataOnly,
        "CREG roaming incorrectly proved that a data-registered SIM supports voice"
    )
    var volteModem = likelyDataOnlyModem
    volteModem.volteSessionAvailable = true
    try expect(
        volteModem.voiceServiceAvailability == .available,
        "available VoLTE session was not classified as voice-capable"
    )
    var numberlessUnknownModem = registeredModem
    numberlessUnknownModem.simPhoneNumber = nil
    try expect(
        numberlessUnknownModem.voiceServiceAvailability == .unknown,
        "missing phone number incorrectly proved that the SIM was data-only"
    )
    let activeECMNetwork = CellularNetworkStatus(
        isEnabled: true,
        isActive: true,
        isLinkActive: true,
        isHardwarePresent: true,
        ipv4Address: "192.168.225.2",
        ipv4Router: "192.168.225.1"
    )
    try expect(
        CellularDataConnectionPolicy.state(
            modem: registeredModem,
            network: activeECMNetwork,
            isPresentedEnabled: true,
            isChangingNetwork: false,
            isRecovering: false
        ) == .available,
        "registered SIM with an active ECM route was not data-available"
    )
    var noSIMModem = registeredModem
    noSIMModem.simState = .absent
    noSIMModem.registrationState = .unavailable
    try expect(
        CellularDataConnectionPolicy.state(
            modem: noSIMModem,
            network: activeECMNetwork,
            isPresentedEnabled: true,
            isChangingNetwork: false,
            isRecovering: false
        ) == .interfaceReady,
        "active ECM interface without a ready SIM was incorrectly marked data-available"
    )
    try expect(
        CellularDataConnectionPolicy.state(
            modem: registeredModem,
            network: activeECMNetwork,
            isPresentedEnabled: false,
            isChangingNetwork: false,
            isRecovering: false
        ) == .disabled,
        "disabled cellular service did not override active interface state"
    )
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2CA3:4006",
            usbNetMode: 0,
            usbConfiguration: djiUSBConfiguration
        ).initialSetupState == .needsIdentityConversion,
        "exact DJI identity was not offered one-click conversion"
    )
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2CA3:4006",
            usbNetMode: 0,
            usbConfiguration: ModemUSBConfiguration(
                vendorID: 0x2CA3,
                productID: 0x4006,
                diagnosticEnabled: true,
                nmeaEnabled: true,
                atPortEnabled: true,
                modemEnabled: true,
                networkEnabled: true,
                adbEnabled: true,
                audioEnabled: false
            )
        ).initialSetupState != .needsIdentityConversion,
        "unknown DJI interface tuple was offered conversion"
    )
    try expect(ATResponseParser.parseCSQ("+CSQ: 20,99\r\nOK") == -73, "CSQ conversion")
    try expect(
        ATResponseParser.parseIMSMode("+QCFG: \"ims\",0,1\r\nOK") == 0,
        "IMS mode zero parsing"
    )
    try expect(
        ATResponseParser.parseIMSMode("AT+QCFG=\"ims\"\r\n+QCFG: \"ims\",1,1\r\nOK") == 1,
        "IMS mode one parsing"
    )
    try expect(
        ATResponseParser.parseIMSMode("+QCFG: \"usbnet\",1\r\nOK") == nil,
        "unrelated QCFG parsed as IMS"
    )
    try expect(
        ATResponseParser.parseVoLTESessionAvailable("+QCFG: \"ims\",0,1\r\nOK") == true,
        "VoLTE available parsing"
    )
    try expect(
        ATResponseParser.parseVoLTESessionAvailable("+QCFG: \"ims\",1,0\r\nOK") == false,
        "VoLTE unavailable parsing"
    )
    try expect(
        ATResponseParser.parseVoLTESessionAvailable("+QCFG: \"ims\",1\r\nOK") == nil,
        "missing VoLTE capability was treated as unavailable"
    )
    try expect(
        ATResponseParser.parseVoLTEDisabled("+QCFG: \"volte/disable\",0\r\nOK") == false,
        "VoLTE enabled state parsing"
    )
    try expect(
        ATResponseParser.parseVoLTEDisabled("+QCFG: \"volte_disable\",1\r\nOK") == true,
        "VoLTE disabled state parsing"
    )
    try expect(
        ATResponseParser.parseOperator("+COPS: 0,0,\"CHN-CT\",7\r\nOK").name == "中国电信",
        "CHN-CT carrier localization"
    )
    try expect(CarrierNameFormatter.localized("CMCC") == "中国移动", "CMCC localization")
    try expect(CarrierNameFormatter.localized("China Unicom") == "中国联通", "Unicom localization")
    try expect(CarrierNameFormatter.localized("46015") == "中国广电", "Broadnet PLMN localization")
    try expect(
        CarrierNameFormatter.localized("Vodafone UK") == "Vodafone UK",
        "unknown carrier name should be preserved"
    )
    let recoverableNetwork = CellularNetworkStatus(
        isEnabled: true,
        isActive: false,
        isLinkActive: false,
        isHardwarePresent: true
    )
    let recoverableModem = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        usbNetMode: 1
    )
    var nonPrioritizedNetwork = recoverableNetwork
    nonPrioritizedNetwork.serviceID = "cellular-service"
    nonPrioritizedNetwork.isPrioritized = false
    try expect(
        CellularNetworkPriorityPolicy.shouldAutoPromote(
            network: nonPrioritizedNetwork,
            modem: recoverableModem,
            isChangingNetwork: false,
            attemptedServiceID: nil
        ),
        "enabled ECM service did not request automatic priority"
    )
    try expect(
        !CellularNetworkPriorityPolicy.shouldAutoPromote(
            network: nonPrioritizedNetwork,
            modem: recoverableModem,
            desiredMode: .standby,
            isChangingNetwork: false,
            attemptedServiceID: nil
        ),
        "standby ECM service incorrectly requested automatic priority"
    )
    try expect(
        !CellularNetworkPriorityPolicy.shouldAutoPromote(
            network: nonPrioritizedNetwork,
            modem: recoverableModem,
            isChangingNetwork: false,
            attemptedServiceID: "cellular-service"
        ),
        "automatic priority retried the same service without a state change"
    )
    var prioritizedNetwork = nonPrioritizedNetwork
    prioritizedNetwork.isPrioritized = true
    try expect(
        !CellularNetworkPriorityPolicy.shouldAutoPromote(
            network: prioritizedNetwork,
            modem: recoverableModem,
            isChangingNetwork: false,
            attemptedServiceID: nil
        ),
        "already prioritized ECM service requested another promotion"
    )
    var disabledStartupNetwork = recoverableNetwork
    disabledStartupNetwork.isEnabled = false
    try expect(
        CellularNetworkPresentationPolicy.effectiveEnabled(
            actualEnabled: false,
            pendingEnabled: true
        ),
        "pending cellular enable did not expand the network details"
    )
    try expect(
        !CellularNetworkPresentationPolicy.effectiveEnabled(
            actualEnabled: true,
            pendingEnabled: false
        ),
        "pending cellular disable did not collapse the network details"
    )
    try expect(
        CellularNetworkPresentationPolicy.effectiveEnabled(
            actualEnabled: true,
            pendingEnabled: nil
        ),
        "settled enabled cellular state did not keep its details expanded"
    )
    try expect(
        !CellularNetworkPresentationPolicy.effectiveEnabled(
            actualEnabled: false,
            pendingEnabled: nil
        ),
        "settled disabled cellular state did not keep its details collapsed"
    )
    try expect(
        CellularNetworkStartupPolicy.shouldRestore(
            network: disabledStartupNetwork,
            modem: recoverableModem,
            isChangingNetwork: false,
            restorePending: true,
            restoreInFlight: false
        ),
        "disabled ECM service was not restored on a fresh app launch"
    )
    try expect(
        !CellularNetworkStartupPolicy.shouldRestore(
            network: disabledStartupNetwork,
            modem: recoverableModem,
            isChangingNetwork: false,
            restorePending: false,
            restoreInFlight: false
        ),
        "explicitly dismissed startup restore was retried"
    )
    try expect(
        !CellularNetworkStartupPolicy.shouldRestore(
            network: disabledStartupNetwork,
            modem: recoverableModem,
            isChangingNetwork: true,
            restorePending: true,
            restoreInFlight: false
        ),
        "startup restore raced an in-flight user operation"
    )
    try expect(
        CellularNetworkStartupPolicy.shouldRestore(
            network: recoverableNetwork,
            modem: recoverableModem,
            isChangingNetwork: false,
            restorePending: true,
            restoreInFlight: false,
            desiredMode: .off
        ),
        "persisted disabled state was not restored for the same module"
    )
    var standbyNetwork = recoverableNetwork
    standbyNetwork.isDemoted = true
    try expect(
        CellularNetworkStartupPolicy.isApplied(.standby, to: standbyNetwork) &&
            !CellularNetworkStartupPolicy.isApplied(.preferred, to: standbyNetwork),
        "standby cellular mode was confused with preferred mode"
    )
    let originalServiceOrder = ["wifi", "cellular-1", "ethernet", "cellular-2"]
    let cellularServiceIDs: Set<String> = ["cellular-1", "cellular-2"]
    try expect(
        CellularNetworkServiceOrderPolicy.appliedOrder(
            mode: .preferred,
            targetServiceID: "cellular-1",
            originalOrder: originalServiceOrder,
            cellularServiceIDs: cellularServiceIDs
        ) == ["cellular-1", "wifi", "ethernet", "cellular-2"] &&
            CellularNetworkServiceOrderPolicy.appliedOrder(
                mode: .standby,
                targetServiceID: "cellular-1",
                originalOrder: originalServiceOrder,
                cellularServiceIDs: cellularServiceIDs
            ) == ["wifi", "ethernet", "cellular-1", "cellular-2"] &&
            CellularNetworkServiceOrderPolicy.appliedOrder(
                mode: .off,
                targetServiceID: "cellular-1",
                originalOrder: originalServiceOrder,
                cellularServiceIDs: cellularServiceIDs
            ) == originalServiceOrder,
        "cellular service order policy did not preserve the three network modes"
    )
    let multiModuleOrder = ["wifi", "cellular-1", "ethernet", "cellular-2", "cellular-3"]
    let multiModuleCellularIDs: Set<String> = ["cellular-1", "cellular-2", "cellular-3"]
    try expect(
        CellularNetworkServiceOrderPolicy.appliedOrder(
            preferredServiceID: "cellular-2",
            standbyServiceIDs: ["cellular-1", "cellular-3"],
            originalOrder: multiModuleOrder,
            cellularServiceIDs: multiModuleCellularIDs
        ) == ["cellular-2", "wifi", "ethernet", "cellular-1", "cellular-3"],
        "multi-module policy did not keep exactly one preferred service before non-cellular services"
    )
    try expect(
        CellularNetworkServiceOrderPolicy.appliedOrder(
            preferredServiceID: nil,
            standbyServiceIDs: ["cellular-1", "cellular-3"],
            originalOrder: multiModuleOrder,
            cellularServiceIDs: multiModuleCellularIDs
        ) == ["wifi", "ethernet", "cellular-1", "cellular-3", "cellular-2"],
        "multi-module policy did not keep standby services behind non-cellular services"
    )
    let validNetworkConfiguration = CellularNetworkConfigurationRequest(
        preferredLocationID: 1,
        standbyLocationIDs: [2, 3],
        offLocationIDs: [4, 5]
    )
    let overlappingNetworkConfiguration = CellularNetworkConfigurationRequest(
        preferredLocationID: 1,
        standbyLocationIDs: [1, 2],
        offLocationIDs: [3]
    )
    let duplicateNetworkConfiguration = CellularNetworkConfigurationRequest(
        preferredLocationID: nil,
        standbyLocationIDs: [2, 2],
        offLocationIDs: []
    )
    try expect(
        validNetworkConfiguration.isValid &&
            validNetworkConfiguration.enabledLocationIDs == [1, 2, 3] &&
            !overlappingNetworkConfiguration.isValid &&
            !duplicateNetworkConfiguration.isValid,
        "multi-module network request validation accepted overlapping or duplicate locations"
    )
    try expect(
        ATResponseParser.parseIMEI("\r\n+CGSN: 867075070123456\r\nOK\r\n") ==
            "867075070123456",
        "IMEI parsing"
    )
    let activationCode = try ESIMActivationCode(
        rawValue: "  LPA:1$smdp.example.com$MATCHING-ID$1.2.840.113549$1  "
    )
    try expect(
        activationCode.smdpAddress == "smdp.example.com" &&
            activationCode.matchingID == "MATCHING-ID" &&
            activationCode.oid == "1.2.840.113549" &&
            activationCode.confirmationCodeRequired,
        "eSIM activation code parsing"
    )
    try expect(
        (try? ESIMActivationCode(rawValue: "https://example.com/activation")) == nil &&
            (try? ESIMActivationCode(rawValue: "LPA:1$http://example.com$MATCHING")) == nil &&
            (try? ESIMActivationCode(rawValue: "LPA:1$smdp.example.com$bad value")) == nil,
        "unsafe eSIM activation code was accepted"
    )
    let tlsFailure = EUICCHTTPFailure(error: URLError(.secureConnectionFailed))
    try expect(
        tlsFailure.kind == .tlsTrust &&
            tlsFailure.diagnosticCode == "tls_trust:NSURLErrorDomain:-1200" &&
            tlsFailure.userMessage.contains("HTTPS 代理"),
        "eSIM TLS trust failure was not classified safely"
    )
    let timeoutFailure = EUICCHTTPFailure(error: URLError(.timedOut))
    try expect(
        timeoutFailure.kind == .timedOut && timeoutFailure.userMessage.contains("超时"),
        "eSIM HTTP timeout was not classified"
    )
    try expect(
        EUICCHTTPFailure(error: NSError(domain: "PrivateTransport", code: 7))
            .diagnosticCode == "transport:network:7",
        "eSIM HTTP diagnostics exposed an arbitrary error domain"
    )
    let downloadStageMessage =
        "eSIM download failed stage=initiate_authentication: HTTP transport failed"
    try expect(
        ESIMDownloadStage.extract(from: downloadStageMessage) == .initiateAuthentication &&
            ESIMDownloadStage.extract(from: "server message stage=private_value") == nil,
        "eSIM download failure stage parsing"
    )
    let cellularDefaultsName = "CellDockSelfTests.CellularPreferences.\(UUID().uuidString)"
    guard let cellularDefaults = UserDefaults(suiteName: cellularDefaultsName) else {
        throw SelfTestFailure.failed("unable to create isolated cellular preferences")
    }
    defer { cellularDefaults.removePersistentDomain(forName: cellularDefaultsName) }
    let cellularPreferences = CellularNetworkingPreferenceStore(
        defaults: cellularDefaults,
        key: "test.preferences",
        legacyKey: "test.legacy-preferences"
    )
    try expect(
        cellularPreferences.preferredMode(forModule: "867075070123456") == nil,
        "unknown module unexpectedly had a cellular preference"
    )
    try expect(
        CellularNetworkMode.defaultConnectionMode == .standby,
        "a new cellular module no longer defaults to keeping its connection"
    )
    cellularPreferences.setPreferredMode(.standby, forModule: "867075070123456")
    cellularPreferences.setPreferredMode(.preferred, forModule: "867075070654321")
    try expect(
        cellularPreferences.preferredMode(forModule: "867075070123456") == .standby &&
            cellularPreferences.preferredMode(forModule: "867075070654321") == .preferred,
        "per-module cellular preferences were not stored independently"
    )
    cellularDefaults.set(
        ["867075070999999": false, "867075070888888": true],
        forKey: "test.legacy-preferences"
    )
    // Migrating the v1 flag restores connectivity but never cellular priority:
    // that is an exclusive state and must stay an explicit user choice.
    try expect(
        cellularPreferences.preferredMode(forModule: "867075070999999") == .off &&
            cellularPreferences.preferredMode(forModule: "867075070888888") == .standby,
        "legacy Boolean cellular preferences were not migrated on read"
    )

    let moduleOneID = CellularModuleID(rawValue: "usb-location-1")
    let moduleTwoID = CellularModuleID(rawValue: "usb-location-2")
    let encodedModuleID = try JSONEncoder().encode(moduleOneID)
    let decodedModuleID = try JSONDecoder().decode(
        CellularModuleID.self,
        from: encodedModuleID
    )
    try expect(
        decodedModuleID == moduleOneID,
        "cellular module ID did not survive persistence"
    )

    // MARK: Multi-module cellular network mode regression matrix

    let moduleThreeID = CellularModuleID(rawValue: "usb-location-3")
    let allModuleIDs = [moduleOneID, moduleTwoID, moduleThreeID]

    func planMode(
        _ mode: CellularNetworkMode,
        for moduleID: CellularModuleID,
        from currentModes: [CellularModuleID: CellularNetworkMode],
        replacing replacementMode: CellularNetworkMode? = nil,
        moduleIDs: [CellularModuleID]? = nil
    ) -> CellularNetworkModePlanner.Outcome<CellularModuleID> {
        CellularNetworkModePlanner.plan(
            setting: mode,
            for: moduleID,
            moduleIDs: moduleIDs ?? allModuleIDs,
            currentModes: currentModes,
            replacingPreviousPreferredWith: replacementMode
        )
    }

    // Matrix 1: A preferred -> B preferred, A demoted to standby.
    let onePreferred: [CellularModuleID: CellularNetworkMode] = [
        moduleOneID: .preferred,
        moduleTwoID: .off,
        moduleThreeID: .off,
    ]
    try expect(
        planMode(.preferred, for: moduleTwoID, from: onePreferred) ==
            .needsPreferredConflictResolution(previousPreferredID: moduleOneID),
        "promoting a second module to cellular priority skipped the confirmation prompt"
    )
    try expect(
        planMode(.preferred, for: moduleTwoID, from: onePreferred, replacing: .standby) ==
            .apply([
                moduleOneID: .standby,
                moduleTwoID: .preferred,
                moduleThreeID: .off,
            ]),
        "resolving the priority conflict with 'keep connected' did not demote the old module"
    )

    // Matrix 2: A preferred -> B preferred, A fully off.
    try expect(
        planMode(.preferred, for: moduleTwoID, from: onePreferred, replacing: .off) ==
            .apply([
                moduleOneID: .off,
                moduleTwoID: .preferred,
                moduleThreeID: .off,
            ]),
        "resolving the priority conflict with 'turn off' did not disable the old module"
    )
    try expect(
        planMode(.preferred, for: moduleTwoID, from: onePreferred, replacing: .preferred) ==
            .needsPreferredConflictResolution(previousPreferredID: moduleOneID),
        "a second cellular priority module was accepted, breaking the single-preferred invariant"
    )

    // No confirmation is required for standby, off, self-demotion, or re-picking
    // the module that already owns cellular priority.
    try expect(
        planMode(.standby, for: moduleTwoID, from: onePreferred) ==
            .apply([
                moduleOneID: .preferred,
                moduleTwoID: .standby,
                moduleThreeID: .off,
            ]) &&
            planMode(.off, for: moduleTwoID, from: onePreferred) == .apply(onePreferred) &&
            planMode(.standby, for: moduleOneID, from: onePreferred) ==
            .apply([
                moduleOneID: .standby,
                moduleTwoID: .off,
                moduleThreeID: .off,
            ]) &&
            planMode(.preferred, for: moduleOneID, from: onePreferred) == .apply(onePreferred),
        "a cellular mode change that cannot conflict still demanded confirmation"
    )

    // Matrix 3: one preferred module plus several standby modules.
    let preferredPlusStandby: [CellularModuleID: CellularNetworkMode] = [
        moduleOneID: .preferred,
        moduleTwoID: .standby,
        moduleThreeID: .off,
    ]
    try expect(
        planMode(.standby, for: moduleThreeID, from: preferredPlusStandby) ==
            .apply([
                moduleOneID: .preferred,
                moduleTwoID: .standby,
                moduleThreeID: .standby,
            ]),
        "a third module could not join the standby set alongside a preferred module"
    )

    // Matrix 4: two standby modules, then a third becomes preferred without a prompt.
    let twoStandby: [CellularModuleID: CellularNetworkMode] = [
        moduleOneID: .standby,
        moduleTwoID: .standby,
        moduleThreeID: .off,
    ]
    try expect(
        planMode(.preferred, for: moduleThreeID, from: twoStandby) ==
            .apply([
                moduleOneID: .standby,
                moduleTwoID: .standby,
                moduleThreeID: .preferred,
            ]),
        "claiming cellular priority while no module owns it required confirmation"
    )

    // Matrix 5: turning one module off leaves the other two untouched.
    let preferredPlusTwoStandby: [CellularModuleID: CellularNetworkMode] = [
        moduleOneID: .preferred,
        moduleTwoID: .standby,
        moduleThreeID: .standby,
    ]
    try expect(
        planMode(.off, for: moduleTwoID, from: preferredPlusTwoStandby) ==
            .apply([
                moduleOneID: .preferred,
                moduleTwoID: .off,
                moduleThreeID: .standby,
            ]),
        "turning one cellular module off disturbed the other modules"
    )

    // Matrix 6: closing every module is a single transaction.
    try expect(
        CellularNetworkModePlanner.turningEverythingOff(
            moduleIDs: allModuleIDs,
            currentModes: preferredPlusTwoStandby
        ) == [
            moduleOneID: .off,
            moduleTwoID: .off,
            moduleThreeID: .off,
        ],
        "closing all cellular modules did not turn every module off at once"
    )

    // Matrix 9: a detached module can neither be retargeted nor promote its peers.
    try expect(
        planMode(
            .preferred,
            for: moduleOneID,
            from: preferredPlusTwoStandby,
            moduleIDs: [moduleTwoID, moduleThreeID]
        ) == .unknownModule,
        "a detached cellular module was still accepted as a mode change target"
    )
    try expect(
        CellularNetworkModePlanner.collapsingExtraPreferred(
            modes: [moduleTwoID: .standby, moduleThreeID: .standby],
            moduleIDs: [moduleTwoID, moduleThreeID],
            retaining: moduleOneID
        ) == [moduleTwoID: .standby, moduleThreeID: .standby],
        "removing the preferred module auto-promoted a standby module"
    )

    // Matrix 10: a restored configuration claiming two preferred modules is
    // repaired in favour of the previously selected primary module.
    let corruptedRestore: [CellularModuleID: CellularNetworkMode] = [
        moduleOneID: .preferred,
        moduleTwoID: .preferred,
        moduleThreeID: .standby,
    ]
    try expect(
        CellularNetworkModePlanner.collapsingExtraPreferred(
            modes: corruptedRestore,
            moduleIDs: allModuleIDs,
            retaining: moduleTwoID
        ) == [
            moduleOneID: .standby,
            moduleTwoID: .preferred,
            moduleThreeID: .standby,
        ],
        "restoring two preferred modules did not retain the previous primary module"
    )
    try expect(
        CellularNetworkModePlanner.collapsingExtraPreferred(
            modes: corruptedRestore,
            moduleIDs: allModuleIDs,
            retaining: nil
        ) == [
            moduleOneID: .preferred,
            moduleTwoID: .standby,
            moduleThreeID: .standby,
        ],
        "restoring two preferred modules without a hint did not fall back to the first module"
    )
    try expect(
        CellularNetworkModePlanner.normalizedModes(
            moduleIDs: allModuleIDs,
            currentModes: [moduleTwoID: .preferred],
            fallback: { _ in .defaultConnectionMode }
        ) == [
            moduleOneID: .standby,
            moduleTwoID: .preferred,
            moduleThreeID: .standby,
        ],
        "unknown cellular modules were not normalized to the default connection mode"
    )

    // Matrix 13: both entry points share one planner, so the SIM management page
    // and the menu bar card cannot diverge, and replaying a plan is idempotent.
    let planFromSIMPage = planMode(
        .preferred,
        for: moduleThreeID,
        from: preferredPlusTwoStandby,
        replacing: .standby
    )
    let planFromMenuBar = planMode(
        .preferred,
        for: moduleThreeID,
        from: preferredPlusTwoStandby,
        replacing: .standby
    )
    guard case let .apply(settledModes) = planFromSIMPage else {
        throw SelfTestFailure.failed("promoting a standby module to preferred did not produce a plan")
    }
    try expect(
        planFromSIMPage == planFromMenuBar &&
            settledModes == [
                moduleOneID: .standby,
                moduleTwoID: .standby,
                moduleThreeID: .preferred,
            ] &&
            planMode(.preferred, for: moduleThreeID, from: settledModes) ==
            .apply(settledModes),
        "the two cellular mode entry points disagreed or the plan was not idempotent"
    )

    // Every planned configuration must survive request validation and keep the
    // documented service order: preferred, then non-cellular, then standby.
    let locationIDsByModule: [CellularModuleID: UInt32] = [
        moduleOneID: 0x100,
        moduleTwoID: 0x200,
        moduleThreeID: 0x300,
    ]
    func request(
        for modes: [CellularModuleID: CellularNetworkMode]
    ) -> CellularNetworkConfigurationRequest {
        var preferred: UInt32?
        var standby: [UInt32] = []
        var off: [UInt32] = []
        for moduleID in allModuleIDs {
            guard let locationID = locationIDsByModule[moduleID] else { continue }
            switch modes[moduleID] ?? .off {
            case .preferred: preferred = locationID
            case .standby: standby.append(locationID)
            case .off: off.append(locationID)
            }
        }
        return CellularNetworkConfigurationRequest(
            preferredLocationID: preferred,
            standbyLocationIDs: standby,
            offLocationIDs: off
        )
    }
    let plannedConfigurations: [[CellularModuleID: CellularNetworkMode]] = [
        onePreferred,
        preferredPlusStandby,
        twoStandby,
        preferredPlusTwoStandby,
        settledModes,
        CellularNetworkModePlanner.turningEverythingOff(
            moduleIDs: allModuleIDs,
            currentModes: preferredPlusTwoStandby
        ),
    ]
    try expect(
        plannedConfigurations.allSatisfy { request(for: $0).isValid },
        "a planned multi-module configuration was rejected by request validation"
    )
    let allOffRequest = request(
        for: CellularNetworkModePlanner.turningEverythingOff(
            moduleIDs: allModuleIDs,
            currentModes: preferredPlusTwoStandby
        )
    )
    try expect(
        allOffRequest.preferredLocationID == nil &&
            allOffRequest.standbyLocationIDs.isEmpty &&
            allOffRequest.offLocationIDs == [0x100, 0x200, 0x300],
        "closing all cellular modules did not disable every module in one request"
    )

    let liveOrder = ["wifi", "ecm-1", "ethernet", "ecm-2", "ecm-3"]
    let liveCellularIDs: Set<String> = ["ecm-1", "ecm-2", "ecm-3"]
    try expect(
        CellularNetworkServiceOrderPolicy.appliedOrder(
            preferredServiceID: "ecm-3",
            standbyServiceIDs: ["ecm-1", "ecm-2"],
            originalOrder: liveOrder,
            cellularServiceIDs: liveCellularIDs
        ) == ["ecm-3", "wifi", "ethernet", "ecm-1", "ecm-2"],
        "promoting a standby module did not move it ahead of the non-cellular services"
    )
    try expect(
        CellularNetworkServiceOrderPolicy.appliedOrder(
            preferredServiceID: nil,
            standbyServiceIDs: [],
            originalOrder: liveOrder,
            cellularServiceIDs: liveCellularIDs
        ) == ["wifi", "ethernet", "ecm-1", "ecm-2", "ecm-3"],
        "closing all cellular modules did not restore the non-cellular services first"
    )
    try expect(
        CellularNetworkServiceOrderPolicy.appliedOrder(
            preferredServiceID: "ecm-1",
            standbyServiceIDs: ["ecm-3"],
            originalOrder: liveOrder,
            cellularServiceIDs: liveCellularIDs
        ) == ["ecm-1", "wifi", "ethernet", "ecm-3", "ecm-2"],
        "turning one module off did not keep it behind the remaining standby module"
    )

    // Desired-versus-actual reporting must distinguish all three modes so a
    // failed system hand-off is visible instead of silently accepted.
    let preferredStatus = CellularNetworkStatus(
        isEnabled: true,
        isPrioritized: true,
        isDemoted: false,
        isSystemPrimary: true
    )
    let demotedStatus = CellularNetworkStatus(
        isEnabled: true,
        isPrioritized: false,
        isDemoted: true
    )
    let disabledStatus = CellularNetworkStatus(isEnabled: false)
    try expect(
        CellularNetworkStartupPolicy.isApplied(.preferred, to: preferredStatus) &&
            !CellularNetworkStartupPolicy.isApplied(.standby, to: preferredStatus) &&
            !CellularNetworkStartupPolicy.isApplied(.off, to: preferredStatus) &&
            CellularNetworkStartupPolicy.isApplied(.standby, to: demotedStatus) &&
            !CellularNetworkStartupPolicy.isApplied(.preferred, to: demotedStatus) &&
            CellularNetworkStartupPolicy.isApplied(.off, to: disabledStatus) &&
            !CellularNetworkStartupPolicy.isApplied(.standby, to: disabledStatus),
        "cellular mode reporting confused preferred, standby, and off states"
    )
    let preferredButNotPrimary = CellularNetworkStatus(
        isEnabled: true,
        isPrioritized: false,
        isDemoted: false,
        isSystemPrimary: false
    )
    try expect(
        !CellularNetworkStartupPolicy.isApplied(.preferred, to: preferredButNotPrimary),
        "a module that failed to take over the default route was reported as preferred"
    )

    // Matrix 11: a DHCP-stage failure means the helper already committed the
    // configuration, so the app must still persist the requested modes.
    try expect(
        CellularNetworkFailureReason.dhcpTimeout.configurationWasApplied &&
            CellularNetworkFailureReason.linkInactive.configurationWasApplied &&
            !CellularNetworkFailureReason.other.configurationWasApplied,
        "a committed cellular configuration was treated as if nothing had been applied"
    )

    // Matrix 12: multiple ECM interfaces handing out the same private address.
    func conflictStatus(_ address: String?, router: String?) -> CellularNetworkStatus {
        CellularNetworkStatus(
            isEnabled: true,
            isHardwarePresent: true,
            ipv4Address: address,
            ipv4Router: router
        )
    }
    let duplicateAddressStatuses: [UInt32: CellularNetworkStatus] = [
        0x100: conflictStatus("192.168.225.2", router: "192.168.225.1"),
        0x200: conflictStatus("192.168.225.2", router: "192.168.225.1"),
        0x300: conflictStatus("10.24.16.8", router: "10.24.16.1"),
    ]
    let detectedConflicts = CellularNetworkConflictPolicy.issues(
        forStatusesByLocationID: duplicateAddressStatuses
    )
    try expect(
        detectedConflicts == [
            0x100: .duplicateAddress("192.168.225.2"),
            0x200: .duplicateAddress("192.168.225.2"),
        ],
        "identical ECM addresses across modules were not reported as an address conflict"
    )
    try expect(
        CellularNetworkConflictPolicy.issues(forStatusesByLocationID: [
            0x100: conflictStatus("192.168.225.24", router: "192.168.225.1"),
            0x200: conflictStatus("192.168.225.22", router: "192.168.225.1"),
        ]) == [
            0x100: .sharedSubnet("192.168.225.1"),
            0x200: .sharedSubnet("192.168.225.1"),
        ],
        "modules behind one gateway were not reported as sharing a subnet"
    )
    // QDC507 firmware pins its ECM gateway, so every multi-module setup shares a
    // subnet. Treating that as a fault would keep the warning indicator on
    // permanently, so only an identical address may count as a warning.
    try expect(
        CellularNetworkIssue.duplicateAddress("192.168.225.2").isWarning &&
            !CellularNetworkIssue.sharedSubnet("192.168.225.1").isWarning,
        "a shared cellular subnet was escalated to a configuration warning"
    )
    try expect(
        CellularNetworkConflictPolicy.issues(forStatusesByLocationID: [
            0x100: conflictStatus("192.168.225.2", router: "192.168.225.1"),
            0x200: conflictStatus("10.24.16.8", router: "10.24.16.1"),
        ]).isEmpty &&
            CellularNetworkConflictPolicy.issues(
                forStatusesByLocationID: duplicateAddressStatuses.filter { $0.key == 0x100 }
            ).isEmpty,
        "distinct cellular addresses were incorrectly flagged as conflicting"
    )
    var disabledDuplicate = conflictStatus("192.168.225.2", router: "192.168.225.1")
    disabledDuplicate.isEnabled = false
    var pendingDuplicate = conflictStatus(nil, router: nil)
    pendingDuplicate.isLinkActive = true
    try expect(
        CellularNetworkConflictPolicy.issues(forStatusesByLocationID: [
            0x100: conflictStatus("192.168.225.2", router: "192.168.225.1"),
            0x200: disabledDuplicate,
            0x300: pendingDuplicate,
        ]).isEmpty,
        "a disabled or lease-less module was counted as an address conflict"
    )

    let readyModule = CellularModuleSummary(
        id: moduleOneID,
        displayName: "模组 1",
        modem: ModemSnapshot(
            state: .connected,
            operatorName: "中国移动",
            accessTechnology: "5G",
            signalDBm: -72,
            simState: .ready,
            simICCID: "89860012345678901234"
        ),
        network: CellularNetworkStatus(isEnabled: true, isActive: true),
        cardKind: .physicalSIM,
        isActiveSession: true,
        isPrimaryData: false
    )
    try expect(
        readyModule.isCommunicationEligible &&
            !readyModule.isDataEligible &&
            readyModule.simSuffix == "1234" &&
            readyModule.selectorTitle == "模组 1 · 中国移动 · 5G",
        "ready cellular module presentation changed unexpectedly"
    )

    let dataReadyModule = CellularModuleSummary(
        id: moduleOneID,
        displayName: "模组 1",
        modem: ModemSnapshot(
            state: .connected,
            simState: .ready,
            usbNetMode: 1
        ),
        network: CellularNetworkStatus(),
        cardKind: .physicalSIM,
        isActiveSession: true,
        isPrimaryData: true
    )
    try expect(
        dataReadyModule.isDataEligible,
        "SIM and ECM ready module was rejected as an internet route"
    )

    let noSIMModule = CellularModuleSummary(
        id: moduleTwoID,
        displayName: "模组 2",
        modem: ModemSnapshot(state: .connected, simState: .absent),
        network: CellularNetworkStatus(),
        cardKind: .unknown,
        isActiveSession: true,
        isPrimaryData: false
    )
    try expect(
        !noSIMModule.isCommunicationEligible && noSIMModule.statusText == "未插入 SIM",
        "module without SIM was allowed as a communication route"
    )

    let monitoredSIMModule = CellularModuleSummary(
        id: moduleTwoID,
        displayName: "模组 2",
        modem: ModemSnapshot(
            state: .connected,
            operatorName: "中国联通",
            simState: .ready,
            simICCID: "89860123456789005678"
        ),
        network: CellularNetworkStatus(),
        cardKind: .physicalSIM,
        isActiveSession: false,
        isPrimaryData: false
    )
    try expect(
        monitoredSIMModule.statusText == "SIM 已就绪" &&
            monitoredSIMModule.simSuffix == "5678" &&
            !monitoredSIMModule.isCommunicationEligible,
        "auxiliary modem SIM monitoring was confused with communication ownership"
    )

    let disconnectedModule = CellularModuleSummary(
        id: CellularModuleID(rawValue: "usb-location-3"),
        displayName: "模组 3",
        modem: ModemSnapshot(),
        network: CellularNetworkStatus(),
        cardKind: .unknown,
        isActiveSession: false,
        isPrimaryData: true
    )
    try expect(
        !disconnectedModule.isCommunicationEligible &&
            disconnectedModule.statusText == "已断开" &&
            disconnectedModule.accessibilitySummary.contains("主上网"),
        "disconnected module role or status presentation regressed"
    )

    let retainedManagementSelection =
        CellularModuleSelectionPolicy.reconciledManagementSelection(
            current: moduleTwoID,
            available: [moduleOneID, moduleTwoID]
        )
    let fallbackManagementSelection =
        CellularModuleSelectionPolicy.reconciledManagementSelection(
            current: CellularModuleID(rawValue: "removed-module"),
            available: [moduleOneID, moduleTwoID]
        )
    try expect(
        retainedManagementSelection == moduleTwoID &&
            fallbackManagementSelection == moduleOneID &&
            CellularModuleSelectionPolicy.reconciledManagementSelection(
                current: moduleOneID,
                available: []
            ) == nil,
        "management selection did not remain stable or fall back safely"
    )
    let fallbackCommunicationID = CellularModuleID(rawValue: "usb-location-fallback")
    try expect(
        CommunicationModuleRoutingPolicy.resolvedModuleID(
            requested: moduleTwoID,
            current: moduleOneID,
            fallback: fallbackCommunicationID
        ) == moduleTwoID &&
            CommunicationModuleRoutingPolicy.resolvedModuleID(
                requested: nil,
                current: moduleOneID,
                fallback: fallbackCommunicationID
            ) == moduleOneID &&
            CommunicationModuleRoutingPolicy.resolvedModuleID(
                requested: nil,
                current: nil,
                fallback: fallbackCommunicationID
            ) == fallbackCommunicationID,
        "current communication module routing precedence regressed"
    )

    let callableModuleTwo = CellularModuleSummary(
        id: moduleTwoID,
        displayName: "模组 2",
        modem: ModemSnapshot(state: .connected, simState: .ready),
        network: CellularNetworkStatus(),
        cardKind: .physicalSIM,
        isActiveSession: true,
        isPrimaryData: false
    )
    try expect(
        MenuBarStatusModuleSelectionPolicy.resolvedModuleID(
            isCellularNetworkingEnabled: true,
            primaryDataModuleID: moduleTwoID,
            currentCommunicationModuleID: moduleOneID,
            modules: [readyModule, callableModuleTwo]
        ) == moduleTwoID,
        "menu bar did not prefer the enabled cellular data module"
    )
    try expect(
        MenuBarStatusModuleSelectionPolicy.resolvedModuleID(
            isCellularNetworkingEnabled: false,
            primaryDataModuleID: moduleOneID,
            currentCommunicationModuleID: moduleTwoID,
            modules: [readyModule, callableModuleTwo]
        ) == moduleTwoID,
        "menu bar did not prefer the selected callable module when data was off"
    )
    try expect(
        MenuBarStatusModuleSelectionPolicy.resolvedModuleID(
            isCellularNetworkingEnabled: false,
            primaryDataModuleID: nil,
            currentCommunicationModuleID: moduleTwoID,
            modules: [readyModule, noSIMModule]
        ) == moduleOneID,
        "menu bar did not fall back to the first callable module"
    )
    try expect(
        MenuBarStatusModuleSelectionPolicy.resolvedModuleID(
            isCellularNetworkingEnabled: false,
            primaryDataModuleID: nil,
            currentCommunicationModuleID: nil,
            modules: [noSIMModule, disconnectedModule]
        ) == moduleTwoID,
        "menu bar did not fall back to the first physical module"
    )

    guard let throughput = NetworkThroughputCalculator.rates(
        previous: NetworkInterfaceByteCounters(
            received: UInt32.max - 49,
            sent: 1_000,
            uptime: 10
        ),
        current: NetworkInterfaceByteCounters(
            received: 50,
            sent: 3_000,
            uptime: 12
        )
    ) else {
        throw SelfTestFailure.failed(
            "network throughput calculator rejected a valid sample"
        )
    }
    try expect(
        throughput.downloadBytesPerSecond == 50 &&
            throughput.uploadBytesPerSecond == 1_000 &&
            NetworkSpeedFormatter.menuBarText(throughput).contains("↓") &&
            NetworkSpeedFormatter.menuBarText(throughput).contains("↑"),
        "network throughput calculation, rollover handling, or formatting regressed"
    )
    try expect(
        NetworkThroughputCalculator.rates(
            previous: NetworkInterfaceByteCounters(
                received: 2_000_000,
                sent: 3_000_000,
                uptime: 20
            ),
            current: NetworkInterfaceByteCounters(
                received: 100,
                sent: 200,
                uptime: 21
            )
        ) == nil,
        "an ECM counter reset was misreported as a multi-gigabyte throughput spike"
    )
    try expect(
        ModuleVoiceInitializationRetryPolicy.delay(forCompletedAttempts: 0) == 2 &&
            ModuleVoiceInitializationRetryPolicy.delay(forCompletedAttempts: 1) == 5 &&
            ModuleVoiceInitializationRetryPolicy.delay(forCompletedAttempts: 4) == 60 &&
            ModuleVoiceInitializationRetryPolicy.delay(forCompletedAttempts: 5) == nil,
        "module voice initialization retry schedule changed unexpectedly"
    )
    try expect(
        !NetworkAddressClassifier.isUsableIPv4("169.254.10.30"),
        "self-assigned IPv4 address was treated as usable cellular data"
    )
    try expect(
        NetworkAddressClassifier.isUsableIPv4("192.168.225.25"),
        "valid ECM DHCP address was rejected"
    )
    try expect(
        !NetworkAddressClassifier.isUsableIPv4("127.0.0.1") &&
            !NetworkAddressClassifier.isUsableIPv4("not-an-address") &&
            !NetworkAddressClassifier.isUsableIPv4("300.1.1.1"),
        "invalid or local-only IPv4 address was accepted"
    )
    let inactiveLinkResult = CellularNetworkActionResult.failure(
        "ECM link inactive",
        reason: .linkInactive
    )
    try expect(
        inactiveLinkResult.failureReason == .linkInactive &&
            inactiveLinkResult.displayResult == .failure("ECM link inactive"),
        "link-inactive network failure lost its recovery reason"
    )
    try expect(
        CellularNetworkActionResult.success("ready").failureReason == nil &&
            CellularNetworkActionResult.success("ready").displayResult == .success("ready"),
        "successful network action was mapped to a failure"
    )
    try expect(
        CellularLinkRecoveryPolicy.shouldAttempt(
            network: recoverableNetwork,
            modem: recoverableModem,
            hasCall: false,
            isChangingNetwork: false,
            isInFlight: false,
            completedAttempts: 0
        ),
        "inactive ECM link did not request recovery"
    )

    // A module kept on standby is just as much the user's connection as the
    // preferred one, so a dead link there must still be repaired. Only a module
    // that is meant to be off is skipped.
    try expect(
        CellularLinkRecoveryPolicy.shouldAttempt(
            network: recoverableNetwork,
            modem: recoverableModem,
            desiredMode: .standby,
            hasCall: false,
            isChangingNetwork: false,
            isInFlight: false,
            completedAttempts: 0
        ),
        "a standby module with a dead ECM link was excluded from recovery"
    )
    try expect(
        !CellularLinkRecoveryPolicy.shouldAttempt(
            network: recoverableNetwork,
            modem: recoverableModem,
            desiredMode: .off,
            hasCall: false,
            isChangingNetwork: false,
            isInFlight: false,
            completedAttempts: 0
        ),
        "a module the user turned off was still scheduled for link recovery"
    )
    try expect(
        CellularLinkRecoveryPolicy.shouldRestartModule(
            network: recoverableNetwork,
            modem: recoverableModem,
            desiredMode: .standby,
            hasCall: false,
            completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts,
            alreadyRestarted: false
        ) &&
            !CellularLinkRecoveryPolicy.shouldRestartModule(
                network: recoverableNetwork,
                modem: recoverableModem,
                desiredMode: .off,
                hasCall: false,
                completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts,
                alreadyRestarted: false
            ),
        "module restart ignored the module's desired cellular mode"
    )

    // A faulty module often blips active for a few seconds after a power cycle.
    // Clearing the restart guard on that blip would re-arm the restart path and
    // leave a chronically broken module re-enumerating USB forever.
    let restartMoment = Date(timeIntervalSince1970: 1_800_000_000)
    try expect(
        CellularLinkRecoveryPolicy.canClearRestartGuard(
            lastRestart: nil,
            now: restartMoment
        ) &&
            !CellularLinkRecoveryPolicy.canClearRestartGuard(
                lastRestart: restartMoment,
                now: restartMoment.addingTimeInterval(30)
            ) &&
            CellularLinkRecoveryPolicy.canClearRestartGuard(
                lastRestart: restartMoment,
                now: restartMoment.addingTimeInterval(
                    CellularLinkRecoveryPolicy.restartCooldown
                )
            ),
        "a brief post-restart blip re-armed the module restart path"
    )

    // An inactive link must ride the backoff ladder before a power cycle, or a
    // module that is merely slow to rejoin its internal bridge gets restarted on
    // the very first failure and the three-attempt budget never applies.
    try expect(
        !CellularLinkRecoveryPolicy.shouldEscalateToRestart(
            reason: .linkInactive,
            completedAttempts: 0
        ) &&
            !CellularLinkRecoveryPolicy.shouldEscalateToRestart(
                reason: .linkInactive,
                completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts - 1
            ) &&
            CellularLinkRecoveryPolicy.shouldEscalateToRestart(
                reason: .linkInactive,
                completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts
            ),
        "an inactive ECM link skipped the soft-recovery ladder and restarted the module"
    )
    // A DHCP timeout means the link already carries traffic, so more link repair
    // cannot help and the restart stays immediate.
    try expect(
        CellularLinkRecoveryPolicy.shouldEscalateToRestart(
            reason: .dhcpTimeout,
            completedAttempts: 0
        ) &&
            !CellularLinkRecoveryPolicy.shouldEscalateToRestart(
                reason: .other,
                completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts
            ),
        "restart escalation ignored the failure reason"
    )

    // An enabled service without carrier used to fall through to `.starting`,
    // so a module that could never connect claimed to be "connecting" forever.
    // Nothing populates the per-module `lastError`, so `.failed` was unreachable
    // and this fallback was the only outcome.
    let readyModemForLink = registeredModem
    let carrierlessService = CellularNetworkStatus(
        isEnabled: true,
        isActive: false,
        isLinkActive: false,
        isHardwarePresent: true
    )
    try expect(
        CellularDataConnectionPolicy.state(
            modem: readyModemForLink,
            network: carrierlessService,
            isPresentedEnabled: true,
            isChangingNetwork: false,
            isRecovering: false,
            isRetryingLink: true
        ) == .linkDown(isRetrying: true),
        "a module with no ECM carrier was still reported as connecting"
    )
    try expect(
        CellularDataConnectionPolicy.state(
            modem: readyModemForLink,
            network: carrierlessService,
            isPresentedEnabled: true,
            isChangingNetwork: false,
            isRecovering: false,
            isRetryingLink: false
        ) == .linkDown(isRetrying: false),
        "a module that stopped retrying was not distinguished from one still trying"
    )
    // A carrier that is up but has no lease yet is genuinely connecting.
    var carryingWithoutLease = carrierlessService
    carryingWithoutLease.isLinkActive = true
    try expect(
        CellularDataConnectionPolicy.state(
            modem: readyModemForLink,
            network: carryingWithoutLease,
            isPresentedEnabled: true,
            isChangingNetwork: false,
            isRecovering: false
        ) == .starting,
        "a live ECM carrier waiting for DHCP was misreported as a dead link"
    )
    // In-flight work and an explicit error still win over the new branch.
    try expect(
        CellularDataConnectionPolicy.state(
            modem: readyModemForLink,
            network: carrierlessService,
            isPresentedEnabled: true,
            isChangingNetwork: true,
            isRecovering: false
        ) == .starting &&
            CellularDataConnectionPolicy.state(
                modem: readyModemForLink,
                network: carrierlessService,
                isPresentedEnabled: false,
                isChangingNetwork: false,
                isRecovering: false
            ) == .disabled,
        "the dead-link branch overrode an in-flight change or a disabled module"
    )
    try expect(
        CellularLinkRecoveryPolicy.isRetrying(completedAttempts: 0, hasRestarted: false) &&
            CellularLinkRecoveryPolicy.isRetrying(
                completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts,
                hasRestarted: false
            ) &&
            !CellularLinkRecoveryPolicy.isRetrying(
                completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts,
                hasRestarted: true
            ),
        "retry reporting did not account for the remaining restart budget"
    )

    // The helper's restore data must never be read by a build that predates its
    // format. Adding optional fields is already tolerated by Codable, so the
    // version guards the downgrade direction: an older helper reading a newer
    // file could otherwise restore the user's service order with the wrong
    // semantics. Files written before versioning read as 0 and stay usable.
    try expect(
        NetworkHelperStateCompatibility.canInterpret(version: nil) &&
            NetworkHelperStateCompatibility.canInterpret(version: 0) &&
            NetworkHelperStateCompatibility.canInterpret(
                version: NetworkHelperStateCompatibility.currentVersion
            ) &&
            !NetworkHelperStateCompatibility.canInterpret(
                version: NetworkHelperStateCompatibility.currentVersion + 1
            ),
        "helper state compatibility accepted a file it cannot interpret"
    )

    // Only a real address conflict may be reported as a port conflict. Mapping
    // every listener failure to that state hid a listener that could not be
    // created at all and sent the diagnosis in the wrong direction.
    try expect(
        SOCKSProxyListenerFailure.state(
            posixCode: EADDRINUSE, description: "EADDRINUSE", port: 1080
        ) == .failedPortInUse(1080) &&
            SOCKSProxyListenerFailure.state(
                posixCode: EADDRNOTAVAIL, description: "EADDRNOTAVAIL", port: 1080
            ) == .failedPortInUse(1080) &&
            SOCKSProxyListenerFailure.state(
                posixCode: EINVAL, description: "EINVAL", port: 1080
            ) == .failedToStart("EINVAL") &&
            SOCKSProxyListenerFailure.state(
                posixCode: nil, description: "boom", port: 1080
            ) == .failedToStart("boom"),
        "a listener failure that was not an address conflict was reported as a port conflict"
    )

    // An idle relay socket must report "nothing yet" as a state. Folding it into
    // an error tore down every connection that stayed quiet for ten seconds,
    // which broke SSH, WebSocket and HTTP keep-alive.
    try expect(
        BoundSocketReadResult.wouldBlock != .endOfStream &&
            BoundSocketReadResult.data(Data([1, 2])) != .wouldBlock &&
            BoundSocketReadResult.data(Data([1, 2])) == .data(Data([1, 2])),
        "non-blocking read states were not distinguishable"
    )

    // A handshake buffer is a Data slice by the time the second and third phases
    // decode: Data.removeFirst only advances startIndex instead of reindexing,
    // so decoders that assumed zero-based subscripts read past the end and
    // trapped. Every decoder must therefore work from an offset slice, which is
    // exactly how it is fed in production.
    func slicedTail(_ prefix: [UInt8], _ payload: [UInt8]) -> Data {
        var buffer = Data(prefix + payload)
        buffer.removeFirst(prefix.count)
        return buffer
    }
    let methodsPrefix: [UInt8] = [0x05, 0x01, 0x02]

    let slicedMethods = slicedTail(methodsPrefix, [0x05, 0x02, 0x00, 0x02])
    try expect(slicedMethods.startIndex != 0, "the sliced fixture was not actually offset")
    let decodedSlicedMethods = try SOCKSProtocol.decodeMethodSelection(slicedMethods)
    try expect(
        decodedSlicedMethods.methods == [0x00, 0x02] &&
            decodedSlicedMethods.consumedByteCount == 4,
        "method selection could not be decoded from an offset buffer"
    )

    // 0x01 VER, 4-byte username "user", 4-byte password "pass"
    let credentialBytes: [UInt8] = [0x01, 0x04] + Array("user".utf8)
        + [0x04] + Array("pass".utf8)
    let decodedSlicedCredentials = try SOCKSProtocol.decodeUsernamePassword(
        slicedTail(methodsPrefix, credentialBytes)
    )
    try expect(
        decodedSlicedCredentials.username == "user" &&
            decodedSlicedCredentials.password == "pass" &&
            decodedSlicedCredentials.consumedByteCount == credentialBytes.count,
        "username and password could not be decoded from an offset buffer"
    )

    let ipv4RequestBytes: [UInt8] = [0x05, 0x01, 0x00, 0x01, 93, 184, 216, 34, 0x01, 0xBB]
    let decodedSlicedRequest = try SOCKSProtocol.decodeRequest(
        slicedTail(methodsPrefix, ipv4RequestBytes)
    )
    try expect(
        decodedSlicedRequest.command == SOCKSCommand.connect.rawValue &&
            decodedSlicedRequest.address == .ipv4([93, 184, 216, 34]) &&
            decodedSlicedRequest.port == 443 &&
            decodedSlicedRequest.consumedByteCount == ipv4RequestBytes.count,
        "a CONNECT request could not be decoded from an offset buffer"
    )

    let domainRequestBytes: [UInt8] = [0x05, 0x01, 0x00, 0x03, 0x0B]
        + Array("example.com".utf8) + [0x00, 0x50]
    let decodedSlicedDomain = try SOCKSProtocol.decodeRequest(
        slicedTail(methodsPrefix, domainRequestBytes)
    )
    try expect(
        decodedSlicedDomain.address == .domain("example.com") &&
            decodedSlicedDomain.port == 80,
        "a domain CONNECT request could not be decoded from an offset buffer"
    )

    // Truncation must still be reported rather than read out of bounds.
    for truncated in 1 ..< credentialBytes.count {
        do {
            _ = try SOCKSProtocol.decodeUsernamePassword(
                slicedTail(methodsPrefix, Array(credentialBytes.prefix(truncated)))
            )
            throw SelfTestFailure.failed(
                "a truncated credential buffer of \(truncated) bytes was accepted"
            )
        } catch is SOCKSProtocolError {
            continue
        }
    }
    for truncated in 1 ..< domainRequestBytes.count {
        do {
            _ = try SOCKSProtocol.decodeRequest(
                slicedTail(methodsPrefix, Array(domainRequestBytes.prefix(truncated)))
            )
            throw SelfTestFailure.failed(
                "a truncated request buffer of \(truncated) bytes was accepted"
            )
        } catch is SOCKSProtocolError {
            continue
        }
    }
    // A pre-versioning file must still decode, so every field stays optional.
    let legacyHelperState = try JSONDecoder().decode(
        NetworkHelperState.self,
        from: Data(#"{"serviceRecordsByLocation":{}}"#.utf8)
    )
    try expect(
        legacyHelperState.version == nil &&
            NetworkHelperStateCompatibility.canInterpret(version: legacyHelperState.version),
        "a helper state file written before versioning was rejected"
    )
    let roundTrippedHelperState = try JSONDecoder().decode(
        NetworkHelperState.self,
        from: try JSONEncoder().encode(NetworkHelperState.empty)
    )
    try expect(
        roundTrippedHelperState == NetworkHelperState.empty,
        "empty helper state did not survive a round trip"
    )

    // The helper cannot see the module's internal bridge, so a service that is
    // enabled but not carrying traffic still needs its link prepared. Gating
    // preparation on "service disabled" alone left exactly that case stranded.
    let enabledButDeadLink = CellularNetworkStatus(
        isEnabled: true,
        isLinkActive: false,
        isHardwarePresent: true
    )
    var enabledAndCarrying = enabledButDeadLink
    enabledAndCarrying.isLinkActive = true
    let disabledService = CellularNetworkStatus(isEnabled: false, isLinkActive: false)
    try expect(
        CellularLinkRecoveryPolicy.needsLinkPreparation(enabledButDeadLink) &&
            CellularLinkRecoveryPolicy.needsLinkPreparation(disabledService) &&
            !CellularLinkRecoveryPolicy.needsLinkPreparation(enabledAndCarrying),
        "an enabled module with an inactive ECM link was not prepared before use"
    )
    var activeNetwork = recoverableNetwork
    activeNetwork.isActive = true
    try expect(
        !CellularLinkRecoveryPolicy.shouldAttempt(
            network: activeNetwork,
            modem: recoverableModem,
            hasCall: false,
            isChangingNetwork: false,
            isInFlight: false,
            completedAttempts: 0
        ),
        "active cellular network requested recovery"
    )
    try expect(
        !CellularLinkRecoveryPolicy.shouldAttempt(
            network: recoverableNetwork,
            modem: recoverableModem,
            hasCall: true,
            isChangingNetwork: false,
            isInFlight: false,
            completedAttempts: 0
        ),
        "active call allowed ECM recovery"
    )
    try expect(
        !CellularLinkRecoveryPolicy.shouldAttempt(
            network: recoverableNetwork,
            modem: recoverableModem,
            hasCall: false,
            isChangingNetwork: true,
            isInFlight: false,
            completedAttempts: 0
        ),
        "ECM recovery raced an in-flight network change"
    )
    try expect(
        !CellularLinkRecoveryPolicy.shouldAttempt(
            network: recoverableNetwork,
            modem: recoverableModem,
            hasCall: false,
            isChangingNetwork: false,
            isInFlight: false,
            completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts
        ),
        "ECM recovery ignored its attempt limit"
    )
    try expect(
        CellularLinkRecoveryPolicy.shouldRestartModule(
            network: recoverableNetwork,
            modem: recoverableModem,
            hasCall: false,
            completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts,
            alreadyRestarted: false
        ),
        "exhausted soft recovery did not request one controlled module restart"
    )
    try expect(
        !CellularLinkRecoveryPolicy.shouldRestartModule(
            network: recoverableNetwork,
            modem: recoverableModem,
            hasCall: false,
            completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts,
            alreadyRestarted: true
        ),
        "cellular recovery requested a second automatic module restart"
    )
    try expect(
        CellularLinkRecoveryPolicy.delayNanoseconds(completedAttempts: 0) == 3_000_000_000 &&
            CellularLinkRecoveryPolicy.delayNanoseconds(completedAttempts: 1) == 15_000_000_000 &&
            CellularLinkRecoveryPolicy.delayNanoseconds(completedAttempts: 2) == 30_000_000_000,
        "ECM recovery backoff changed unexpectedly"
    )

    // SOCKS5 method negotiation must consume exactly one frame and preserve
    // pipelined bytes for the authentication or request phase.
    let methodFrame = Data([0x05, 0x02, 0x00, 0x02, 0xAA])
    let methods = try SOCKSProtocol.decodeMethodSelection(methodFrame)
    try expect(
        methods.methods == [0x00, 0x02] && methods.consumedByteCount == 4,
        "SOCKS5 method negotiation did not preserve a pipelined frame"
    )
    try expect(
        SOCKSProtocol.encodeMethodSelectionResponse(.usernamePassword) == Data([0x05, 0x02]) &&
            SOCKSProtocol.encodeMethodSelectionResponse(.noAcceptableMethods) == Data([0x05, 0xFF]),
        "SOCKS5 method selection response was encoded incorrectly"
    )

    let authFrame = Data([0x01, 0x04]) + Data("user".utf8) +
        Data([0x06]) + Data("secret".utf8) + Data([0xBB])
    let credentials = try SOCKSProtocol.decodeUsernamePassword(authFrame)
    try expect(
        credentials.username == "user" && credentials.password == "secret" &&
            credentials.consumedByteCount == authFrame.count - 1,
        "SOCKS5 username/password frame was decoded incorrectly"
    )
    try expect(
        SOCKSProtocol.encodeUsernamePasswordResponse(succeeded: true) == Data([0x01, 0x00]) &&
            SOCKSProtocol.encodeUsernamePasswordResponse(succeeded: false) == Data([0x01, 0x01]),
        "SOCKS5 authentication response was encoded incorrectly"
    )

    let ipv4Request = try SOCKSProtocol.decodeRequest(Data([
        0x05, 0x01, 0x00, 0x01, 192, 0, 2, 1, 0x01, 0xBB,
    ]))
    try expect(
        ipv4Request.command == SOCKSCommand.connect.rawValue &&
            ipv4Request.address == .ipv4([192, 0, 2, 1]) &&
            ipv4Request.port == 443 && ipv4Request.consumedByteCount == 10,
        "SOCKS5 IPv4 CONNECT request was decoded incorrectly"
    )

    let domainBytes = Array("example.com".utf8)
    let domainRequest = try SOCKSProtocol.decodeRequest(
        Data([0x05, 0x01, 0x00, 0x03, UInt8(domainBytes.count)] + domainBytes + [0x00, 0x50])
    )
    try expect(
        domainRequest.address == .domain("example.com") && domainRequest.port == 80,
        "SOCKS5 domain CONNECT request was decoded incorrectly"
    )

    let ipv6Address = Array(0..<16).map(UInt8.init)
    let ipv6Request = try SOCKSProtocol.decodeRequest(
        Data([0x05, 0x01, 0x00, 0x04] + ipv6Address + [0x14, 0xE9])
    )
    try expect(
        ipv6Request.address == .ipv6(ipv6Address) && ipv6Request.port == 5353,
        "SOCKS5 IPv6 CONNECT request was decoded incorrectly"
    )

    let reply = try SOCKSProtocol.encodeReply(
        .succeeded,
        boundAddress: .ipv4([10, 12, 34, 34]),
        boundPort: 1080
    )
    try expect(
        reply == Data([0x05, 0x00, 0x00, 0x01, 10, 12, 34, 34, 0x04, 0x38]),
        "SOCKS5 CONNECT response was encoded incorrectly"
    )

    let udpPayload = Data([
        0x00, 0x00, 0x00, 0x01, 203, 0, 113, 7, 0x11, 0x94, 0xde, 0xad,
    ])
    let udpDatagram = try SOCKSProtocol.decodeUDPDatagram(udpPayload)
    try expect(
        udpDatagram.address == .ipv4([203, 0, 113, 7]) &&
            udpDatagram.port == 4500 && udpDatagram.payload == Data([0xde, 0xad]),
        "SOCKS5 UDP datagram was decoded incorrectly"
    )
    let encodedUDPDatagram = try SOCKSProtocol.encodeUDPDatagram(udpDatagram)
    try expect(
        encodedUDPDatagram == udpPayload,
        "SOCKS5 UDP datagram encoding did not round-trip"
    )
    do {
        _ = try SOCKSProtocol.decodeUDPDatagram(
            Data([0x00, 0x00, 0x01, 0x01, 127, 0, 0, 1, 0x00, 0x35])
        )
        throw SelfTestFailure.failed("fragmented SOCKS5 UDP datagram was accepted")
    } catch SOCKSProtocolError.fragmentedUDPDatagram(1) {
        // Expected: RFC 1928 fragmentation is deliberately unsupported.
    }

    let truncatedSOCKSFrames: [Data] = [
        Data(),
        Data([0x05]),
        Data([0x05, 0x02, 0x00]),
    ]
    for frame in truncatedSOCKSFrames {
        do {
            _ = try SOCKSProtocol.decodeMethodSelection(frame)
            throw SelfTestFailure.failed("truncated SOCKS5 method frame was accepted")
        } catch SOCKSProtocolError.incomplete {
            // Expected.
        }
    }
    do {
        _ = try SOCKSProtocol.decodeRequest(Data([0x04, 0x01, 0x00, 0x01]))
        throw SelfTestFailure.failed("SOCKS4 request was accepted")
    } catch SOCKSProtocolError.invalidVersion(0x04) {
        // Expected.
    }
    do {
        _ = try SOCKSProtocol.decodeRequest(Data([0x05, 0x01, 0x01, 0x01]))
        throw SelfTestFailure.failed("SOCKS5 request with nonzero RSV was accepted")
    } catch SOCKSProtocolError.invalidReservedByte(0x01) {
        // Expected.
    }
    do {
        _ = try SOCKSProtocol.decodeRequest(Data([0x05, 0x01, 0x00, 0x09]))
        throw SelfTestFailure.failed("SOCKS5 request with unknown ATYP was accepted")
    } catch SOCKSProtocolError.invalidAddressType(0x09) {
        // Expected.
    }
    do {
        _ = try SOCKSProtocol.decodeUsernamePassword(Data([0x01, 0x00]))
        throw SelfTestFailure.failed("SOCKS5 authentication accepted an empty username")
    } catch SOCKSProtocolError.invalidLength {
        // Expected.
    }

    let primaryProxyID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    let backupProxyID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    let otherProxyID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    let newProxyDraft = SOCKSProxyConfiguration.newDraft(
        moduleIMEI: "860000000000000",
        port: 1080
    )
    try expect(
        newProxyDraft.name.isEmpty &&
            !newProxyDraft.isEnabled &&
            newProxyDraft.listenScope == .loopback &&
            newProxyDraft.authentication == .none,
        "a new SOCKS proxy was given a default name or enabled automatically"
    )
    let primaryProxy = SOCKSProxyConfiguration(
        id: primaryProxyID,
        name: "移动主力",
        moduleIMEI: "860000000000001",
        listenScope: .loopback,
        port: 1080,
        isEnabled: true,
        authentication: .usernamePassword(username: "user")
    )
    let encodedProxy = try JSONEncoder().encode(primaryProxy)
    let decodedProxy = try JSONDecoder().decode(
        SOCKSProxyConfiguration.self,
        from: encodedProxy
    )
    try expect(
        decodedProxy == primaryProxy,
        "SOCKS proxy configuration did not survive persistence round trip"
    )

    try expect(
        SOCKSProxyPortAllocator.nextAvailable(used: []) == 1080 &&
            SOCKSProxyPortAllocator.nextAvailable(used: [1080, 1081, 1083]) == 1082,
        "SOCKS proxy port allocator did not select the first free port"
    )
    let exhaustedProxyPorts = Set(SOCKSProxyPortAllocator.base...UInt16.max)
    try expect(
        SOCKSProxyPortAllocator.nextAvailable(used: exhaustedProxyPorts) == nil,
        "SOCKS proxy port allocator did not report exhaustion"
    )
    let backupProxy = SOCKSProxyConfiguration(
        id: backupProxyID,
        name: "移动备用",
        moduleIMEI: primaryProxy.moduleIMEI,
        listenScope: .loopback,
        port: 1080,
        isEnabled: false,
        authentication: .none
    )
    let otherProxy = SOCKSProxyConfiguration(
        id: otherProxyID,
        name: "联通备用",
        moduleIMEI: "860000000000002",
        listenScope: .loopback,
        port: 1081,
        isEnabled: true,
        authentication: .none
    )
    try expect(
        SOCKSProxyPortAllocator.conflicts(in: [primaryProxy, backupProxy, otherProxy]) == [
            primaryProxyID, backupProxyID,
        ],
        "SOCKS proxy port conflict detection missed a disabled reservation or included a free port"
    )

    var readyProxyNetwork = CellularNetworkStatus(
        isEnabled: true,
        isLinkActive: true,
        isHardwarePresent: true
    )
    try expect(
        SOCKSProxyRunPolicy.shouldListen(
            isEnabled: true,
            mode: .standby,
            network: readyProxyNetwork
        ) && SOCKSProxyRunPolicy.shouldListen(
            isEnabled: true,
            mode: .preferred,
            network: readyProxyNetwork
        ),
        "SOCKS proxy did not run for both enabled cellular modes"
    )
    try expect(
        !SOCKSProxyRunPolicy.shouldListen(
            isEnabled: true,
            mode: .off,
            network: readyProxyNetwork
        ) && SOCKSProxyRunPolicy.stoppedState(
            isEnabled: true,
            mode: .off,
            network: readyProxyNetwork
        ) == .stoppedCellularDisabled,
        "SOCKS proxy remained available while cellular networking was off"
    )
    readyProxyNetwork.isLinkActive = false
    try expect(
        !SOCKSProxyRunPolicy.shouldListen(
            isEnabled: true,
            mode: .standby,
            network: readyProxyNetwork
        ) && SOCKSProxyRunPolicy.stoppedState(
            isEnabled: true,
            mode: .standby,
            network: readyProxyNetwork
        ) == .stoppedLinkDown,
        "SOCKS proxy did not fail closed when the ECM link dropped"
    )
    readyProxyNetwork.isLinkActive = true
    readyProxyNetwork.isEnabled = false
    try expect(
        !SOCKSProxyRunPolicy.shouldListen(
            isEnabled: true,
            mode: .standby,
            network: readyProxyNetwork
        ) && SOCKSProxyRunPolicy.stoppedState(
            isEnabled: true,
            mode: .standby,
            network: readyProxyNetwork
        ) == .stoppedCellularDisabled,
        "SOCKS proxy remained available while its network service was disabled"
    )
    try expect(
        SOCKSProxyRunPolicy.stoppedState(
            isEnabled: false,
            mode: .off,
            network: nil
        ) == .disabled && SOCKSProxyRunPolicy.stoppedState(
            isEnabled: true,
            mode: .standby,
            network: nil
        ) == .stoppedModuleOffline,
        "SOCKS proxy stopped-state precedence changed"
    )

    let dnsServers = CellularDNSStateParser.serverAddresses(from: [
        "ServerAddresses": [
            "192.168.225.1",
            " 2001:db8::53 ",
            "192.168.225.1",
            "",
        ],
    ])
    try expect(
        dnsServers == ["192.168.225.1", "2001:db8::53"] &&
            CellularDNSStateParser.serverAddresses(from: nil).isEmpty &&
            CellularDNSStateParser.serverAddresses(from: ["ServerAddresses": "invalid"]).isEmpty,
        "cellular DNS state was not normalized and deduplicated"
    )
    try expect(
        SOCKSDNSResolver.serverCandidates(advertised: ["192.168.225.1", "8.8.8.8"]) ==
            ["192.168.225.1", "8.8.8.8", "8.8.4.4"] &&
            SOCKSDNSResolver.serverCandidates(advertised: []).starts(with: ["8.8.8.8"]),
        "SOCKS DNS fallback ordering or deduplication changed"
    )

    let bindingSnapshot = SOCKSModuleNetworkBindingSnapshot(
        moduleID: CellularModuleID(rawValue: "usb-location:00100000"),
        moduleIMEI: primaryProxy.moduleIMEI,
        serviceID: "service-1",
        bsdName: "en11",
        ipv4Address: "192.168.225.20",
        ipv6Address: nil,
        dnsServers: dnsServers
    )
    try expect(
        bindingSnapshot.moduleIMEI == primaryProxy.moduleIMEI &&
            bindingSnapshot.bsdName == "en11" &&
            bindingSnapshot.dnsServers == dnsServers,
        "SOCKS module network binding snapshot lost runtime identity"
    )

    let loopbackIndex = if_nametoindex("lo0")
    // A client can close between readiness and a write. This must become an
    // ordinary EPIPE path instead of terminating CellDock with SIGPIPE.
    SOCKSSignalSafety.install()
    try expect(raise(SIGPIPE) == 0, "SIGPIPE safety handler was not installed")
    try expect(loopbackIndex != 0, "test host has no loopback interface")
    let localVoWiFiProxy = VoWiFiUpstreamProxySnapshot(
        id: UUID(),
        name: "local",
        host: "127.0.0.1",
        port: 6153,
        username: nil,
        password: nil
    )
    let remoteVoWiFiProxy = VoWiFiUpstreamProxySnapshot(
        id: UUID(),
        name: "remote",
        host: "192.0.2.10",
        port: 1080,
        username: nil,
        password: nil
    )
    try expect(
        localVoWiFiProxy.usesLoopbackEndpoint &&
            !remoteVoWiFiProxy.usesLoopbackEndpoint,
        "VoWiFi proxy probe did not distinguish loopback from outer endpoints"
    )
    let boundIPv4TCP = try BoundSocket(family: .ipv4, kind: .tcp, bsdName: "lo0")
    let actualIPv4BoundIndex = try boundIPv4TCP.currentBoundInterfaceIndex()
    try expect(
        boundIPv4TCP.interfaceIndex == loopbackIndex &&
            actualIPv4BoundIndex == loopbackIndex,
        "IPv4 TCP socket was not bound to the requested interface"
    )
    do {
        try boundIPv4TCP.connect(to: .domain("example.com"), port: 443)
        throw SelfTestFailure.failed("bound socket accepted a domain through the system resolver")
    } catch BoundSocketError.domainRequiresResolution {
        // Expected.
    }
    boundIPv4TCP.close()
    do {
        _ = try boundIPv4TCP.currentBoundInterfaceIndex()
        throw SelfTestFailure.failed("closed bound socket remained usable")
    } catch BoundSocketError.systemCall(operation: "getsockopt", code: EBADF) {
        // Expected.
    }

    let boundIPv6UDP = try BoundSocket(family: .ipv6, kind: .udp, bsdName: "lo0")
    let actualIPv6BoundIndex = try boundIPv6UDP.currentBoundInterfaceIndex()
    try expect(
        actualIPv6BoundIndex == loopbackIndex,
        "IPv6 UDP socket was not bound to the requested interface"
    )
    do {
        _ = try BoundSocket(
            family: .ipv4,
            kind: .tcp,
            bsdName: "celldock-interface-does-not-exist"
        )
        throw SelfTestFailure.failed("unknown interface produced an unbound fallback socket")
    } catch BoundSocketError.interfaceNotFound("celldock-interface-does-not-exist") {
        // Expected.
    }

    let dnsQuery = try SOCKSDNSCodec.encodeQuery(name: "example.com", type: .a, id: 0x1234)
    try expect(
        dnsQuery == Data([
            0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x07, 0x65, 0x78, 0x61,
            0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d,
            0x00, 0x00, 0x01, 0x00, 0x01,
        ]),
        "DNS A query encoding changed"
    )
    var dnsAResponse = Array(dnsQuery)
    dnsAResponse[2] = 0x81
    dnsAResponse[3] = 0x80
    dnsAResponse[6] = 0x00
    dnsAResponse[7] = 0x01
    dnsAResponse += [
        0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x3c, 0x00, 0x04, 93, 184, 216, 34,
    ]
    let decodedDNSA = try SOCKSDNSCodec.decodeResponse(
        Data(dnsAResponse), expectedID: 0x1234, type: .a
    )
    let decodedDNSAWithTTL = try SOCKSDNSCodec.decodeResponseWithTTL(
        Data(dnsAResponse), expectedID: 0x1234, type: .a
    )
    try expect(
        decodedDNSA == [.ipv4([93, 184, 216, 34])] &&
            decodedDNSAWithTTL.minimumTTL == 60,
        "DNS compressed A response was decoded incorrectly"
    )
    let dnsCache = SOCKSDNSCache()
    let cacheNow = Date(timeIntervalSince1970: 1_800_000_000)
    dnsCache.insert(
        decodedDNSA,
        domain: "Example.COM.",
        type: .a,
        bsdName: "en11",
        ttl: 60,
        now: cacheNow
    )
    try expect(
        dnsCache.addresses(
            domain: "example.com", type: .a, bsdName: "en11",
            now: cacheNow.addingTimeInterval(59)
        ) == decodedDNSA &&
            dnsCache.addresses(
                domain: "example.com", type: .a, bsdName: "en12",
                now: cacheNow.addingTimeInterval(1)
            ) == nil &&
            dnsCache.addresses(
                domain: "example.com", type: .a, bsdName: "en11",
                now: cacheNow.addingTimeInterval(60)
            ) == nil,
        "SOCKS DNS cache ignored expiry or module-interface isolation"
    )
    var dnsAAAAResponse = Array(try SOCKSDNSCodec.encodeQuery(
        name: "example.com", type: .aaaa, id: 0x4321
    ))
    dnsAAAAResponse[2] = 0x81
    dnsAAAAResponse[3] = 0x80
    dnsAAAAResponse[7] = 0x01
    let exampleIPv6: [UInt8] = [
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    ]
    dnsAAAAResponse += [
        0xc0, 0x0c, 0x00, 0x1c, 0x00, 0x01, 0, 0, 0, 60, 0, 16,
    ] + exampleIPv6
    let decodedDNSAAAA = try SOCKSDNSCodec.decodeResponse(
        Data(dnsAAAAResponse), expectedID: 0x4321, type: .aaaa
    )
    try expect(
        decodedDNSAAAA == [.ipv6(exampleIPv6)],
        "DNS AAAA response was decoded incorrectly"
    )
    var nxdomainResponse = Array(dnsQuery)
    nxdomainResponse[2] = 0x81
    nxdomainResponse[3] = 0x83
    do {
        _ = try SOCKSDNSCodec.decodeResponse(
            Data(nxdomainResponse), expectedID: 0x1234, type: .a
        )
        throw SelfTestFailure.failed("DNS NXDOMAIN response was accepted")
    } catch SOCKSDNSError.nameError {
        // Expected.
    }
    do {
        _ = try SOCKSDNSCodec.decodeResponse(
            Data(dnsAResponse.dropLast()), expectedID: 0x1234, type: .a
        )
        throw SelfTestFailure.failed("truncated DNS response was accepted")
    } catch SOCKSDNSError.truncated {
        // Expected.
    }

    let voWiFiSession = "1f4b9c2ad0e34f6f9b1c7d2e5a8f0b31"

    let voWiFiMissingHost = VoWiFiRuntimeStatus.parse(keyValueOutput: """
    protocol=4
    supported=0
    running=0
    reason=control-host-missing
    """)
    guard case .unsupported = VoWiFiSessionState(
        status: voWiFiMissingHost, expectedSessionID: nil
    ) else {
        throw SelfTestFailure.failed("a module without a vowifi-go control host was accepted")
    }
    try expect(
        VoWiFiSessionState(status: voWiFiMissingHost, expectedSessionID: nil).pollInterval == nil,
        "an unsupported module kept polling the shared ADB control channel"
    )

    let voWiFiOldProtocol = VoWiFiRuntimeStatus.parse(keyValueOutput: """
    protocol=2
    supported=1
    running=1
    phase=ready
    ims_ready=1
    """)
    try expect(
        !voWiFiOldProtocol.isSupported,
        "an incompatible vowifi-go control protocol was accepted"
    )

    let voWiFiStopped = VoWiFiRuntimeStatus.parse(keyValueOutput: """
    protocol=4
    supported=1
    running=0
    phase=stopped
    """)
    try expect(
        VoWiFiSessionState(status: voWiFiStopped, expectedSessionID: nil) == .stopped,
        "a stopped vowifi-go runtime was not reported as stopped"
    )

    // A module with no WLAN radio is the normal case for the SOCKS transport;
    // readiness must never depend on a module-side Wi-Fi link.
    let voWiFiRegistered = VoWiFiRuntimeStatus.parse(keyValueOutput: """
    protocol=4
    supported=1
    running=1
    session=\(voWiFiSession)
    phase=ready
    dataplane_mode=userspace
    sim_ready=true
    access_ready=true
    tunnel_ready=true
    ims_ready=true
    reg_status=200
    last_reason=registered
    """)
    try expect(
        voWiFiRegistered.isSupported &&
            voWiFiRegistered.registrationStatus == 200 &&
            VoWiFiSessionState(
                status: voWiFiRegistered, expectedSessionID: voWiFiSession
            ) == .registered(voWiFiRegistered),
        "a fully registered vowifi-go session was not reported as registered"
    )

    // The same reply, but started by a previous CellDock launch: its SOCKS5
    // relay no longer exists, so it must never render as healthy.
    try expect(
        VoWiFiSessionState(
            status: voWiFiRegistered, expectedSessionID: "other-session"
        ) == .desynchronized(voWiFiRegistered),
        "a foreign vowifi-go session was accepted as our own"
    )

    let voWiFiTunnelPending = VoWiFiRuntimeStatus.parse(keyValueOutput: """
    protocol=4
    supported=1
    running=1
    session=\(voWiFiSession)
    phase=sim_ready
    dataplane_mode=userspace
    sim_ready=1
    access_ready=1
    tunnel_ready=0
    ims_ready=0
    """)
    try expect(
        VoWiFiSessionState(
            status: voWiFiTunnelPending, expectedSessionID: voWiFiSession
        ) == .establishingTunnel(voWiFiTunnelPending),
        "vowifi-go SWu establishment was not reported"
    )

    let voWiFiTunnelBlocked = VoWiFiRuntimeStatus.parse(keyValueOutput: """
    protocol=4
    supported=1
    running=1
    session=\(voWiFiSession)
    phase=tunnel_blocked
    dataplane_mode=userspace
    sim_ready=1
    access_ready=1
    tunnel_ready=0
    last_reason=SWU tunnel establishment failed: IKE response timeout
    """)
    try expect(
        VoWiFiSessionState(
            status: voWiFiTunnelBlocked, expectedSessionID: voWiFiSession
        ) == .establishingTunnel(voWiFiTunnelBlocked),
        "a blocked ePDG stage was misreported as a runtime process failure"
    )

    let voWiFiRegisteringIMS = VoWiFiRuntimeStatus.parse(keyValueOutput: """
    protocol=4
    supported=1
    running=1
    session=\(voWiFiSession)
    phase=sim_ready
    dataplane_mode=userspace
    sim_ready=1
    access_ready=1
    tunnel_ready=1
    ims_ready=0
    """)
    try expect(
        VoWiFiSessionState(
            status: voWiFiRegisteringIMS, expectedSessionID: voWiFiSession
        ) == .registeringIMS(voWiFiRegisteringIMS),
        "vowifi-go IMS registration was not reported"
    )

    // engine/swu rejects SOCKSNATTTransport unless the dataplane is userspace,
    // so a kernel-XFRM host can never carry this transport.
    let voWiFiKernelDataplane = VoWiFiRuntimeStatus.parse(keyValueOutput: """
    protocol=4
    supported=1
    running=1
    session=\(voWiFiSession)
    phase=ready
    dataplane_mode=kernel
    sim_ready=1
    access_ready=1
    tunnel_ready=1
    ims_ready=1
    """)
    guard case .failed = VoWiFiSessionState(
        status: voWiFiKernelDataplane, expectedSessionID: voWiFiSession
    ) else {
        throw SelfTestFailure.failed("a kernel dataplane was accepted for the SOCKS5 transport")
    }

    let voWiFiFaulted = VoWiFiRuntimeStatus.parse(keyValueOutput: """
    protocol=4
    supported=1
    running=1
    session=\(voWiFiSession)
    phase=error
    dataplane_mode=userspace
    sim_ready=1
    access_ready=0
    last_error_class=swu_proxy
    last_reason=socks-udp-associate-rejected
    """)
    try expect(
        VoWiFiSessionState(
            status: voWiFiFaulted, expectedSessionID: voWiFiSession
        ) == .failed("socks-udp-associate-rejected"),
        "a faulted vowifi-go runtime was not surfaced with its redacted reason"
    )

    let voWiFiStartCommand = try VoWiFiRuntimeControl.startCommand(VoWiFiSessionRequest(
        sessionID: voWiFiSession,
        proxyURL: "socks5://vowifi:s3cret@192.168.225.34:52001"
    ))
    try expect(
        !voWiFiStartCommand.contains("--proxy") &&
            voWiFiStartCommand.contains("\"$tool\" start <<'") &&
            voWiFiStartCommand.contains("proxy=socks5://vowifi:s3cret@192.168.225.34:52001"),
        "the vowifi-go session credential was not delivered on stdin"
    )
    try expect(
        VoWiFiRuntimeControl.statusCommand.contains("celldock-vowifi-go") &&
            !VoWiFiRuntimeControl.statusCommand.contains("wfc_ims_enabled") &&
            !VoWiFiRuntimeControl.statusCommand.contains("wlan"),
        "the VoWiFi probe still reaches for a module-side WLAN backend"
    )

    do {
        _ = try VoWiFiRuntimeControl.startCommand(VoWiFiSessionRequest(
            sessionID: voWiFiSession,
            proxyURL: "socks5://vowifi:pass@host:1080\nCELLDOCK_VOWIFI_\(voWiFiSession.uppercased().prefix(24))"
        ))
        throw SelfTestFailure.failed("a session payload was allowed to close its own heredoc")
    } catch VoWiFiControlError.unsafeConfiguration {
        // Expected.
    }

    print("CellDock self-tests passed (calls, PDU/UDH, SOCKS5, VoWiFi, buffering, storage, merge, USB config).")
} catch {
    fputs("Self-test failed: \(error)\n", stderr)
    exit(1)
}

// MARK: - USBConfiguration + USBModeController Tests

do {
    // --- USBConfiguration parsing tests ---

    // 1. Real DJOneHub/EG25 USBCFG response
    let realResponse = "+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,0\r\nOK\r\n"
    let realConfig = try USBConfiguration.parse(response: realResponse).get()
    try expect(realConfig.vendorID == 0x2CA3, "real response VID mismatch")
    try expect(realConfig.productID == 0x4006, "real response PID mismatch")
    try expect(realConfig.atEnabled == true, "real response AT mismatch")
    try expect(realConfig.nmeaEnabled == true, "real response NMEA mismatch")
    try expect(realConfig.diagEnabled == true, "real response DIAG mismatch")
    try expect(realConfig.modemEnabled == true, "real response modem mismatch")
    try expect(realConfig.reservedFlag == true, "real response reserved mismatch")
    try expect(realConfig.adbEnabled == false, "real response ADB mismatch")
    try expect(realConfig.uacEnabled == false, "real response UAC mismatch")

    // 2. Response with AT echo
    let echoResponse = "AT+QCFG=\"usbcfg\"\r\n+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,1,1\r\nOK\r\n"
    let echoConfig = try USBConfiguration.parse(response: echoResponse).get()
    try expect(echoConfig.uacEnabled == true, "AT echo response UAC mismatch")
    try expect(echoConfig.adbEnabled == true, "AT echo response ADB mismatch")

    // 3. Response with CRLF + OK
    let crlfResponse = "\r\n+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,1\r\n\r\nOK\r\n"
    let crlfConfig = try USBConfiguration.parse(response: crlfResponse).get()
    try expect(crlfConfig.uacEnabled == true, "CRLF response UAC mismatch")

    // 4. Malformed response - missing +QCFG prefix
    do {
        _ = try USBConfiguration.parse(response: "garbage").get()
        throw SelfTestFailure.failed("malformed response was accepted")
    } catch USBConfiguration.USBConfigurationError.missingUSBCFGPrefix {
        // Expected
    }

    // 5. Missing field (only 8 fields)
    do {
        _ = try USBConfiguration.parse(response: "+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0\r\n").get()
        throw SelfTestFailure.failed("missing field was accepted")
    } catch USBConfiguration.USBConfigurationError.unsupportedFieldCount(8) {
        // Expected
    }

    // 6. Invalid numeric field (non-hex VID)
    do {
        _ = try USBConfiguration.parse(response: "+QCFG: \"usbcfg\",ZZZZ,0x4006,1,1,1,1,1,0,0\r\n").get()
        throw SelfTestFailure.failed("invalid hex VID was accepted")
    } catch USBConfiguration.USBConfigurationError.invalidHexField {
        // Expected
    }

    // 7. Invalid binary field (value 2)
    do {
        _ = try USBConfiguration.parse(response: "+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,2\r\n").get()
        throw SelfTestFailure.failed("invalid binary field was accepted")
    } catch USBConfiguration.USBConfigurationError.invalidBinaryField {
        // Expected
    }

    // 8. Empty response
    do {
        _ = try USBConfiguration.parse(response: "").get()
        throw SelfTestFailure.failed("empty response was accepted")
    } catch USBConfiguration.USBConfigurationError.emptyResponse {
        // Expected
    }

    // --- USBModeController transformation tests ---

    let executor: USBModeController.ATCommandExecutor = { _, _ in ("", 0) }
    let controller = USBModeController(executor: executor)

    let macFullConfig = try USBConfiguration.parse(
        response: "+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,1,1\r\n"
    ).get()

    // 9. Mac → Mobile transformation (UAC off)
    let mobileDesired = controller.configuration(from: macFullConfig, for: .mobile)
    try expect(mobileDesired != nil, "mac→mobile returned nil (should produce target)")
    try expect(mobileDesired!.uacEnabled == false, "mac→mobile did not clear UAC")

    // 10-13. Non-UAC fields unchanged
    try expect(mobileDesired!.vendorID == macFullConfig.vendorID, "VID changed during mac→mobile")
    try expect(mobileDesired!.productID == macFullConfig.productID, "PID changed during mac→mobile")
    try expect(mobileDesired!.atEnabled == macFullConfig.atEnabled, "AT changed during mac→mobile")
    try expect(mobileDesired!.modemEnabled == macFullConfig.modemEnabled, "modem changed during mac→mobile")

    // 14. Validate diff only touches UAC
    let diffResult = controller.validateDiff(from: macFullConfig, to: mobileDesired!)
    switch diffResult {
    case .success(let desc):
        try expect(desc.contains("UAC"), "diff description did not mention UAC")
    case .failure(let error):
        throw SelfTestFailure.failed("validateDiff failed: \(error)")
    }

    // 15. Mobile → Mac transformation (UAC on)
    let mobileConfig = try USBConfiguration.parse(
        response: "+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,0\r\n"
    ).get()
    let macDesired = controller.configuration(from: mobileConfig, for: .mac)
    try expect(macDesired != nil, "mobile→mac returned nil")
    try expect(macDesired!.uacEnabled == true, "mobile→mac did not enable UAC")
    try expect(macDesired!.vendorID == mobileConfig.vendorID, "VID changed during mobile→mac")

    // 16. Already mobile → mobile = no-op (nil)
    let noOpMobile = controller.configuration(from: mobileConfig, for: .mobile)
    try expect(noOpMobile == nil, "already mobile→mobile should be nil")

    // 17. Already mac → mac = no-op (nil)
    let noOpMac = controller.configuration(from: macFullConfig, for: .mac)
    try expect(noOpMac == nil, "already mac→mac should be nil")

    // 18. Round-trip: parse → serialize → parse
    let serialized = realConfig.writeCommand
    try expect(serialized.hasPrefix("AT+QCFG=\"usbcfg\","), "writeCommand prefix wrong")
    let fields = String(serialized.dropFirst("AT+QCFG=\"usbcfg\",".count))
    let roundTrip = try USBConfiguration.parse(
        response: "+QCFG: \"usbcfg\",\(fields)\r\n"
    ).get()
    try expect(roundTrip == realConfig, "round-trip parse did not reproduce original config")

    // 19. Validate diff catches unexpected VID change
    let vidDiff = controller.validateDiff(
        from: realConfig,
        to: USBConfiguration(vendorID: 0xFFFF, productID: realConfig.productID,
                              atEnabled: true, nmeaEnabled: true, diagEnabled: true,
                              modemEnabled: true, reservedFlag: true, adbEnabled: false,
                              uacEnabled: false)
    )
    switch vidDiff {
    case .failure(.unexpectedFieldChange("VendorID")):
        break // Expected
    default:
        throw SelfTestFailure.failed("VID diff not caught")
    }

    print("USB configuration tests passed (parse, transform, validate, round-trip).")
}

do {
    // ============================================================
    // MARK: - USB Mode Manager tests
    // These exercise ModemUSBConfiguration's mode derivation and
    // the "only toggle UAC, preserve everything else" transform that
    // the USB mode management path is built on.
    // ============================================================

    // A Mac / CellDock configuration (UAC=1) parsed from a real AT response.
    let macLine = "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1,1\r\nOK"
    let macConfig = try expectNonNil(
        ATResponseParser.parseUSBConfiguration(macLine),
        "Mac USBCFG should parse"
    )
    try expect(macConfig.vendorID == 0x2C7C, "Mac config vendor ID")
    try expect(macConfig.productID == 0x0125, "Mac config product ID")
    try expect(macConfig.audioEnabled == true, "Mac config UAC")
    try expect(macConfig.usbConnectionMode == .mac, "Mac config derives .mac mode")
    try expect(macConfig.isCellDockTarget, "Mac config is CellDock target")

    // A Mobile / iPhone configuration (UAC=0).
    let mobileLine = "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1,0\r\nOK"
    let mobileConfig = try expectNonNil(
        ATResponseParser.parseUSBConfiguration(mobileLine),
        "Mobile USBCFG should parse"
    )
    try expect(mobileConfig.audioEnabled == false, "Mobile config UAC cleared")
    try expect(mobileConfig.usbConnectionMode == .mobile, "Mobile config derives .mobile mode")

    // Toggling Mobile → Mac must flip only UAC, preserving all other 8 fields.
    let macTarget = mobileConfig.switchingUSBMode(to: .mac)
    try expect(macTarget.audioEnabled == true, "mobile→mac enables UAC")
    try expect(macTarget.vendorID == mobileConfig.vendorID, "mobile→mac keeps VID")
    try expect(macTarget.productID == mobileConfig.productID, "mobile→mac keeps PID")
    try expect(macTarget.diagnosticEnabled == mobileConfig.diagnosticEnabled, "mobile→mac keeps diag")
    try expect(macTarget.nmeaEnabled == mobileConfig.nmeaEnabled, "mobile→mac keeps nmea")
    try expect(macTarget.atPortEnabled == mobileConfig.atPortEnabled, "mobile→mac keeps at")
    try expect(macTarget.modemEnabled == mobileConfig.modemEnabled, "mobile→mac keeps modem")
    try expect(macTarget.networkEnabled == mobileConfig.networkEnabled, "mobile→mac keeps net")
    try expect(macTarget.adbEnabled == mobileConfig.adbEnabled, "mobile→mac keeps adb")

    // Toggling Mac → Mobile must flip only UAC.
    let mobileTarget = macConfig.switchingUSBMode(to: .mobile)
    try expect(mobileTarget.audioEnabled == false, "mac→mobile clears UAC")
    try expect(mobileTarget.vendorID == macConfig.vendorID, "mac→mobile keeps VID")
    try expect(mobileTarget.productID == macConfig.productID, "mac→mobile keeps PID")
    try expect(mobileTarget.adbEnabled == macConfig.adbEnabled, "mac→mobile keeps adb")
    try expect(mobileTarget.diagnosticEnabled == macConfig.diagnosticEnabled, "mac→mobile keeps diag")
    try expect(mobileTarget.nmeaEnabled == macConfig.nmeaEnabled, "mac→mobile keeps nmea")
    try expect(mobileTarget.atPortEnabled == macConfig.atPortEnabled, "mac→mobile keeps at")
    try expect(mobileTarget.modemEnabled == macConfig.modemEnabled, "mac→mobile keeps modem")
    try expect(mobileTarget.networkEnabled == macConfig.networkEnabled, "mac→mobile keeps net")

    // Parse → serialize → parse round-trip preserves all fields.
    // Simulate the modem echoing the written command back as its USBCFG line.
    let writtenCommand = macConfig.usbcfgWriteCommand
    let replyPrefix = "+QCFG: \"usbcfg\","
    guard writtenCommand.hasPrefix("AT+QCFG=\"USBCFG\",") else {
        throw SelfTestFailure.failed("writeCommand prefix wrong")
    }
    let replyBody = String(writtenCommand.dropFirst("AT+QCFG=\"USBCFG\",".count))
    let roundTripConfig = try expectNonNil(
        ATResponseParser.parseUSBConfiguration("\(replyPrefix)\(replyBody)\r\nOK"),
        "writeCommand round-trip should parse"
    )
    try expect(roundTripConfig == macConfig, "mac config round-trips losslessly")

    // Idempotency: switching to the mode you are already in is a no-op result.
    try expect(mobileConfig.usbConnectionMode == .mobile, "mobile already in .mobile")
    try expect(macConfig.usbConnectionMode == .mac, "mac already in .mac")

    // Unsupported identity: a non-DJI / non-Quectel VID entirely outside scope.
    let unsupportedLine = "+QCFG: \"usbcfg\",0x1234,0xABCD,1,1,1,1,1,1,1\r\nOK"
    let unsupportedConfig = try expectNonNil(
        ATResponseParser.parseUSBConfiguration(unsupportedLine),
        "Unsupported USBCFG still parses structurally"
    )
    try expect(!(unsupportedConfig.vendorID == 0x2C7C && unsupportedConfig.productID == 0x0125),
        "Unsupported VID/PID is not a recognized module identity")

    // Malformed / field-count mismatch must not parse (do-not-write safety).
    let shortLine = "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1\r\nOK"
    try expect(
        ATResponseParser.parseUSBConfiguration(shortLine) == nil,
        "Field-count mismatch must not parse"
    )
    let bannedFlag = "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,2,1\r\nOK"
    try expect(
        ATResponseParser.parseUSBConfiguration(bannedFlag) == nil,
        "Invalid flag value must not parse"
    )
    let missingQCFG = "AT+QCFG=\"usbcfg\"\r\nERROR"
    try expect(
        ATResponseParser.parseUSBConfiguration(missingQCFG) == nil,
        "Response without a +QCFG usbcfg line must not parse"
    )


    // ============================================================
    // MARK: - Single source-of-truth contract regression
    // These tests pin the classification contract shared by the UI, the USB
    // mode controller, and the self-tests: BOTH the DJI-original (audio=1) and
    // the CellDock-compatible (audio=0) compositions are known-safe and one-click
    // switchable. The lone free variable is UAC/audio.
    // ============================================================

    // DJI original / Mac: audio=1.
    try expect(macConfig.usbProfile == .djiOriginal, "Mac audio=1 was not DJI original profile")
    try expect(macConfig.knownSafe == true, "Mac audio=1 was not known-safe")
    try expect(macConfig.oneClickSwitchAllowed == true, "Mac audio=1 did not allow one-click switch")
    try expect(macConfig.usbConnectionMode == .mac, "Mac audio=1 did not derive .mac")
    let macReady = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        usbNetMode: 1,
        usbConfiguration: macConfig
    )
    try expect(macReady.initialSetupState == .ready, "Mac audio=1 QDC507 was not reported ready")

    // CellDock compatible / Mobile: audio=0 — the real reported config.
    try expect(mobileConfig.usbProfile == .cellDockCompatible, "Mobile audio=0 was not CellDock compatible")
    try expect(mobileConfig.knownSafe == true, "Mobile audio=0 was not known-safe")
    try expect(mobileConfig.oneClickSwitchAllowed == true, "Mobile audio=0 did not allow one-click switch")
    try expect(mobileConfig.usbConnectionMode == .mobile, "Mobile audio=0 did not derive .mobile")
    let mobileReady = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        usbNetMode: 1,
        usbConfiguration: mobileConfig
    )
    try expect(mobileReady.initialSetupState == .ready, "Mobile audio=0 QDC507 was not reported ready")
    try expect(
        mobileReady.initialSetupState != .unsupportedUSBConfiguration(
            mobileReady.usbConfiguration!.compactDescription
        ),
        "Mobile audio=0 was rejected as an unsupported USB configuration"
    )
    let mobilePanel = ModemModuleStatusPresentation.derive(snapshot: mobileReady)
    try expect(mobilePanel.configuration == .valid, "Mobile audio=0 was not a valid presentation configuration")
    try expect(mobilePanel.usbMode == .mobile, "Mobile audio=0 presentation did not map to Mobile mode")
    try expect(mobilePanel.profile == .cellDockCompatible, "Mobile audio=0 presentation profile mismatch")

    // Mobile -> Mac: only UAC flips, all other fields bit-for-bit identical.
    let mobileToMac = mobileConfig.switchingUSBMode(to: .mac)
    try expect(mobileToMac.audioEnabled == true, "mobile->mac did not enable audio")
    try expect(mobileToMac.vendorID == mobileConfig.vendorID, "mobile->mac VID changed")
    try expect(mobileToMac.productID == mobileConfig.productID, "mobile->mac PID changed")
    try expect(mobileToMac.diagnosticEnabled == mobileConfig.diagnosticEnabled, "mobile->mac diag changed")
    try expect(mobileToMac.nmeaEnabled == mobileConfig.nmeaEnabled, "mobile->mac nmea changed")
    try expect(mobileToMac.atPortEnabled == mobileConfig.atPortEnabled, "mobile->mac at changed")
    try expect(mobileToMac.modemEnabled == mobileConfig.modemEnabled, "mobile->mac modem changed")
    try expect(mobileToMac.networkEnabled == mobileConfig.networkEnabled, "mobile->mac net changed")
    try expect(mobileToMac.adbEnabled == mobileConfig.adbEnabled, "mobile->mac adb changed")

    // Mac -> Mobile: only UAC flips, all other fields bit-for-bit identical.
    let macToMobile = macConfig.switchingUSBMode(to: .mobile)
    try expect(macToMobile.audioEnabled == false, "mac->mobile did not disable audio")
    try expect(macToMobile.vendorID == macConfig.vendorID, "mac->mobile VID changed")
    try expect(macToMobile.productID == macConfig.productID, "mac->mobile PID changed")
    try expect(macToMobile.diagnosticEnabled == macConfig.diagnosticEnabled, "mac->mobile diag changed")
    try expect(macToMobile.nmeaEnabled == macConfig.nmeaEnabled, "mac->mobile nmea changed")
    try expect(macToMobile.atPortEnabled == macConfig.atPortEnabled, "mac->mobile at changed")
    try expect(macToMobile.modemEnabled == macConfig.modemEnabled, "mac->mobile modem changed")
    try expect(macToMobile.networkEnabled == macConfig.networkEnabled, "mac->mobile net changed")
    try expect(macToMobile.adbEnabled == macConfig.adbEnabled, "mac->mobile adb changed")

    // Profile classifiers agree with the transforms above.
    try expect(mobileToMac.usbProfile == .djiOriginal, "mobile->mac target profile was not DJI original")
    try expect(mobileToMac.knownSafe == true, "mobile->mac target profile was not known-safe")
    try expect(macToMobile.usbProfile == .cellDockCompatible, "mac->mobile target profile was not CellDock compatible")
    try expect(macToMobile.knownSafe == true, "mac->mobile target profile was not known-safe")

    // Protected-field changes are never a safe profile and never pass validateDiff.
    let usbMac = USBConfiguration(
        vendorID: 0x2C7C, productID: 0x0125,
        atEnabled: true, nmeaEnabled: true, diagEnabled: true,
        modemEnabled: true, reservedFlag: true, adbEnabled: true, uacEnabled: true
    )
    let usbMobile = USBConfiguration(
        vendorID: 0x2C7C, productID: 0x0125,
        atEnabled: true, nmeaEnabled: true, diagEnabled: true,
        modemEnabled: true, reservedFlag: true, adbEnabled: true, uacEnabled: false
    )
    let usbExec: USBModeController.ATCommandExecutor = { _, _ in ("", 0) }
    let usbController = USBModeController(executor: usbExec)

    // Only-UAC toggle is the accepted transformation.
    if case .failure = usbController.validateDiff(from: usbMac, to: usbMobile) {
        throw SelfTestFailure.failed("only-UAC toggle was rejected by validateDiff")
    }

    // diag changed -> reject.
    let usbDiagChanged = USBConfiguration(
        vendorID: 0x2C7C, productID: 0x0125,
        atEnabled: true, nmeaEnabled: true, diagEnabled: false,
        modemEnabled: true, reservedFlag: true, adbEnabled: true, uacEnabled: true
    )
    if case .success = usbController.validateDiff(from: usbMac, to: usbDiagChanged) {
        throw SelfTestFailure.failed("diag change was not rejected by validateDiff")
    }

    // adb changed -> reject.
    let usbAdbChanged = USBConfiguration(
        vendorID: 0x2C7C, productID: 0x0125,
        atEnabled: true, nmeaEnabled: true, diagEnabled: true,
        modemEnabled: true, reservedFlag: true, adbEnabled: false, uacEnabled: true
    )
    if case .success = usbController.validateDiff(from: usbMac, to: usbAdbChanged) {
        throw SelfTestFailure.failed("adb change was not rejected by validateDiff")
    }

    // VID changed -> reject.
    let usbVidChanged = USBConfiguration(
        vendorID: 0xFFFF, productID: 0x0125,
        atEnabled: true, nmeaEnabled: true, diagEnabled: true,
        modemEnabled: true, reservedFlag: true, adbEnabled: true, uacEnabled: true
    )
    if case .success = usbController.validateDiff(from: usbMac, to: usbVidChanged) {
        throw SelfTestFailure.failed("VID change was not rejected by validateDiff")
    }

    // PID changed -> reject.
    let usbPidChanged = USBConfiguration(
        vendorID: 0x2C7C, productID: 0x9999,
        atEnabled: true, nmeaEnabled: true, diagEnabled: true,
        modemEnabled: true, reservedFlag: true, adbEnabled: true, uacEnabled: true
    )
    if case .success = usbController.validateDiff(from: usbMac, to: usbPidChanged) {
        throw SelfTestFailure.failed("PID change was not rejected by validateDiff")
    }

    // Non-UAC flag changes in the model profile are never legal switchable states.
    let diagChangedConfig = ModemUSBConfiguration(
        vendorID: 0x2C7C, productID: 0x0125,
        diagnosticEnabled: false, nmeaEnabled: true, atPortEnabled: true,
        modemEnabled: true, networkEnabled: true, adbEnabled: true, audioEnabled: true
    )
    let adbChangedConfig = ModemUSBConfiguration(
        vendorID: 0x2C7C, productID: 0x0125,
        diagnosticEnabled: true, nmeaEnabled: true, atPortEnabled: true,
        modemEnabled: true, networkEnabled: true, adbEnabled: false, audioEnabled: true
    )
    let vidChangedConfig = ModemUSBConfiguration(
        vendorID: 0xFFFF, productID: 0x0125,
        diagnosticEnabled: true, nmeaEnabled: true, atPortEnabled: true,
        modemEnabled: true, networkEnabled: true, adbEnabled: true, audioEnabled: true
    )
    let pidChangedConfig = ModemUSBConfiguration(
        vendorID: 0x2C7C, productID: 0x9999,
        diagnosticEnabled: true, nmeaEnabled: true, atPortEnabled: true,
        modemEnabled: true, networkEnabled: true, adbEnabled: true, audioEnabled: true
    )
    try expect(diagChangedConfig.usbProfile == .unsupported, "diag=0 profile was not classified as unsupported")
    try expect(diagChangedConfig.knownSafe == false, "diag=0 profile reported as known-safe")
    try expect(adbChangedConfig.usbProfile == .unsupported, "adb=0 profile was not classified as unsupported")
    try expect(adbChangedConfig.knownSafe == false, "adb=0 profile reported as known-safe")
    try expect(vidChangedConfig.usbProfile == .unsupported, "VID change was not classified as unsupported")
    try expect(pidChangedConfig.usbProfile == .unsupported, "PID change was not classified as unsupported")
    try expect(vidChangedConfig.oneClickSwitchAllowed == false, "VID change allowed one-click switch")
    try expect(pidChangedConfig.oneClickSwitchAllowed == false, "PID change allowed one-click switch")

    // Invalid audio value (2) must not parse.
    let badAudio = "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1,2\r\nOK"
    try expect(
        ATResponseParser.parseUSBConfiguration(badAudio) == nil,
        "invalid audio value was parsed as a valid configuration"
    )

    print("USB mode manager tests passed (derive, only-UAC transform, round-trip, idempotent, unsupported, malformed).")
}


// MARK: - USB composition helpers & crash-recovery regression

do {
    // A scripted transport that returns a fixed USBCFG read while recording
    // the last command, so the crash-recovery path can be exercised offline.
    final class ScriptedTransport: USBModemTransport {
        var readOutput: (output: String, code: Int32) = ("", 0)
        var lastCommand = ""
        func execute(command: String, timeoutMS: Int) -> (output: String, code: Int32) {
            lastCommand = command
            if command == USBConfiguration.readCommand {
                return readOutput
            }
            return ("", 0)
        }
        func waitForReconnect(timeoutMS: Int) -> Bool { true }
        var isConnected: Bool { true }
    }

    let macLine = "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1,1\r\n"
    let mobileLine = "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1,0\r\n"
    let macConfig = try USBConfiguration.parse(response: macLine).get()
    let mobileConfig = try USBConfiguration.parse(response: mobileLine).get()

    // --- Composition helpers: protected-field identity and only-UAC diff ---

    // Same protected fields; only UAC differs -> legal switch.
    try expect(macConfig.hasSameProtectedFields(as: mobileConfig), "original vs mobile protected fields differ")
    try expect(macConfig.onlyUACChanged(from: mobileConfig), "original vs mobile not only-UAC")
    try expect(mobileConfig.onlyUACChanged(from: macConfig), "mobile vs original not only-UAC")

    // Identical compositions are NOT an only-UAC change (no UAC delta).
    try expect(!macConfig.onlyUACChanged(from: macConfig), "identical configs reported as only-UAC")
    try expect(!mobileConfig.onlyUACChanged(from: mobileConfig), "identical configs reported as only-UAC")

    // Modem hex formatting (0x125 vs 0x0125, lowercase) must not affect identity.
    let hexVariant = try USBConfiguration.parse(response: "+QCFG: \"usbcfg\",0x2c7c,0x125,1,1,1,1,1,1,1\r\n").get()
    try expect(macConfig == hexVariant, "hex formatting should not affect equality")
    try expect(macConfig.hasSameProtectedFields(as: hexVariant), "hex variant protected fields differ")
    try expect(hexVariant.onlyUACChanged(from: mobileConfig), "hex variant vs mobile should be only-UAC")

    // Protected-field changes break both hasSameProtectedFields and onlyUACChanged.
    let diagChanged = USBConfiguration(
        vendorID: 0x2C7C, productID: 0x0125,
        atEnabled: true, nmeaEnabled: true, diagEnabled: false,
        modemEnabled: true, reservedFlag: true, adbEnabled: true, uacEnabled: true
    )
    try expect(!diagChanged.hasSameProtectedFields(as: macConfig), "diag change not detected")
    try expect(!diagChanged.onlyUACChanged(from: macConfig), "diag change reported as only-UAC")

    let adbChanged = USBConfiguration(
        vendorID: 0x2C7C, productID: 0x0125,
        atEnabled: true, nmeaEnabled: true, diagEnabled: true,
        modemEnabled: true, reservedFlag: true, adbEnabled: false, uacEnabled: true
    )
    try expect(!adbChanged.hasSameProtectedFields(as: macConfig), "adb change not detected")
    try expect(!adbChanged.onlyUACChanged(from: macConfig), "adb change reported as only-UAC")

    let vidChanged = USBConfiguration(
        vendorID: 0xFFFF, productID: 0x0125,
        atEnabled: true, nmeaEnabled: true, diagEnabled: true,
        modemEnabled: true, reservedFlag: true, adbEnabled: true, uacEnabled: true
    )
    try expect(!vidChanged.hasSameProtectedFields(as: macConfig), "VID change not detected")
    try expect(!vidChanged.onlyUACChanged(from: macConfig), "VID change reported as only-UAC")

    let pidChanged = USBConfiguration(
        vendorID: 0x2C7C, productID: 0x9999,
        atEnabled: true, nmeaEnabled: true, diagEnabled: true,
        modemEnabled: true, reservedFlag: true, adbEnabled: true, uacEnabled: true
    )
    try expect(!pidChanged.hasSameProtectedFields(as: macConfig), "PID change not detected")

    // Malformed USBCFG must not parse (field-count mismatch).
    do {
        _ = try USBConfiguration.parse(response: "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,1,1\r\n").get()
        throw SelfTestFailure.failed("field-count mismatch was accepted")
    } catch USBConfiguration.USBConfigurationError.unsupportedFieldCount {
        // Expected
    }

    // --- Crash-recovery regression ---

    func makeBackup(original: USBConfiguration, target: USBConfiguration) -> USBConfigBackup {
        USBConfigBackup(
            original: USBConfigBackup.USBConfigSnapshot(original),
            targetMode: target.uacEnabled ? "mac" : "mobile",
            targetConfig: USBConfigBackup.USBConfigSnapshot(target),
            createdAt: Date(),
            writeStarted: true,
            verificationCompleted: false
        )
    }

    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("celldock-usb-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    // Scenario A — write did not take effect: current == original (audio=1).
    let transportRestored = ScriptedTransport()
    transportRestored.readOutput = (macLine, 0)
    let controllerRestored = USBModeController(transport: transportRestored, backupDirectory: tmpDir)
    try USBConfigBackupStore.save(makeBackup(original: macConfig, target: mobileConfig), to: tmpDir)
    try expect(
        controllerRestored.recoverUnfinishedTransition() == .restored,
        "crash recovery did not classify current==original as restored"
    )

    // Scenario B — write succeeded, verification was interrupted: current == desired (audio=0).
    let transportCompleted = ScriptedTransport()
    transportCompleted.readOutput = (mobileLine, 0)
    let controllerCompleted = USBModeController(transport: transportCompleted, backupDirectory: tmpDir)
    try USBConfigBackupStore.save(makeBackup(original: macConfig, target: mobileConfig), to: tmpDir)
    try expect(
        controllerCompleted.recoverUnfinishedTransition() == .completedRecovery,
        "crash recovery did not classify current==desired as completed"
    )

    // Scenario C — protected field changed (audio=0 but adb=0): genuine conflict.
    let conflictLine = "+QCFG: \"usbcfg\",0x2C7C,0x0125,1,1,1,1,0,1,0\r\n"
    let transportConflict = ScriptedTransport()
    transportConflict.readOutput = (conflictLine, 0)
    let controllerConflict = USBModeController(transport: transportConflict, backupDirectory: tmpDir)
    try USBConfigBackupStore.save(makeBackup(original: macConfig, target: mobileConfig), to: tmpDir)
    try expect(
        controllerConflict.recoverUnfinishedTransition() == .conflict,
        "crash recovery did not flag a protected-field conflict"
    )

    // Scenario D — hex-formatting tolerance: current reports 0x125 lowercase for
    // the original composition, which must still be classified as restored.
    let hexVariantLine = "+QCFG: \"usbcfg\",0x2c7c,0x125,1,1,1,1,1,1,1\r\n"
    let transportHex = ScriptedTransport()
    transportHex.readOutput = (hexVariantLine, 0)
    let controllerHex = USBModeController(transport: transportHex, backupDirectory: tmpDir)
    try USBConfigBackupStore.save(makeBackup(original: macConfig, target: mobileConfig), to: tmpDir)
    try expect(
        controllerHex.recoverUnfinishedTransition() == .restored,
        "crash recovery did not tolerate modem hex formatting"
    )

    print("USB composition & crash-recovery tests passed (hasSameProtectedFields, onlyUACChanged, recoverUnfinishedTransition).")
}

// MARK: - Connection / recovery engine regression matrix

do {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let supportedUSB = ModemUSBConfiguration.maVoTarget
    let mobileUSB = ModemUSBConfiguration(
        vendorID: 0x2C7C,
        productID: 0x0125,
        diagnosticEnabled: true,
        nmeaEnabled: true,
        atPortEnabled: true,
        modemEnabled: true,
        networkEnabled: true,
        adbEnabled: true,
        audioEnabled: false
    )

    func modem(
        state: ModemConnectionState = .connected,
        lifecycle: ModemLifecyclePhase = .normal,
        sim: SIMState = .ready,
        registration: CellularRegistrationState = .registered,
        usb: ModemUSBConfiguration? = supportedUSB
    ) -> ModemSnapshot {
        ModemSnapshot(
            state: state,
            lifecyclePhase: lifecycle,
            usbIdentity: state == .disconnected ? nil : "2C7C:0125",
            operatorName: "China Unicom",
            accessTechnology: "LTE",
            signalDBm: -92,
            simState: sim,
            registrationState: registration,
            usbNetMode: state == .connected ? 1 : nil,
            usbConfiguration: usb
        )
    }

    func activeNetwork(internet: Bool? = true) -> CellularNetworkStatus {
        CellularNetworkStatus(
            serviceID: "cellular-test",
            bsdName: "en7",
            isEnabled: true,
            isActive: true,
            isLinkActive: true,
            isHardwarePresent: true,
            ipv4Address: "192.168.225.25",
            ipv4Router: "192.168.225.1",
            internetReachable: internet
        )
    }

    func readyObservation(
        usb: ModemUSBConfiguration = supportedUSB,
        internet: Bool? = true
    ) -> ModemConnectionObservation {
        ModemConnectionObservation(
            usbDetected: true,
            modem: modem(usb: usb),
            network: activeNetwork(internet: internet),
            internetReachable: internet
        )
    }

    // Test 1 — Cold Plug.
    var coldPlug = ModemConnectionStateMachine()
    try expect(
        coldPlug.observe(ModemConnectionObservation(
            usbDetected: false,
            modem: ModemSnapshot()
        ), now: base).stage == .disconnected,
        "Cold Plug did not start disconnected"
    )
    _ = coldPlug.beginRecovery(trigger: .coldPlug, now: base)
    try expect(
        coldPlug.observe(ModemConnectionObservation(
            usbDetected: true,
            modem: ModemSnapshot()
        ), now: base.addingTimeInterval(1)).stage == .waitingForAT,
        "Cold Plug did not wait for delayed AT"
    )
    try expect(
        coldPlug.observe(ModemConnectionObservation(
            usbDetected: true,
            modem: modem(registration: .searching),
            network: CellularNetworkStatus()
        ), now: base.addingTimeInterval(4)).stage == .registeringNetwork,
        "Cold Plug skipped the registration wait"
    )
    try expect(
        coldPlug.observe(readyObservation(), now: base.addingTimeInterval(10)).stage == .connected,
        "Cold Plug did not reach connected"
    )

    // Test 2 — AT Delayed with bounded retries.
    var atDelayed = ModemConnectionStateMachine()
    let atSession = atDelayed.beginRecovery(trigger: .coldPlug, now: base)
    for attempt in 0 ..< 4 {
        let state = atDelayed.observe(ModemConnectionObservation(
            usbDetected: true,
            modem: modem(state: .connecting, sim: .initializing, registration: .unavailable)
        ), now: base.addingTimeInterval(Double(attempt)))
        try expect(state.stage == .waitingForAT, "AT delay became a terminal failure too early")
        atDelayed.recordRecoveryAttempt(level: .refresh)
    }
    try expect(atDelayed.isCurrentSession(atSession), "AT delayed session was replaced")
    try expect(
        atDelayed.observe(readyObservation(), now: base.addingTimeInterval(8)).stage == .connected,
        "AT delayed recovery did not succeed"
    )

    // Test 3 — SIM Missing must not collapse into network failure.
    var simMissing = ModemConnectionStateMachine()
    let simMissingStatus = simMissing.observe(ModemConnectionObservation(
        usbDetected: true,
        modem: modem(sim: .absent, registration: .unavailable),
        network: CellularNetworkStatus()
    ), now: base)
    try expect(
        simMissingStatus.stage == .failed && simMissingStatus.failure == .simMissing,
        "SIM Missing was not classified independently"
    )

    // Test 4 — Registration Delay.
    var registrationDelay = ModemConnectionStateMachine()
    for offset in [0.0, 30.0, 60.0] {
        let state = registrationDelay.observe(ModemConnectionObservation(
            usbDetected: true,
            modem: modem(registration: .searching),
            network: CellularNetworkStatus()
        ), now: base.addingTimeInterval(offset))
        try expect(state.stage == .registeringNetwork, "Searching registration failed too early")
    }
    try expect(
        registrationDelay.observe(
            readyObservation(),
            now: base.addingTimeInterval(70)
        ).stage == .connected,
        "Registration delay did not recover"
    )

    // Test 5 — USB Disconnect / Reconnect.
    var reconnect = ModemConnectionStateMachine()
    _ = reconnect.beginRecovery(trigger: .coldPlug, now: base)
    _ = reconnect.observe(readyObservation(), now: base.addingTimeInterval(1))
    let disconnected = reconnect.observe(ModemConnectionObservation(
        usbDetected: false,
        modem: ModemSnapshot()
    ), now: base.addingTimeInterval(2))
    try expect(
        disconnected.stage == .waitingForModuleReboot,
        "connected USB loss was treated as an immediate fatal error"
    )
    _ = reconnect.beginRecovery(trigger: .usbReconnect, now: base.addingTimeInterval(3))
    _ = reconnect.observe(ModemConnectionObservation(
        usbDetected: true,
        modem: modem(state: .connecting, sim: .initializing, registration: .unavailable)
    ), now: base.addingTimeInterval(4))
    try expect(
        reconnect.observe(readyObservation(), now: base.addingTimeInterval(9)).stage == .connected,
        "USB reconnect did not return to connected"
    )

    // Test 6 — Module Reboot.
    var reboot = ModemConnectionStateMachine()
    _ = reboot.beginRecovery(trigger: .coldPlug, now: base)
    _ = reboot.observe(readyObservation(), now: base.addingTimeInterval(1))
    reboot.markDisconnected(now: base.addingTimeInterval(2), expectedReboot: true)
    try expect(
        reboot.status.stage == .waitingForModuleReboot && reboot.status.isRecovering,
        "module reboot did not enter its grace state"
    )
    _ = reboot.observe(ModemConnectionObservation(
        usbDetected: true,
        modem: modem(
            state: .connecting,
            lifecycle: .reconnecting,
            sim: .initializing,
            registration: .unavailable
        )
    ), now: base.addingTimeInterval(5))
    try expect(
        reboot.observe(readyObservation(), now: base.addingTimeInterval(10)).stage == .connected,
        "module reboot did not reconnect"
    )

    // Test 7 — Sleep / Wake.
    var sleepWake = ModemConnectionStateMachine()
    _ = sleepWake.beginRecovery(trigger: .coldPlug, now: base)
    _ = sleepWake.observe(readyObservation(), now: base.addingTimeInterval(1))
    sleepWake.markSleep(now: base.addingTimeInterval(2))
    try expect(
        sleepWake.observe(ModemConnectionObservation(
            usbDetected: false,
            modem: ModemSnapshot()
        ), now: base.addingTimeInterval(3)).stage == .waitingForEnumeration,
        "sleep USB loss was treated as permanent"
    )
    _ = sleepWake.markWake(now: base.addingTimeInterval(4))
    try expect(
        sleepWake.observe(readyObservation(), now: base.addingTimeInterval(11)).stage == .connected &&
            sleepWake.status.recoveredAfterWake,
        "wake recovery did not complete"
    )

    // Test 8 — Concurrent recovery triggers coalesce into one session.
    var concurrent = ModemConnectionStateMachine()
    let wakeSession = concurrent.beginRecovery(trigger: .systemWake, now: base)
    let usbSession = concurrent.beginRecovery(trigger: .usbReconnect, now: base)
    let healthSession = concurrent.beginRecovery(trigger: .healthCheckFailure, now: base)
    try expect(
        wakeSession == usbSession && usbSession == healthSession &&
            concurrent.status.coalescedTriggers == 2,
        "concurrent recovery created more than one active session"
    )

    // Test 9 — Recovery may read USBCFG but must never mutate it.
    let originalUSBConfiguration = mobileUSB
    try expect(
        ModemRecoveryPolicy.automaticATCommands.allSatisfy {
            !ModemRecoveryPolicy.changesPersistentConfiguration($0)
        },
        "automatic recovery contains a persistent AT command"
    )
    try expect(
        !ModemRecoveryPolicy.actions(for: .refresh).contains(.requestUserConfiguration) &&
            !ModemRecoveryPolicy.actions(for: .softRecover).contains(.requestUserConfiguration),
        "automatic recovery crossed into persistent user-action policy"
    )
    var preservation = ModemConnectionStateMachine()
    _ = preservation.beginRecovery(trigger: .usbReconnect, now: base)
    try expect(
        preservation.observe(
            readyObservation(usb: originalUSBConfiguration),
            now: base.addingTimeInterval(8)
        ).stage == .connected &&
            originalUSBConfiguration == mobileUSB,
        "USB configuration changed during recovery"
    )

    let sensitiveModem = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        operatorName: "China Unicom",
        accessTechnology: "LTE",
        signalDBm: -92,
        simState: .ready,
        registrationState: .registered,
        simPhoneNumber: "13800138000",
        simICCID: "89860312345678901234",
        simIMSI: "460011234567890",
        moduleIMEI: "867530900000001",
        usbNetMode: 1,
        usbConfiguration: supportedUSB
    )
    let diagnostics = ModemConnectionDiagnosticsReport.make(
        status: preservation.status,
        modem: sensitiveModem,
        network: activeNetwork(),
        appVersion: "test",
        timestamp: base
    )
    try expect(
        !diagnostics.contains("13800138000") &&
            !diagnostics.contains("89860312345678901234") &&
            !diagnostics.contains("460011234567890") &&
            !diagnostics.contains("867530900000001"),
        "connection diagnostics exposed SIM or device identity"
    )

    print("Connection recovery tests passed (cold plug, delayed AT/registration, SIM, reconnect, reboot, wake, concurrency, USB preservation, diagnostics).")
}

// MARK: - SMSManager regression tests

do {
    let manager = SMSManager()

    // Build helper SMSMessage instances.
    let firstSMS = SMSMessage(
        id: "sms-a",
        modemIndices: [],
        sender: "10086",
        body: "您的验证码为 123456",
        timestamp: Date(timeIntervalSince1970: 1_700_002_000),
        rawPDUs: [],
        isRead: false,
        firstSeenAt: Date(timeIntervalSince1970: 1_700_002_000)
    )
    let secondSMS = SMSMessage(
        id: "sms-b",
        modemIndices: [],
        sender: "BANK",
        body: "订单号 482913 已发货",
        timestamp: Date(timeIntervalSince1970: 1_700_002_100),
        rawPDUs: [],
        isRead: false,
        firstSeenAt: Date(timeIntervalSince1970: 1_700_002_100)
    )

    // 1. Single message appears once.
    let firstMirrors = manager.ingest([firstSMS])
    try expect(firstMirrors.count == 1, "first SMS was not mirrored")
    try expect(manager.messages.count == 1, "SMSManager did not retain the first message")
    try expect(manager.messages.first?.sender == "10086", "SMSManager lost the sender")

    // 2. Duplicate ingest does not duplicate.
    let secondRound = manager.ingest([firstSMS])
    try expect(secondRound.isEmpty, "duplicate SMS was re-emitted by SMSManager")
    try expect(manager.messages.count == 1, "duplicate SMS was re-stored by SMSManager")

    // 3. Different message is appended.
    let thirdRound = manager.ingest([secondSMS])
    try expect(thirdRound.count == 1, "second SMS was not mirrored")
    try expect(manager.messages.count == 2, "second SMS was not retained")
    try expect(manager.messages.first?.sender == "BANK", "newest message should be first")

    // 4. Multipart: once assembled by the PDU pipeline, the merged message
    // enters SMSManager exactly once with the assembled body.
    let assembledMultipart = SMSMessage(
        id: "multipart-1",
        modemIndices: [1, 2],
        sender: "10086",
        body: "验证码为 123456",
        timestamp: Date(timeIntervalSince1970: 1_700_003_000),
        rawPDUs: [],
        isRead: false,
        firstSeenAt: Date(timeIntervalSince1970: 1_700_003_000)
    )
    let multipartRound = manager.ingest([assembledMultipart, assembledMultipart])
    try expect(multipartRound.count == 1, "assembled multipart SMS entered SMSManager more than once")
    try expect(manager.messages.first?.body == "验证码为 123456", "multipart body was not the assembled text")

    // 5. History limit of 100.
    let bulkManager = SMSManager()
    var bulk: [SMSMessage] = []
    for i in 0..<150 {
        bulk.append(SMSMessage(
            id: "bulk-\(i)",
            modemIndices: [],
            sender: "Sender \(i)",
            body: "Body \(i)",
            timestamp: Date(timeIntervalSince1970: 1_700_004_000 + TimeInterval(i)),
            rawPDUs: [],
            isRead: false,
            firstSeenAt: Date(timeIntervalSince1970: 1_700_004_000 + TimeInterval(i))
        ))
    }
    _ = bulkManager.ingest(bulk)
    try expect(
        bulkManager.messages.count == SMSManager.historyLimit,
        "SMSManager exceeded history limit"
    )
    try expect(
        bulkManager.messages.first?.body == "Body 149",
        "SMSManager did not keep the newest message after truncation"
    )

    // 7. replaceMessages() replaces the list and resets dedup state.
    manager.clear()
    try expect(manager.messages.isEmpty, "clear() did not empty SMSManager")
    let afterClear = manager.ingest([firstSMS])
    try expect(afterClear.count == 1, "message was not re-accepted after clear")

    // 7. replaceMessages() replaces the list and resets dedup state.
    let replacement = ModemSMSMessage(
        sender: "NEW",
        timestamp: Date(timeIntervalSince1970: 1_700_005_000),
        body: "replacement",
        receivedAt: Date(timeIntervalSince1970: 1_700_005_000)
    )
    manager.replaceMessages([replacement])
    try expect(manager.messages.count == 1, "replaceMessages did not set the list")
    try expect(manager.messages.first?.body == "replacement", "replaceMessages wrong content")
    let afterReplace = manager.ingest([firstSMS])
    try expect(afterReplace.count == 1, "replaceMessages did not reset dedup state")

    print("SMSManager tests passed (ingest, dedup, multipart, limit, clear, replace).")
}
