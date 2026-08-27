import Foundation

/// Presentation-layer vocabulary for the DJI 4G module status panel.
///
/// This is a *pure* derivation over the existing module state model
/// (`ModemSnapshot` → `operationalState`, `usbConfiguration` →
/// `USBConfigurationProfile` / `usbConnectionMode`). It issues no AT commands,
/// reads nothing, and performs no I/O — so the exact same mapping is shared by
/// the settings UI and the self-tests. The UI never re-derives USB state on its
/// own; the single source of truth stays in `Models.swift` / `ModemService`.
struct ModemModuleStatusPresentation: Equatable, Sendable {
    /// The high-level, user-visible module state. Explicitly decoupled from any
    /// optional feature (VoWiFi, Voice Test): those must never downgrade the
    /// module's own readiness.
    enum Status: Equatable, Sendable {
        case disconnected
        case detecting
        case initializing
        case ready
        case configurationRequired
        case error
    }

    /// USB-composition validity, derived only from the already-canonical
    /// `USBConfigurationProfile`. `valid` covers both DJI-original (audio=1) and
    /// CellDock-compatible (audio=0).
    enum Configuration: Equatable, Sendable {
        case valid
        case needsRepair(RepairIssue)
    }

    /// A concrete, single reason why a composition is not usable. Never a vague
    /// "DJI 配置未通过校验" — the UI prints precisely which interface is off.
    enum RepairIssue: Equatable, Sendable {
        case diagDisabled
        case nmeaDisabled
        case atDisabled
        case modemDisabled
        case networkDisabled
        case adbDisabled
        case unsupportedIdentity(String)
        case malformed
    }

    enum Interface: Equatable, Sendable {
        case available
        case unavailable
        case notApplicable
    }

    /// `USBConfigurationProfile` mapped 1:1; kept here so the UI never switches
    /// on the model enum and re-spells its meaning.
    enum Profile: Equatable, Sendable {
        case djiOriginal
        case cellDockCompatible
        case unsupported
    }

    enum Audio: Equatable, Sendable {
        case enabled
        case disabled
        case notApplicable
    }

    enum USBMode: Equatable, Sendable {
        case mac
        case mobile
        case unknown
    }

    let status: Status
    let profile: Profile
    let configuration: Configuration
    let at: Interface
    let network: Interface
    let adb: Interface
    let audio: Audio
    let usbMode: USBMode

    /// Derive the panel contents from a live module snapshot.
    static func derive(snapshot: ModemSnapshot) -> Self {
        let status = status(for: snapshot.operationalState)
        let profile = profile(for: snapshot.usbConfiguration)
        let configuration = configuration(for: snapshot.usbConfiguration)
        let at = interface(for: snapshot.usbConfiguration?.atPortEnabled)
        let network = interface(for: snapshot.usbConfiguration?.networkEnabled)
        let adb = interface(for: snapshot.usbConfiguration?.adbEnabled)
        let audio = audio(for: snapshot.usbConfiguration, profile: profile)
        let usbMode = usbMode(for: snapshot.usbConfiguration, profile: profile)
        return Self(
            status: status,
            profile: profile,
            configuration: configuration,
            at: at,
            network: network,
            adb: adb,
            audio: audio,
            usbMode: usbMode
        )
    }

    // MARK: - Pure translators

    private static func status(for operational: ModemOperationalState) -> Status {
        switch operational {
        case .absent: return .disconnected
        case .enumerating: return .detecting
        case .initializing: return .initializing
        case .ready: return .ready
        case .configurationRequired: return .configurationRequired
        case .failed: return .error
        case .restarting, .reconnecting: return .initializing
        }
    }

    private static func profile(for configuration: ModemUSBConfiguration?) -> Profile {
        switch configuration?.usbProfile {
        case .djiOriginal: return .djiOriginal
        case .cellDockCompatible: return .cellDockCompatible
        case .unsupported, nil: return .unsupported
        }
    }

    private static func configuration(
        for configuration: ModemUSBConfiguration?
    ) -> Configuration {
        guard let configuration else { return .needsRepair(.malformed) }
        switch configuration.usbProfile {
        case .djiOriginal, .cellDockCompatible:
            return .valid
        case .unsupported:
            return .needsRepair(repairIssue(for: configuration))
        }
    }

    private static func repairIssue(for configuration: ModemUSBConfiguration) -> RepairIssue {
        // Report the first disabling issue with a stable precedence so the UI is
        // consistent across refreshes: diag → nmea → at → modem → net → adb,
        // then identity.
        if !configuration.diagnosticEnabled { return .diagDisabled }
        if !configuration.nmeaEnabled { return .nmeaDisabled }
        if !configuration.atPortEnabled { return .atDisabled }
        if !configuration.modemEnabled { return .modemDisabled }
        if !configuration.networkEnabled { return .networkDisabled }
        if !configuration.adbEnabled { return .adbDisabled }
        return .unsupportedIdentity(configuration.identity)
    }

    private static func interface(for enabled: Bool?) -> Interface {
        guard let enabled else { return .notApplicable }
        return enabled ? .available : .unavailable
    }

    private static func audio(for configuration: ModemUSBConfiguration?, profile: Profile) -> Audio {
        guard let configuration, profile != .unsupported else { return .notApplicable }
        return configuration.audioEnabled ? .enabled : .disabled
    }

    private static func usbMode(for configuration: ModemUSBConfiguration?, profile: Profile) -> USBMode {
        guard let configuration, profile != .unsupported else { return .unknown }
        switch configuration.usbConnectionMode {
        case .mac: return .mac
        case .mobile: return .mobile
        }
    }
}
