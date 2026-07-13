//
//  ChatMediaDiskCache.swift
//  CodeAgentsMobile
//
//  Purpose: Durable on-disk cache for chat media previews (survives app relaunch).
//  Lives in Caches so the system may reclaim under pressure; not Temporary Directory.
//

import CryptoKit
import Foundation

enum ChatMediaDiskCache {
    static let directoryName = "ChatMediaCache"
    /// Soft cap — prune oldest files when exceeded after a write.
    static let maxTotalBytes: Int64 = 400 * 1024 * 1024

    private static let fileManager = FileManager.default

    static var directoryURL: URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Stable absolute path for a logical cache key (does not create the file).
    static func fileURL(forKey key: String, pathExtension: String?) -> URL {
        let digest = sha256Hex(key)
        let ext = sanitizedExtension(pathExtension)
        let name = ext.isEmpty ? digest : "\(digest).\(ext)"
        return directoryURL.appendingPathComponent(name)
    }

    /// Returns an existing on-disk file for the key, if present and non-empty.
    static func existingFile(forKey key: String, pathExtension: String?) -> URL? {
        let url = fileURL(forKey: key, pathExtension: pathExtension)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        // Touch access date for LRU pruning.
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return url
    }

    /// Scan for any file matching the key digest (when extension is unknown).
    static func existingFile(forKey key: String) -> URL? {
        let digest = sha256Hex(key)
        let dir = directoryURL
        guard let items = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for item in items {
            let name = item.deletingPathExtension().lastPathComponent
            if name == digest {
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 {
                    try? fileManager.setAttributes(
                        [.modificationDate: Date()],
                        ofItemAtPath: item.path
                    )
                    return item
                }
            }
        }
        return nil
    }

    /// Move/copy a downloaded file into the durable cache location.
    @discardableResult
    static func storeFile(at source: URL, forKey key: String, pathExtension: String?) throws -> URL {
        let destination = fileURL(forKey: key, pathExtension: pathExtension ?? source.pathExtension)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        // Prefer move (same volume); fall back to copy.
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            try fileManager.copyItem(at: source, to: destination)
            try? fileManager.removeItem(at: source)
        }
        pruneIfNeeded()
        return destination
    }

    /// Write raw bytes into the durable cache.
    @discardableResult
    static func storeData(_ data: Data, forKey key: String, pathExtension: String?) throws -> URL {
        let destination = fileURL(forKey: key, pathExtension: pathExtension)
        try data.write(to: destination, options: [.atomic])
        pruneIfNeeded()
        return destination
    }

    // MARK: - Pruning

    static func pruneIfNeeded() {
        let dir = directoryURL
        guard let items = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        struct Entry {
            let url: URL
            let size: Int64
            let modified: Date
        }

        var entries: [Entry] = []
        var total: Int64 = 0
        for url in items {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast
            total += size
            entries.append(Entry(url: url, size: size, modified: modified))
        }

        guard total > maxTotalBytes else { return }

        entries.sort { $0.modified < $1.modified }
        for entry in entries {
            guard total > maxTotalBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    // MARK: - Helpers

    static func sha256Hex(_ value: String) -> String {
        sha256Hex(Data(value.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedExtension(_ ext: String?) -> String {
        guard let ext else { return "" }
        let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !trimmed.isEmpty else { return "" }
        let allowed = CharacterSet.alphanumerics
        let filtered = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        return filtered
    }
}
