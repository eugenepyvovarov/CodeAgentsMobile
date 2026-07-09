//
//  ChatAttachmentLocalStore.swift
//  CodeAgentsMobile
//
//  Purpose: Durable on-device cache for chat attachment files (preview + retry after upload failure).
//  Uses Application Support so iOS does not purge files the way Temporary Directory can.
//

import Foundation

enum ChatAttachmentLocalStore {
    static let directoryName = "chat-attachments"

    /// Root directory for staged chat attachment bytes.
    static var directoryURL: URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Stage a security-scoped or external file into the durable store.
    static func stageCopy(from sourceURL: URL) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let destination = uniqueDestination(filename: sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// If `path` is already under our store and exists, return it; otherwise copy into the store.
    /// Used before upload so retries always have a durable local file.
    static func ensureDurableCopy(at path: String, displayName: String) throws -> URL {
        let fileManager = FileManager.default
        let source = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: source.path) else {
            throw ChatAttachmentError.missingLocalFile(displayName)
        }

        let storeRoot = directoryURL.standardizedFileURL.path
        let sourcePath = source.standardizedFileURL.path
        if sourcePath.hasPrefix(storeRoot + "/") || sourcePath == storeRoot {
            return source
        }

        let destination = uniqueDestination(filename: displayName.isEmpty ? source.lastPathComponent : displayName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    /// Resolve a stored local path, recovering via basename under the store if the absolute path moved.
    static func resolveExistingFile(at path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty else { return nil }
        let candidate = directoryURL.appendingPathComponent(name)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func uniqueDestination(filename: String) -> URL {
        let safe = sanitizeFilename(filename)
        return directoryURL.appendingPathComponent("\(UUID().uuidString)-\(safe)")
    }

    private static func sanitizeFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "file" }

        var result = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_" {
                result.append(Character(scalar))
            } else {
                result.append("_")
            }
        }

        let collapsed = result
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))

        return collapsed.isEmpty ? "file" : collapsed
    }
}
