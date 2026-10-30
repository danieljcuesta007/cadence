// Fail-private history recovery. No file writes, transcript logging, or clipboard writes.
import Foundation

final class PendingHistory {
    struct Item {
        let token: UUID
        let record: [String: Any]
    }
    static let shared = PendingHistory()
    static let changed = Notification.Name("CadencePendingHistoryChanged")
    private let lock = NSLock()
    private var items: [Item] = []
    var snapshot: [Item] { lock.lock(); defer { lock.unlock() }; return items }
    var count: Int { snapshot.count }

    func append(_ record: [String: Any]) {
        lock.lock()
        items.append(Item(token: UUID(), record: record))
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    /// Only remove the exact item whose encrypted write succeeded. New dictations may
    /// arrive while a retry runs, and a failed retry must preserve all remaining words.
    @discardableResult
    func retry(write: ([String: Any]) -> Bool) -> Int {
        var saved = 0
        for item in snapshot {
            guard write(item.record) else { continue }
            lock.lock()
            if let i = items.firstIndex(where: { $0.token == item.token }) {
                items.remove(at: i); saved += 1
            }
            lock.unlock()
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
        return saved
    }

    var copyText: String {
        snapshot.compactMap { $0.record["text"] as? String }.joined(separator: "\n\n")
    }
}
