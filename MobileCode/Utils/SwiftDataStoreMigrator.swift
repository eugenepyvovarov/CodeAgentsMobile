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

        // Skip when the destination store already exists.
        if fileManager.fileExists(atPath: destinationURL.path) {
            return
        }

        // Resolve the legacy location by constructing a configuration without an explicit URL.
        let legacyConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let legacyURL = legacyConfiguration.url

        // If both URLs resolve to the same path, there is nothing to migrate.
        if legacyURL == destinationURL {
            return
        }

        // Ensure we have permission to read the legacy store.
        guard fileManager.isReadableFile(atPath: legacyURL.path) else {
            return
        }

        // Only attempt migration when the legacy store actually exists.
        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return
        }

        // Create the destination directory if needed.
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            print("⚠️ Failed to create shared store directory: \(error)")
            return
        }

        do {
            try fileManager.copyItem(at: legacyURL, to: destinationURL)
            copySidecars(from: legacyURL, to: destinationURL, using: fileManager)
            print("✅ Migrated SwiftData store to shared app group at \(destinationURL.path)")
        } catch {
            print("⚠️ Failed to migrate SwiftData store: \(error)")
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
