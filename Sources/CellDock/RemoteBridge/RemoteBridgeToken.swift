import Foundation
import Security

/// Pairing token for the LAN bridge. Generated once on first server start,
/// persisted under the app's Application Support directory with user-only
/// permissions. The iPhone client stores the same token in its Keychain.
enum RemoteBridgeToken {
    static func loadOrCreate() -> String {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("CellDock", isDirectory: true) else {
            return generateAndStore()
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("remote-bridge-token")
        if let data = try? Data(contentsOf: file),
           let token = String(data: data, encoding: .utf8),
           token.count == 9 {
            return token
        }
        let token = generateAndStore()
        try? token.data(using: .utf8)?.write(to: file, options: [.atomic])
        try? fm.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        return token
    }

    private static func generateAndStore() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // ponytail: arc4random fallback is still cryptographically fine
            // on macOS; SecRandom failure is effectively unreachable.
            for index in bytes.indices {
                bytes[index] = UInt8(arc4random_uniform(256))
            }
        }
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(4))-\(hex.suffix(4))"
    }
}
