import Foundation

@MainActor protocol DeviceSession: AnyObject {
    var canReuse: Bool { get }
    func activate()
    func deactivate()
    func stop()
}

extension DeviceSession { var canReuse: Bool { true } }

/// Retain recent connections. Leases keep an old view's delayed cancellation
/// from suspending a newly selected session.
@MainActor final class DeviceSessionCache<Session: DeviceSession> {
    struct Lease {
        let key: String
        let token: UUID
        let session: Session
    }
    private struct Entry {
        let session: Session
        var leases: Set<UUID>
        var lastUsed: UInt64
    }
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0
    private let capacity: Int

    init(capacity: Int = 12) { self.capacity = max(1, capacity) }

    func acquire(_ key: String, create: () -> Session) -> Lease {
        if let entry = entries[key], !entry.session.canReuse {
            entries.removeValue(forKey: key)?.session.stop()
        }
        sequence += 1
        let token = UUID()
        var entry = entries[key] ?? Entry(session: create(), leases: [], lastUsed: sequence)
        if entry.leases.isEmpty { entry.session.activate() }
        entry.leases.insert(token)
        entry.lastUsed = sequence
        entries[key] = entry
        trim()
        return Lease(key: key, token: token, session: entry.session)
    }

    func release(_ lease: Lease) {
        guard var entry = entries[lease.key], entry.session === lease.session,
              entry.leases.remove(lease.token) != nil else { return }
        entries[lease.key] = entry
        if entry.leases.isEmpty { entry.session.deactivate() }
        trim()
    }

    func discard(_ lease: Lease) {
        guard entries[lease.key]?.session === lease.session else { return }
        entries.removeValue(forKey: lease.key)?.session.stop()
    }

    func retain(_ keys: Set<String>) {
        for key in Array(entries.keys) where !keys.contains(key) {
            entries.removeValue(forKey: key)?.session.stop()
        }
    }

    private func trim() {
        while entries.count > capacity,
              let oldest = entries.filter({ $0.value.leases.isEmpty }).min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries.removeValue(forKey: oldest)?.session.stop()
        }
    }
}
