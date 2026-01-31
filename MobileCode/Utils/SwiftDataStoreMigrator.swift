//
//  SwiftDataStoreMigrator.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2025-10-11.
//

import Foundation
import SwiftData

/// Handles one-time migration of the SwiftData store into the shared app group.
enum SwiftDataStoreMigrator {
    /// Copies the legacy on-device store into the shared app-group location when needed.
    /// - Parameters:
    ///   - schema: The schema used by the existing store (used to resolve the legacy URL).
    ///   - destinationURL: The URL for the new shared store.
    static func migrateIfNeeded(schema: Schema, destinationURL: URL) {
        let fileManager = FileManager.default
        let destinationExists = fileManager.fileExists(atPath: destinationURL.path)

        let legacyCandidates = resolveLegacyStoreURLs(schema: schema, destinationURL: destinationURL, using: fileManager)

        // If the destination doesn't exist yet, migrate from the first legacy store that looks populated.
        if !destinationExists {
            guard let legacyURL = firstPopulatedLegacyStore(from: legacyCandidates, using: fileManager, schema: schema) else {
                return
            }

            migrateStore(from: legacyURL, to: destinationURL, destinationExisted: false, using: fileManager)
            return
        }

        // Destination exists — only replace it when it appears empty and we have legacy data available.
        let destinationHasData = storeContainsUserData(at: destinationURL, schema: schema)
        guard !destinationHasData else {
            return
        }

        guard let legacyURL = firstPopulatedLegacyStore(from: legacyCandidates, using: fileManager, schema: schema) else {
            return
        }

        migrateStore(from: legacyURL, to: destinationURL, destinationExisted: true, using: fileManager)
    }

    private static func resolveLegacyStoreURLs(schema: Schema, destinationURL: URL, using fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []

        // 1) If we previously ran without App Groups, we persisted to the app's documents directory.
        candidates.append(AppGroup.fallbackDocumentsStoreURL)

        // 2) Older builds may have used SwiftData's default store location.
        let defaultConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        candidates.append(defaultConfiguration.url)

        // Keep stable order and remove duplicates / destination itself.
        var unique: [URL] = []
        unique.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard candidate != destinationURL else { continue }
            guard !unique.contains(candidate) else { continue }
            unique.append(candidate)
        }

        // Avoid returning unreadable or missing URLs.
        return unique.filter { fileManager.fileExists(atPath: $0.path) && fileManager.isReadableFile(atPath: $0.path) }
    }

    private static func firstPopulatedLegacyStore(from candidates: [URL], using fileManager: FileManager, schema: Schema) -> URL? {
        for url in candidates {
            guard fileManager.fileExists(atPath: url.path), fileManager.isReadableFile(atPath: url.path) else { continue }
            if storeContainsUserData(at: url, schema: schema) {
                return url
            }
        }
        return nil
    }

    private static func migrateStore(from legacyURL: URL, to destinationURL: URL, destinationExisted: Bool, using fileManager: FileManager) {
        // Create the destination directory if needed.
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            print("⚠️ Failed to create shared store directory: \(error)")
            return
        }

        do {
            if destinationExisted {
                _ = try backupExistingStore(at: destinationURL, using: fileManager)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try fileManager.copyItem(at: legacyURL, to: destinationURL)
            copySidecars(from: legacyURL, to: destinationURL, using: fileManager)
            print("✅ Migrated SwiftData store from \(legacyURL.lastPathComponent) to \(destinationURL.path)")
        } catch {
            print("⚠️ Failed to migrate SwiftData store: \(error)")
        }
    }

    private static func backupExistingStore(at destinationURL: URL, using fileManager: FileManager) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(destinationURL.lastPathComponent).backup-\(timestamp)")

        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }

        try fileManager.moveItem(at: destinationURL, to: backupURL)
        moveSidecars(from: destinationURL, to: backupURL, using: fileManager)
        return backupURL
    }

    private static func moveSidecars(from sourceURL: URL, to destinationURL: URL, using fileManager: FileManager) {
        let suffixes = ["-wal", "-shm"]
        let sourcePath = sourceURL.path
        let destinationPath = destinationURL.path

        for suffix in suffixes {
            let sourceSidecarPath = sourcePath + suffix
            let destinationSidecarPath = destinationPath + suffix

            guard fileManager.fileExists(atPath: sourceSidecarPath) else {
                continue
            }

            do {
                if fileManager.fileExists(atPath: destinationSidecarPath) {
                    try fileManager.removeItem(atPath: destinationSidecarPath)
                }
                try fileManager.moveItem(atPath: sourceSidecarPath, toPath: destinationSidecarPath)
            } catch {
                print("⚠️ Failed to move sidecar file \(sourceSidecarPath): \(error)")
            }
        }
    }

    private static func storeContainsUserData(at storeURL: URL, schema: Schema) -> Bool {
        do {
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)

            var projectDescriptor = FetchDescriptor<RemoteProject>()
            projectDescriptor.fetchLimit = 1
            if try !context.fetch(projectDescriptor).isEmpty { return true }

            var serverDescriptor = FetchDescriptor<Server>()
            serverDescriptor.fetchLimit = 1
            if try !context.fetch(serverDescriptor).isEmpty { return true }

            var providerDescriptor = FetchDescriptor<ServerProvider>()
            providerDescriptor.fetchLimit = 1
            if try !context.fetch(providerDescriptor).isEmpty { return true }

            var skillDescriptor = FetchDescriptor<AgentSkill>()
            skillDescriptor.fetchLimit = 1
            if try !context.fetch(skillDescriptor).isEmpty { return true }

            return false
        } catch {
            return false
        }
    }

    /// Copies any WAL/SHM sidecar files that accompany the SQLite store.
    private static func copySidecars(from sourceURL: URL, to destinationURL: URL, using fileManager: FileManager) {
        let suffixes = ["-wal", "-shm"]
        let sourcePath = sourceURL.path
        let destinationPath = destinationURL.path

        for suffix in suffixes {
            let sourceSidecarPath = sourcePath + suffix
            let destinationSidecarPath = destinationPath + suffix

            guard fileManager.fileExists(atPath: sourceSidecarPath) else {
                continue
            }

            do {
                if fileManager.fileExists(atPath: destinationSidecarPath) {
                    try fileManager.removeItem(atPath: destinationSidecarPath)
                }
                try fileManager.copyItem(atPath: sourceSidecarPath, toPath: destinationSidecarPath)
            } catch {
                print("⚠️ Failed to copy sidecar file \(sourceSidecarPath): \(error)")
            }
        }
    }
}
