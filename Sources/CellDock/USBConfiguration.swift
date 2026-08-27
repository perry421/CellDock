import Foundation

/// Structured representation of a Quectel EG25-G `AT+QCFG="usbcfg"` response.
///
/// Real-world response example (DJOneHub v1.2.4 capture):
///   +QCFG: "usbcfg",0x2CA3,0x4006,1,1,1,1,1,0,0
///
/// Field layout (9 comma-separated values after the quoted key):
///   [0] Vendor ID   (hex, e.g. 0x2CA3 = DJI, 0x2C7C = Quectel)
///   [1] Product ID  (hex, e.g. 0x4006, 0x0125)
///   [2] AT interface   (0 or 1)
///   [3] NMEA interface (0 or 1)
///   [4] DIAG interface (0 or 1)
///   [5] Modem/RMNET    (0 or 1)
///   [6] Reserved       (0 or 1) — always 1 in all observed configs
///   [7] ADB interface  (0 or 1)
///   [8] UAC interface  (0 or 1) — USB Audio Class, the only field we modify
struct USBConfiguration: Equatable, Sendable {
    let vendorID: UInt16
    let productID: UInt16
    var atEnabled: Bool
    var nmeaEnabled: Bool
    var diagEnabled: Bool
    var modemEnabled: Bool
    var reservedFlag: Bool
    var adbEnabled: Bool
    var uacEnabled: Bool

    /// Nine raw string fields preserving exact modem values (hex VID/PID, "0"/"1").
    private var rawFields: [String]

    /// Strip optional 0x/0X prefix so UInt16(_:radix:16) accepts modem output.
    private static func hexStr(_ s: String) -> String {
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return String(s.dropFirst(2)) }
        return s
    }

    private init(rawFields: [String]) {
        self.rawFields = rawFields
        self.vendorID = UInt16(USBConfiguration.hexStr(rawFields[0]), radix: 16) ?? 0
        self.productID = UInt16(USBConfiguration.hexStr(rawFields[1]), radix: 16) ?? 0
        self.atEnabled = rawFields[2] == "1"
        self.nmeaEnabled = rawFields[3] == "1"
        self.diagEnabled = rawFields[4] == "1"
        self.modemEnabled = rawFields[5] == "1"
        self.reservedFlag = rawFields[6] == "1"
        self.adbEnabled = rawFields[7] == "1"
        self.uacEnabled = rawFields[8] == "1"
    }

    /// Internal initializer for constructing configs directly (tests, controller).
    /// Only constructs from validated typed values; raw fields are derived.
    internal init(
        vendorID: UInt16, productID: UInt16,
        atEnabled: Bool, nmeaEnabled: Bool, diagEnabled: Bool,
        modemEnabled: Bool, reservedFlag: Bool, adbEnabled: Bool, uacEnabled: Bool
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.atEnabled = atEnabled
        self.nmeaEnabled = nmeaEnabled
        self.diagEnabled = diagEnabled
        self.modemEnabled = modemEnabled
        self.reservedFlag = reservedFlag
        self.adbEnabled = adbEnabled
        self.uacEnabled = uacEnabled
        self.rawFields = [
            String(format: "0x%04X", vendorID),
            String(format: "0x%04X", productID),
            atEnabled ? "1" : "0",
            nmeaEnabled ? "1" : "0",
            diagEnabled ? "1" : "0",
            modemEnabled ? "1" : "0",
            reservedFlag ? "1" : "0",
            adbEnabled ? "1" : "0",
            uacEnabled ? "1" : "0"
        ]
    }

    // MARK: - Serialization

    /// AT command string that writes this configuration back to the modem.
    /// Format: `AT+QCFG="usbcfg",0xVVVV,0xPPPP,F1,F2,...,F8`
    var writeCommand: String {
        let fields = [
            String(format: "0x%04X", vendorID),
            String(format: "0x%04X", productID),
            atEnabled ? "1" : "0",
            nmeaEnabled ? "1" : "0",
            diagEnabled ? "1" : "0",
            modemEnabled ? "1" : "0",
            reservedFlag ? "1" : "0",
            adbEnabled ? "1" : "0",
            uacEnabled ? "1" : "0"
        ]
        return "AT+QCFG=\"usbcfg\"," + fields.joined(separator: ",")
    }

    /// Read command to query current configuration.
    static let readCommand = "AT+QCFG=\"usbcfg\""

    // MARK: - Comparing composition layouts

    /// Two configurations are equal only when every typed composition field —
    /// VID, PID, and all eight interface flags including UAC — is identical.
    ///
    /// The comparison deliberately ignores `rawFields`, so a live modem reply
    /// that hex-formats VID/PID differently (e.g. `0x125` instead of `0x0125`,
    /// or lowercase hex) is still recognised as the *same* composition. The raw
    /// text is preserved for exact AT replay but never participates in identity.
    static func == (lhs: USBConfiguration, rhs: USBConfiguration) -> Bool {
        lhs.vendorID == rhs.vendorID &&
        lhs.productID == rhs.productID &&
        lhs.atEnabled == rhs.atEnabled &&
        lhs.nmeaEnabled == rhs.nmeaEnabled &&
        lhs.diagEnabled == rhs.diagEnabled &&
        lhs.modemEnabled == rhs.modemEnabled &&
        lhs.reservedFlag == rhs.reservedFlag &&
        lhs.adbEnabled == rhs.adbEnabled &&
        lhs.uacEnabled == rhs.uacEnabled
    }

    /// All protected (non-UAC) composition fields — VID, PID and the six
    /// interface flags — are identical between `self` and `other`.
    ///
    /// This is the invariant a CellDock Mac ↔ Mobile switch must preserve: the
    /// only field allowed to be a free variable is UAC/audio. The comparison is
    /// on the typed fields, so modem hex formatting of VID/PID is irrelevant.
    func hasSameProtectedFields(as other: USBConfiguration) -> Bool {
        vendorID == other.vendorID &&
        productID == other.productID &&
        atEnabled == other.atEnabled &&
        nmeaEnabled == other.nmeaEnabled &&
        diagEnabled == other.diagEnabled &&
        modemEnabled == other.modemEnabled &&
        reservedFlag == other.reservedFlag &&
        adbEnabled == other.adbEnabled
    }

    /// `self` and `other` describe two states of the same legal composition that
    /// differ only in the UAC/audio flag.
    ///
    /// Returns `false` when the configurations are fully identical (no UAC
    /// change) or when any protected field differs. This is the single
    /// transformation the USB mode switch is permitted to apply.
    func onlyUACChanged(from other: USBConfiguration) -> Bool {
        hasSameProtectedFields(as: other) && uacEnabled != other.uacEnabled
    }

    // MARK: - Parsing

    enum USBConfigurationError: LocalizedError, Equatable {
        case emptyResponse
        case missingUSBCFGPrefix
        case unsupportedFieldCount(Int)
        case emptyField(index: Int)
        case invalidHexField(field: String, expected: String)
        case invalidBinaryField(field: String, index: Int)

        var errorDescription: String? {
            switch self {
            case .emptyResponse:
                return "modem returned an empty response"
            case .missingUSBCFGPrefix:
                return "response does not contain a +QCFG: \"usbcfg\" line"
            case .unsupportedFieldCount(let count):
                return "expected 9 fields, got \(count)"
            case .emptyField(let index):
                return "field \(index) is empty"
            case .invalidHexField(let field, let expected):
                return "\(expected) field '\(field)' is not valid hex"
            case .invalidBinaryField(let field, let index):
                return "field \(index) '\(field)' is not 0 or 1"
            }
        }
    }

    /// Parse a raw AT response string into a structured configuration.
    ///
    /// Handles: AT echo, CRLF, OK trailing, whitespace, extra lines.
    /// Returns `.failure` for any malformed input — never falls back to defaults.
    static func parse(response: String) -> Result<USBConfiguration, USBConfigurationError> {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyResponse)
        }

        // Extract the +QCFG: "usbcfg",<fields> line (case-insensitive).
        let lines = trimmed.components(separatedBy: .newlines)
        var usbcfgLine: String?
        for line in lines {
            let upper = line.uppercased().trimmingCharacters(in: .whitespaces)
            if upper.contains("+QCFG:") && upper.contains("\"USBCFG\"") {
                usbcfgLine = line
                break
            }
        }
        guard let rawLine = usbcfgLine else {
            return .failure(.missingUSBCFGPrefix)
        }

        // Split on the first comma after the closing quote.
        guard let quoteEnd = rawLine.range(of: "\"usbcfg\"", options: .caseInsensitive)?.upperBound
                ?? rawLine.range(of: "\"USBCFG\"")?.upperBound else {
            return .failure(.missingUSBCFGPrefix)
        }
        let afterQuote = rawLine[quoteEnd...]
        guard let commaIdx = afterQuote.firstIndex(of: ",") else {
            return .failure(.missingUSBCFGPrefix)
        }
        let fieldsString = afterQuote[afterQuote.index(after: commaIdx)...]
            .trimmingCharacters(in: .whitespaces)

        let fields = fieldsString
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard fields.count == 9 else {
            return .failure(.unsupportedFieldCount(fields.count))
        }

        for (i, field) in fields.enumerated() {
            if field.isEmpty {
                return .failure(.emptyField(index: i))
            }
        }

        // Validate VID/PID are valid hex.
        guard UInt16(USBConfiguration.hexStr(fields[0]), radix: 16) != nil else {
            return .failure(.invalidHexField(field: fields[0], expected: "vendor ID"))
        }
        guard UInt16(USBConfiguration.hexStr(fields[1]), radix: 16) != nil else {
            return .failure(.invalidHexField(field: fields[1], expected: "product ID"))
        }

        // Validate binary fields [2]..[8].
        for i in 2..<9 {
            guard fields[i] == "0" || fields[i] == "1" else {
                return .failure(.invalidBinaryField(field: fields[i], index: i))
            }
        }

        return .success(USBConfiguration(rawFields: fields))
    }
}
