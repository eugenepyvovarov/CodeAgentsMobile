//
//  OpenCodeProviderStatusCache.swift
//  CodeAgentsMobile
//
//  Purpose: Persist last-known OpenCode provider catalogs per server so settings
//  can paint immediately without flashing the short preset list.
//

import Foundation

struct OpenCodeProviderStatusCacheEntry: Codable, Equatable {
    let serverID: UUID
    let serverName: String
    let fetchedAt: Date
    let status: OpenCodeProviderStatus
}

/// Disk + memory cache of OpenCode `/provider` status snapshots, keyed by server id.
final class OpenCodeProviderStatusCache {
    static let shared = OpenCodeProviderStatusCache()

    static let storageKey = "opencode.providerStatus.cache.v1"

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var memory: [UUID: OpenCodeProviderStatusCacheEntry] = [:]
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadFromDiskIntoMemory()
    }

    func entry(for serverID: UUID) -> OpenCodeProviderStatusCacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        return memory[serverID]
    }

    func status(for serverID: UUID) -> OpenCodeProviderStatus? {
        entry(for: serverID)?.status
    }

    func store(_ status: OpenCodeProviderStatus, for server: Server, fetchedAt: Date = Date()) {
        store(
            OpenCodeProviderStatusCacheEntry(
                serverID: server.id,
                serverName: server.name,
                fetchedAt: fetchedAt,
                status: status
            )
        )
    }

    func store(_ entry: OpenCodeProviderStatusCacheEntry) {
        lock.lock()
        memory[entry.serverID] = entry
        let snapshot = memory
        lock.unlock()
        persist(snapshot)
    }

    func remove(serverID: UUID) {
        lock.lock()
        memory.removeValue(forKey: serverID)
        let snapshot = memory
        lock.unlock()
        persist(snapshot)
    }

    func removeAll() {
        lock.lock()
        memory.removeAll()
        lock.unlock()
        userDefaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Private

    private func loadFromDiskIntoMemory() {
        guard let data = userDefaults.data(forKey: Self.storageKey) else { return }
        guard let decoded = try? decoder.decode([String: OpenCodeProviderStatusCacheEntry].self, from: data) else {
            return
        }
        var mapped: [UUID: OpenCodeProviderStatusCacheEntry] = [:]
        for (key, entry) in decoded {
            if let id = UUID(uuidString: key) {
                mapped[id] = entry
            } else {
                mapped[entry.serverID] = entry
            }
        }
        lock.lock()
        memory = mapped
        lock.unlock()
    }

    private func persist(_ snapshot: [UUID: OpenCodeProviderStatusCacheEntry]) {
        var keyed: [String: OpenCodeProviderStatusCacheEntry] = [:]
        keyed.reserveCapacity(snapshot.count)
        for (id, entry) in snapshot {
            keyed[id.uuidString] = entry
        }
        guard let data = try? encoder.encode(keyed) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}
