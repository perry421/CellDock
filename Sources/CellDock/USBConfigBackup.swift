import Foundation

/// Persistent emergency backup for USB configuration transitions.
///
/// Stored in Application Support to survive crashes during the
/// write → re-enumeration → verification window.
struct USBConfigBackup: Codable, Equatable {
    let original: USBConfigSnapshot
    let targetMode: String           // "mac" or "mobile"
    let targetConfig: USBConfigSnapshot
    let createdAt: Date
    var writeStarted: Bool
    var verificationCompleted: Bool

    struct USBConfigSnapshot: Codable, Equatable {
        let vendorID: UInt16
        let productID: UInt16
        let atEnabled: Bool
        let nmeaEnabled: Bool
        let diagEnabled: Bool
        let modemEnabled: Bool
        let reservedFlag: Bool
        let adbEnabled: Bool
        let uacEnabled: Bool
        let serialized: String        // writeCommand output for exact replay

        init(_ config: USBConfiguration) {
            self.vendorID = config.vendorID
            self.productID = config.productID
            self.atEnabled = config.atEnabled
            self.nmeaEnabled = config.nmeaEnabled
            self.diagEnabled = config.diagEnabled
            self.modemEnabled = config.modemEnabled
            self.reservedFlag = config.reservedFlag
            self.adbEnabled = config.adbEnabled
            self.uacEnabled = config.uacEnabled
            self.serialized = config.writeCommand
        }

        /// Reconstruct a USBConfiguration from the snapshot.
        var configuration: USBConfiguration {
            USBConfiguration(
                vendorID: vendorID, productID: productID,
                atEnabled: atEnabled, nmeaEnabled: nmeaEnabled,
                diagEnabled: diagEnabled, modemEnabled: modemEnabled,
                reservedFlag: reservedFlag, adbEnabled: adbEnabled,
                uacEnabled: uacEnabled
            )
        }
    }
}

/// Manages reading/writing USB configuration transition backups to disk.
enum USBConfigBackupStore {
    private static let fileName = "usb-config-backup.json"

    /// Directory for persistent USB transition state.
    /// Located in Application Support / CellDock.
    static func backupURL(for directory: URL? = nil) -> URL {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let fm = FileManager.default
            if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                dir = appSupport.appendingPathComponent("CellDock", isDirectory: true)
            } else {
                dir = fm.temporaryDirectory
            }
        }
        return dir.appendingPathComponent(fileName)
    }

    /// Save a backup to disk.
    static func save(_ backup: USBConfigBackup, to directory: URL? = nil) throws {
        let data = try JSONEncoder().encode(backup)
        let url = backupURL(for: directory)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Load a backup from disk. Returns nil if no backup exists or if it's corrupted.
    static func load(from directory: URL? = nil) -> USBConfigBackup? {
        let url = backupURL(for: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(USBConfigBackup.self, from: data)
    }

    /// Delete the backup from disk.
    static func delete(from directory: URL? = nil) {
        let url = backupURL(for: directory)
        try? FileManager.default.removeItem(at: url)
    }
}
