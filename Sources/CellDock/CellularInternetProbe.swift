import Foundation

enum CellularInternetProbe {
    /// Numeric endpoints avoid DNS and prove that traffic leaves through the
    /// exact ECM interface selected by `IP_BOUND_IF`.
    static func isReachable(bsdName: String) -> Bool {
        let endpoints: [[UInt8]] = [
            [223, 5, 5, 5],
            [1, 1, 1, 1],
        ]
        for address in endpoints {
            do {
                let socket = try BoundSocket(family: .ipv4, kind: .tcp, bsdName: bsdName)
                try socket.setTimeout(seconds: 2)
                try socket.connect(to: .ipv4(address), port: 443)
                return true
            } catch {
                continue
            }
        }
        return false
    }
}
