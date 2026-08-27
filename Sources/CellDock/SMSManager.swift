import Foundation

/// Side-channel mirror of PDU-decoded SMS that `MessageStore` already accepted.
///
/// CellDock's modem always operates in PDU mode (`AT+CMGF=0`) and the
/// existing `MessageStore` / `NotificationService` pipeline is the sole
/// source of truth for decoding, deduplication, and user-visible
/// notifications. `SMSManager` mirrors a copy of every *new* `SMSMessage`
/// into a short in-memory list so Settings can surface a "SIM 短信列表"
/// without duplicating the PDU pipeline or creating a second notification
/// source.
///
/// Deduplication uses `SMSMessage.id` (a SHA-256 of the raw PDU payloads),
/// which is more stable than sender+body+minute because it survives
/// cosmetic re-encoding of the same SMS.
final class SMSManager: ObservableObject {
    static let shared = SMSManager()

    static let historyLimit = 100

    @Published private(set) var messages: [ModemSMSMessage] = []

    private var seenIDs: Set<String> = []

    /// Replaces the entire in-memory list, e.g. after a manual clear from
    /// the UI. Resets dedup state so previously-seen messages would be
    /// re-added if they arrive again.
    func replaceMessages(_ messages: [ModemSMSMessage]) {
        self.messages = messages
        seenIDs.removeAll(keepingCapacity: true)
        for message in messages {
            seenIDs.insert(message.id.uuidString)
        }
    }

    /// Mirrors already-decoded incoming messages into the recent list.
    /// Returns the subset that was actually new (not deduplicated).
    @discardableResult
    func ingest(_ messages: [SMSMessage]) -> [ModemSMSMessage] {
        var newMirrors: [ModemSMSMessage] = []
        for message in messages {
            guard !seenIDs.contains(message.id) else { continue }
            let mirror = ModemSMSMessage(
                sender: message.sender,
                timestamp: message.timestamp,
                body: message.body,
                receivedAt: message.firstSeenAt
            )
            seenIDs.insert(message.id)
            newMirrors.append(mirror)
        }
        guard !newMirrors.isEmpty else { return [] }
        // Insert newest-first so the list stays sorted with the most recent
        // item at the top.
        self.messages.insert(contentsOf: newMirrors.reversed(), at: 0)
        if self.messages.count > Self.historyLimit {
            self.messages = Array(self.messages.prefix(Self.historyLimit))
        }
        return newMirrors
    }

    /// Clears the in-memory list and dedup state.
    func clear() {
        messages.removeAll()
        seenIDs.removeAll(keepingCapacity: true)
    }
}

