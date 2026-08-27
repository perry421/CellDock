import Foundation
import os

// MARK: - Transport Protocol

/// Abstracts modem read/write/reconnect for testability.
///
/// Production implementation wraps ModemService's existing AT channel.
/// Mock implementation returns scripted responses for offline tests.
protocol USBModemTransport: AnyObject {
    /// Send an AT command and return (output, errorCode).
    /// code == 0 means success.
    func execute(command: String, timeoutMS: Int) -> (output: String, code: Int32)

    /// Wait for the modem to re-enumerate after a USBCFG write.
    /// Returns true if the modem is reachable again within timeout.
    func waitForReconnect(timeoutMS: Int) -> Bool

    /// Whether the transport is currently connected.
    var isConnected: Bool { get }
}

// MARK: - Production Transport

/// Wraps the existing ModemService AT channel.
/// Does NOT create any new serial port, USB handle, or DispatchQueue.
final class ModemServiceTransport: USBModemTransport {
    private let executor: (_ command: String, _ timeoutMS: Int) -> (output: String, code: Int32)
    private let reconnectBlock: (_ timeoutMS: Int) -> Bool
    private let connectedCheck: () -> Bool

    init(
        executor: @escaping (_ command: String, _ timeoutMS: Int) -> (output: String, code: Int32),
        reconnect: @escaping (_ timeoutMS: Int) -> Bool = { _ in true },
        isConnected: @escaping () -> Bool = { true }
    ) {
        self.executor = executor
        self.reconnectBlock = reconnect
        self.connectedCheck = isConnected
    }

    func execute(command: String, timeoutMS: Int) -> (output: String, code: Int32) {
        executor(command, timeoutMS)
    }

    func waitForReconnect(timeoutMS: Int) -> Bool {
        reconnectBlock(timeoutMS)
    }

    var isConnected: Bool { connectedCheck() }
}

// MARK: - Transition State

enum USBModeTransitionState: Equatable, Sendable {
    case idle
    case reading
    case validating
    case backingUp
    case writing
    case waitingForReenumeration
    case reconnecting
    case verifying
    case rollingBack
    case completed
    case failed(String)
}

// MARK: - Errors

enum USBTransitionError: LocalizedError, Equatable {
    case readFailed
    case parseFailed(String)
    case validationFailed(String)
    case noOpNeeded
    case backupFailed(String)
    case writeFailed(Int32)
    case reenumerationTimeout
    case reconnectFailed
    case readbackFailed
    case readbackMismatch(expected: String, actual: String)
    case rollbackFailed(String)
    case rollbackVerificationFailed

    var errorDescription: String? {
        switch self {
        case .readFailed: return "failed to read current USBCFG"
        case .parseFailed(let m): return "parse failed: \(m)"
        case .validationFailed(let m): return "validation failed: \(m)"
        case .noOpNeeded: return "already in target mode"
        case .backupFailed(let m): return "backup failed: \(m)"
        case .writeFailed(let c): return "modem write returned error code \(c)"
        case .reenumerationTimeout: return "USB re-enumeration timed out"
        case .reconnectFailed: return "failed to reconnect to modem"
        case .readbackFailed: return "failed to read back USBCFG after write"
        case .readbackMismatch(let e, let a): return "readback mismatch: expected \(e), got \(a)"
        case .rollbackFailed(let m): return "rollback failed: \(m)"
        case .rollbackVerificationFailed: return "rollback verification failed"
        }
    }
}

// MARK: - USBModeController

/// Controls reading, transforming, writing, and rolling back the module's USB composition.
///
/// Phase 2 adds:
/// - Full transition flow: read → validate → backup → write → re-enumerate → reconnect → verify
/// - Persistent emergency backup for crash recovery
/// - Rollback on verification failure
///
/// All modem access goes through `USBModemTransport` — never directly through CModemBridge.
final class USBModeController: @unchecked Sendable {

    private static let log = Logger(subsystem: "app.celldock.mac", category: "USBMode")

    // MARK: - Dependencies

    typealias ATCommandExecutor = (_ command: String, _ timeoutMS: Int) -> (output: String, code: Int32)

    private let transport: USBModemTransport

    // MARK: - State

    private(set) var transitionState: USBModeTransitionState = .idle
    private var cachedConfiguration: USBConfiguration?

    // Backup store — injected for testing, defaults to disk.
    private let backupDirectory: URL?

    // MARK: - Init

    /// Production init: inject the executor closure from ModemService.
    /// Wraps it in a ModemServiceTransport automatically.
    convenience init(executor: @escaping ATCommandExecutor) {
        self.init(transport: ModemServiceTransport(executor: executor))
    }

    /// Init with explicit transport (for testing with mocks).
    init(transport: USBModemTransport, backupDirectory: URL? = nil) {
        self.transport = transport
        self.backupDirectory = backupDirectory
    }

    // MARK: - Read

    /// Read the current USB configuration from the modem.
    func readConfiguration(timeoutMS: Int = 5000) -> USBConfiguration? {
        let result = transport.execute(command: USBConfiguration.readCommand, timeoutMS: timeoutMS)
        guard result.code == 0 else { return nil }
        switch USBConfiguration.parse(response: result.output) {
        case .success(let config):
            cachedConfiguration = config
            return config
        case .failure:
            return nil
        }
    }

    var lastKnownConfiguration: USBConfiguration? { cachedConfiguration }

    // MARK: - Transform

    func configuration(
        from current: USBConfiguration,
        for mode: USBConnectionMode
    ) -> USBConfiguration? {
        let targetUAC: Bool
        switch mode {
        case .mac:    targetUAC = true
        case .mobile: targetUAC = false
        }
        guard current.uacEnabled != targetUAC else { return nil }
        return USBConfiguration(
            vendorID: current.vendorID, productID: current.productID,
            atEnabled: current.atEnabled, nmeaEnabled: current.nmeaEnabled,
            diagEnabled: current.diagEnabled, modemEnabled: current.modemEnabled,
            reservedFlag: current.reservedFlag, adbEnabled: current.adbEnabled,
            uacEnabled: targetUAC
        )
    }

    // MARK: - Validation

    @discardableResult
    func validateDiff(from original: USBConfiguration, to target: USBConfiguration) -> Result<String, USBValidationError> {
        if original.vendorID != target.vendorID { return .failure(.unexpectedFieldChange("VendorID")) }
        if original.productID != target.productID { return .failure(.unexpectedFieldChange("ProductID")) }
        if original.atEnabled != target.atEnabled { return .failure(.unexpectedFieldChange("AT interface")) }
        if original.nmeaEnabled != target.nmeaEnabled { return .failure(.unexpectedFieldChange("NMEA interface")) }
        if original.diagEnabled != target.diagEnabled { return .failure(.unexpectedFieldChange("DIAG interface")) }
        if original.modemEnabled != target.modemEnabled { return .failure(.unexpectedFieldChange("Modem/RMNET")) }
        if original.reservedFlag != target.reservedFlag { return .failure(.unexpectedFieldChange("Reserved flag")) }
        if original.adbEnabled != target.adbEnabled { return .failure(.unexpectedFieldChange("ADB interface")) }
        guard original.uacEnabled != target.uacEnabled else { return .failure(.noDifference) }
        return .success("UAC: \(original.uacEnabled) -> \(target.uacEnabled)")
    }

    // MARK: - Full Transition Flow

    /// Execute a complete USB mode transition: read → validate → backup → write → re-enumerate → verify.
    ///
    /// On verification failure, automatically attempts rollback using the backed-up original.
    /// Returns the final state; check `transitionState` for details.
    @discardableResult
    func transitionUSBMode(to targetMode: USBConnectionMode) -> USBModeTransitionState {
        Self.log.info("Starting transition to \(targetMode.rawValue, privacy: .public)")

        // Step 1 — Read
        setState(.reading)
        guard let current = readConfiguration() else {
            return fail(.readFailed)
        }
        Self.log.info("Read current config: VID=0x\(String(current.vendorID, radix: 16, uppercase: true), privacy: .public)")

        // Step 2 — Validate
        setState(.validating)
        if let desired = configuration(from: current, for: targetMode) {
            let diffResult = validateDiff(from: current, to: desired)
            if case .failure(let err) = diffResult {
                return fail(.validationFailed(err.localizedDescription))
            }
            // Verify round-trip: serialize → parse must reproduce identical config.
            guard let reparsed = parseWriteCommand(desired) else {
                return fail(.validationFailed("round-trip serialize→parse failed"))
            }
            guard reparsed == desired else {
                return fail(.validationFailed("round-trip mismatch"))
            }
        } else {
            // No-op: already in target mode
            setState(.completed)
            Self.log.info("Already in \(targetMode.rawValue, privacy: .public) mode — no-op")
            return .completed
        }

        let desired = configuration(from: current, for: targetMode)!

        // Step 3 — Backup
        setState(.backingUp)
        let backup = USBConfigBackup(
            original: USBConfigBackup.USBConfigSnapshot(current),
            targetMode: targetMode.rawValue,
            targetConfig: USBConfigBackup.USBConfigSnapshot(desired),
            createdAt: Date(),
            writeStarted: false,
            verificationCompleted: false
        )
        do {
            try USBConfigBackupStore.save(backup, to: backupDirectory)
            Self.log.info("Backup saved to disk")
        } catch {
            return fail(.backupFailed(error.localizedDescription))
        }

        // Step 4 — Write
        setState(.writing)
        let writeResult = transport.execute(command: desired.writeCommand, timeoutMS: 10_000)
        guard writeResult.code == 0 else {
            cleanupBackup()
            return fail(.writeFailed(writeResult.code))
        }
        Self.log.info("Write accepted by modem")

        // Mark write started in persistent backup
        var writtenBackup = backup
        writtenBackup.writeStarted = true
        try? USBConfigBackupStore.save(writtenBackup, to: backupDirectory)

        // Step 5 — Wait for re-enumeration
        setState(.waitingForReenumeration)
        Self.log.info("Waiting for USB re-enumeration...")
        let reconnected = transport.waitForReconnect(timeoutMS: 15_000)
        guard reconnected else {
            cleanupBackup()
            return fail(.reenumerationTimeout)
        }

        // Step 6 — Reconnect
        setState(.reconnecting)
        Self.log.info("Modem rediscovered")

        // Step 7 — Readback verification
        setState(.verifying)
        guard let actual = readConfiguration() else {
            cleanupBackup()
            return fail(.readbackFailed)
        }

        // Verify actual matches desired
        guard actual == desired else {
            Self.log.error("Readback mismatch — initiating rollback")
            let rollbackResult = performRollback(original: current)
            cleanupBackup()
            return rollbackResult
        }

        // Verify diff from original is only UAC
        let finalDiff = validateDiff(from: current, to: actual)
        if case .failure = finalDiff {
            let rollbackResult = performRollback(original: current)
            cleanupBackup()
            return rollbackResult
        }

        // Step 8 — Complete
        setState(.completed)
        Self.log.info("Transition to \(targetMode.rawValue, privacy: .public) completed successfully")

        // Mark verification complete, keep backup as known-good reference
        var completedBackup = backup
        completedBackup.writeStarted = true
        completedBackup.verificationCompleted = true
        try? USBConfigBackupStore.save(completedBackup, to: backupDirectory)

        return .completed
    }

    // MARK: - Rollback

    /// Attempt to restore the original configuration after a failed transition.
    private func performRollback(original: USBConfiguration) -> USBModeTransitionState {
        setState(.rollingBack)
        Self.log.warning("Rolling back to original config")

        let writeResult = transport.execute(command: original.writeCommand, timeoutMS: 10_000)
        guard writeResult.code == 0 else {
            Self.log.error("Rollback write failed: code \(writeResult.code)")
            return .failed("rollback write failed: \(writeResult.code)")
        }

        // Wait for re-enumeration after rollback
        let reconnected = transport.waitForReconnect(timeoutMS: 15_000)
        guard reconnected else {
            return .failed("rollback re-enumeration timed out")
        }

        // Verify rollback
        guard let actual = readConfiguration() else {
            return .failed("rollback readback failed")
        }
        guard actual == original else {
            Self.log.error("Rollback verification failed — original not restored")
            return .failed("rollback verification failed")
        }

        Self.log.info("Rollback successful — original config restored")
        return .failed("transition failed, rollback succeeded")
    }

    // MARK: - Crash Recovery

    /// Check for an unfinished transition from a previous session.
    ///
    /// Call this at app startup after the modem connection is established.
    /// Compares the current modem config against the backed-up original and desired.
    enum RecoveryResult: Equatable {
        case clean              // No backup or backup was complete
        case restored           // current == original (write didn't take effect)
        case completedRecovery  // current == desired (write succeeded, verification didn't)
        case conflict           // current differs from both — needs manual attention
    }

    func recoverUnfinishedTransition() -> RecoveryResult {
        guard let backup = USBConfigBackupStore.load(from: backupDirectory) else {
            Self.log.info("No USB transition backup found")
            return .clean
        }

        // If previous transition was fully verified, clean up and return clean
        if backup.verificationCompleted {
            USBConfigBackupStore.delete(from: backupDirectory)
            Self.log.info("Previous transition was verified — cleaning up backup")
            return .clean
        }

        Self.log.warning("Unfinished USB transition found (writeStarted=\(backup.writeStarted))")

        guard let current = readConfiguration() else {
            Self.log.error("Cannot read current config for crash recovery")
            return .conflict
        }

        let originalConfig = backup.original.configuration
        let desiredConfig = backup.targetConfig.configuration

        // A legitimate CellDock mode switch only ever toggles UAC/audio, so a
        // state reached by an interrupted transition must sit at either the
        // original or the desired composition: identical protected fields, with
        // UAC matching that side. Comparing the typed composition (not raw text)
        // also tolerates a modem that hex-formats VID/PID differently (0x125 vs
        // 0x0125). Any change to a protected field is a genuine conflict and is
        // never auto-resolved here.
        let currentIsOriginalComposition =
            current.hasSameProtectedFields(as: originalConfig) &&
            current.uacEnabled == originalConfig.uacEnabled
        let currentIsDesiredComposition =
            current.hasSameProtectedFields(as: desiredConfig) &&
            current.uacEnabled == desiredConfig.uacEnabled

        if currentIsOriginalComposition {
            Self.log.info("Current config matches original — write did not take effect")
            USBConfigBackupStore.delete(from: backupDirectory)
            return .restored
        }

        if currentIsDesiredComposition {
            Self.log.info("Current config matches desired — write succeeded, verifying")
            // Complete the verification that was interrupted
            let finalDiff = validateDiff(from: originalConfig, to: current)
            if case .success = finalDiff {
                var completedBackup = backup
                completedBackup.verificationCompleted = true
                try? USBConfigBackupStore.save(completedBackup, to: backupDirectory)
                Self.log.info("Crash recovery: transition actually completed")
                return .completedRecovery
            }
            return .conflict
        }

        Self.log.error("Current config differs from both original and desired")
        return .conflict
    }

    // MARK: - Helpers

    private func setState(_ state: USBModeTransitionState) {
        transitionState = state
    }

    private func fail(_ error: USBTransitionError) -> USBModeTransitionState {
        let state: USBModeTransitionState = .failed(error.localizedDescription)
        transitionState = state
        Self.log.error("Transition failed: \(error.localizedDescription, privacy: .public)")
        return state
    }

    /// Parse a writeCommand string back into USBConfiguration for round-trip verification.
    private func parseWriteCommand(_ config: USBConfiguration) -> USBConfiguration? {
        let cmd = config.writeCommand
        // Strip "AT+QCFG=\"usbcfg\"," prefix to get fields
        let prefix = "AT+QCFG=\"usbcfg\","
        guard cmd.hasPrefix(prefix) else { return nil }
        let fields = String(cmd.dropFirst(prefix.count))
        let response = "+QCFG: \"usbcfg\",\(fields)"
        guard case .success(let parsed) = USBConfiguration.parse(response: response) else { return nil }
        return parsed
    }

    /// Remove the persistent backup file.
    private func cleanupBackup() {
        USBConfigBackupStore.delete(from: backupDirectory)
    }

    // MARK: - Error types

    enum USBValidationError: LocalizedError, Equatable {
        case unexpectedFieldChange(String)
        case noDifference

        var errorDescription: String? {
            switch self {
            case .unexpectedFieldChange(let name):
                return "unexpected change in \(name); only UAC may differ"
            case .noDifference:
                return "configurations are identical"
            }
        }
    }
}
