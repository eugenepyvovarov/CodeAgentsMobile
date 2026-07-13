//
//  ChatMediaLoader.swift
//  CodeAgentsMobile
//
//  Purpose: Resolve CodeAgents UI media sources to local or remote URLs,
//  with durable on-disk caching for previews across app launches.
//

import Foundation
import ImageIO

enum CodeAgentsUIMediaResolved {
    case remote(URL)
    case local(URL)
}

@MainActor
final class ChatMediaLoader: ObservableObject {
    static let shared = ChatMediaLoader()

    private let sshService = ServiceManager.shared.sshService
    private let fileManager = FileManager.default

    /// In-memory map of cacheKey → local file URL (also mirrored on disk).
    private var cache: [String: URL] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var aspectRatioCache: [String: Double] = [:]

    private let maxProjectImageBytes = 25 * 1024 * 1024
    private let maxProjectVideoBytes = 200 * 1024 * 1024
    private let maxBase64Bytes = 1 * 1024 * 1024

    private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic"]
    private let videoExtensions: Set<String> = ["mp4", "mov"]

    private init() { }

    // MARK: - Public

    func resolveMedia(
        _ source: CodeAgentsUIMediaSource,
        project: RemoteProject?
    ) async -> CodeAgentsUIMediaResolved? {
        switch source {
        case .url(let url):
            guard isAllowedURL(url) else { return nil }
            return await resolveRemoteURL(url)
        case .projectFile(let path):
            guard let project else { return nil }
            return await resolveProjectFile(path: path, project: project)
        case .base64(let mediaType, let data):
            return await resolveBase64(mediaType: mediaType, data: data)
        }
    }

    func cachedResolvedMedia(
        _ source: CodeAgentsUIMediaSource,
        project: RemoteProject?
    ) -> CodeAgentsUIMediaResolved? {
        switch source {
        case .url(let url):
            guard isAllowedURL(url) else { return nil }
            let cacheKey = urlCacheKey(url)
            if let local = localCachedURL(forKey: cacheKey, pathExtension: url.pathExtension) {
                return .local(local)
            }
            return .remote(url)
        case .projectFile(let path):
            guard let project else { return nil }
            let cacheKey = projectCacheKey(projectId: project.id, path: path)
            let ext = URL(fileURLWithPath: path).pathExtension
            if let local = localCachedURL(forKey: cacheKey, pathExtension: ext) {
                return .local(local)
            }
            return nil
        case .base64(_, let data):
            let cacheKey = base64CacheKey(data)
            if let local = localCachedURL(forKey: cacheKey, pathExtension: nil) {
                return .local(local)
            }
            return nil
        }
    }

    func cachedAspectRatio(
        _ source: CodeAgentsUIMediaSource,
        project: RemoteProject?
    ) -> Double? {
        switch source {
        case .url(let url):
            return aspectRatioCache[urlCacheKey(url)]
        case .projectFile(let path):
            guard let project else { return nil }
            return aspectRatioCache[projectCacheKey(projectId: project.id, path: path)]
        case .base64(_, let data):
            return aspectRatioCache[base64CacheKey(data)]
        }
    }

    func preparePreviewURL(
        for source: CodeAgentsUIMediaSource,
        project: RemoteProject?
    ) async -> URL? {
        guard let resolved = await resolveMedia(source, project: project) else { return nil }
        switch resolved {
        case .local(let url):
            return url
        case .remote(let url):
            // Fallback if resolve couldn't materialize a local copy.
            return await downloadRemoteToDisk(url)
        }
    }

    func preparePreviewItems(
        sources: [CodeAgentsUIMediaSource],
        project: RemoteProject?
    ) async -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(sources.count)
        for source in sources {
            if let url = await preparePreviewURL(for: source, project: project) {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - Resolve paths

    private func resolveProjectFile(path: String, project: RemoteProject) async -> CodeAgentsUIMediaResolved? {
        let lowercasedExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        let mediaType = mediaTypeForExtension(lowercasedExtension)
        guard mediaType != nil else { return nil }

        let cacheKey = projectCacheKey(projectId: project.id, path: path)
        if let local = localCachedURL(forKey: cacheKey, pathExtension: lowercasedExtension) {
            await ensureAspectRatio(forKey: cacheKey, mediaType: mediaType, fileURL: local)
            return .local(local)
        }

        if let task = inFlight[cacheKey] {
            if let url = await task.value {
                return .local(url)
            }
            return nil
        }

        let task = Task<URL?, Never> { [sshService] in
            guard let session = try? await sshService.getConnection(for: project, purpose: .fileOperations) else {
                return nil
            }
            let remotePath = "\(project.path)/\(path)"
            guard let size = await Self.remoteFileSize(remotePath, session: session) else {
                return nil
            }
            if let mediaType, !Self.isSizeAllowed(
                size: size,
                mediaType: mediaType,
                maxImage: 25 * 1024 * 1024,
                maxVideo: 200 * 1024 * 1024
            ) {
                return nil
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codeagents-dl-\(UUID().uuidString)")
                .appendingPathExtension(lowercasedExtension)
            do {
                try await session.downloadFile(remotePath: remotePath, localPath: tempURL)
                return try ChatMediaDiskCache.storeFile(
                    at: tempURL,
                    forKey: cacheKey,
                    pathExtension: lowercasedExtension
                )
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
        }

        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil

        if let result {
            cache[cacheKey] = result
            await ensureAspectRatio(forKey: cacheKey, mediaType: mediaType, fileURL: result)
            return .local(result)
        }

        return nil
    }

    private func resolveBase64(mediaType: String, data: Data) async -> CodeAgentsUIMediaResolved? {
        guard mediaType.lowercased().hasPrefix("image/") else { return nil }
        guard data.count <= maxBase64Bytes else { return nil }

        let cacheKey = base64CacheKey(data)
        let ext = extensionForMediaType(mediaType)
        if let local = localCachedURL(forKey: cacheKey, pathExtension: ext) {
            await ensureAspectRatio(forKey: cacheKey, mediaType: "image", fileURL: local)
            return .local(local)
        }

        do {
            let destination = try ChatMediaDiskCache.storeData(data, forKey: cacheKey, pathExtension: ext)
            cache[cacheKey] = destination
            await ensureAspectRatio(forKey: cacheKey, mediaType: "image", fileURL: destination)
            return .local(destination)
        } catch {
            return nil
        }
    }

    private func resolveRemoteURL(_ url: URL) async -> CodeAgentsUIMediaResolved? {
        let cacheKey = urlCacheKey(url)
        if let local = localCachedURL(forKey: cacheKey, pathExtension: url.pathExtension) {
            let mediaType = mediaTypeForExtension(url.pathExtension.lowercased())
            await ensureAspectRatio(forKey: cacheKey, mediaType: mediaType, fileURL: local)
            return .local(local)
        }

        if let downloaded = await downloadRemoteToDisk(url) {
            return .local(downloaded)
        }

        // Network failed — still allow streaming remote if reachable later.
        return .remote(url)
    }

    private func downloadRemoteToDisk(_ url: URL) async -> URL? {
        guard isAllowedURL(url) else { return nil }
        let cacheKey = urlCacheKey(url)
        if let local = localCachedURL(forKey: cacheKey, pathExtension: url.pathExtension) {
            return local
        }
        if let task = inFlight[cacheKey] {
            return await task.value
        }

        let task = Task<URL?, Never> {
            let ext = url.pathExtension.lowercased()
            let allowedExt = ext.isEmpty ? nil : ext
            let mediaTypeFromExt = allowedExt.flatMap { Self.mediaTypeForExtensionStatic($0) }
            guard mediaTypeFromExt != nil || allowedExt == nil else { return nil }

            do {
                let (tempURL, response) = try await URLSession.shared.download(from: url)
                let mimeType = response.mimeType
                let mediaType = mediaTypeFromExt ?? mimeType.flatMap { Self.mediaTypeForMimeTypeStatic($0) }
                guard let mediaType else {
                    try? FileManager.default.removeItem(at: tempURL)
                    return nil
                }

                let finalExt = allowedExt
                    ?? mimeType.flatMap { Self.extensionForMediaTypeStatic($0) }
                    ?? tempURL.pathExtension

                let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if !Self.isSizeAllowed(
                    size: Int64(size),
                    mediaType: mediaType,
                    maxImage: 25 * 1024 * 1024,
                    maxVideo: 200 * 1024 * 1024
                ) {
                    try? FileManager.default.removeItem(at: tempURL)
                    return nil
                }

                return try ChatMediaDiskCache.storeFile(
                    at: tempURL,
                    forKey: cacheKey,
                    pathExtension: finalExt
                )
            } catch {
                return nil
            }
        }

        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil

        if let result {
            cache[cacheKey] = result
            let mediaType = mediaTypeForExtension(result.pathExtension.lowercased())
            await ensureAspectRatio(forKey: cacheKey, mediaType: mediaType, fileURL: result)
        }
        return result
    }

    // MARK: - Local cache lookup

    private func localCachedURL(forKey key: String, pathExtension: String?) -> URL? {
        if let cached = cache[key], fileManager.fileExists(atPath: cached.path) {
            return cached
        }
        if let disk = ChatMediaDiskCache.existingFile(forKey: key, pathExtension: pathExtension)
            ?? ChatMediaDiskCache.existingFile(forKey: key) {
            cache[key] = disk
            return disk
        }
        if cache[key] != nil {
            cache[key] = nil
            aspectRatioCache[key] = nil
        }
        return nil
    }

    private func ensureAspectRatio(forKey key: String, mediaType: String?, fileURL: URL) async {
        guard mediaType == "image" else { return }
        if aspectRatioCache[key] != nil { return }
        if let ratio = await imageAspectRatio(for: fileURL) {
            aspectRatioCache[key] = ratio
        }
    }

    // MARK: - Keys

    private func projectCacheKey(projectId: UUID, path: String) -> String {
        "project:\(projectId.uuidString):\(path)"
    }

    private func urlCacheKey(_ url: URL) -> String {
        "url:\(url.absoluteString)"
    }

    private func base64CacheKey(_ data: Data) -> String {
        // Content hash is stable across launches (unlike Data.hashValue).
        "base64:\(ChatMediaDiskCache.sha256Hex(data))"
    }

    // MARK: - ImageIO / helpers

    private func imageAspectRatio(for url: URL) async -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: false
                ]
                guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                guard let width = properties?[kCGImagePropertyPixelWidth] as? Double,
                      let height = properties?[kCGImagePropertyPixelHeight] as? Double,
                      width > 0,
                      height > 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                let orientation = properties?[kCGImagePropertyOrientation] as? UInt32
                let shouldSwap = orientation.map { (5...8).contains(Int($0)) } ?? false
                continuation.resume(returning: shouldSwap ? (height / width) : (width / height))
            }
        }
    }

    private static func remoteFileSize(_ path: String, session: SSHSession) async -> Int64? {
        let escaped = shellEscaped(path)
        let command = "stat -f%z \(escaped) 2>/dev/null || stat -c%s \(escaped) 2>/dev/null"
        guard let output = try? await session.execute(command) else {
            return nil
        }
        return parseFirstInt64(from: output)
    }

    private static func parseFirstInt64(from output: String) -> Int64? {
        let tokens = output.split { !$0.isNumber }
        for token in tokens {
            if let value = Int64(token) {
                return value
            }
        }
        return nil
    }

    private func isAllowedURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return true }
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    private func mediaTypeForExtension(_ ext: String) -> String? {
        Self.mediaTypeForExtensionStatic(ext)
    }

    private static func mediaTypeForExtensionStatic(_ ext: String) -> String? {
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic"]
        let videoExtensions: Set<String> = ["mp4", "mov"]
        if imageExtensions.contains(ext) { return "image" }
        if videoExtensions.contains(ext) { return "video" }
        return nil
    }

    private static func isSizeAllowed(
        size: Int64,
        mediaType: String,
        maxImage: Int64,
        maxVideo: Int64
    ) -> Bool {
        switch mediaType {
        case "image":
            return size <= maxImage
        case "video":
            return size <= maxVideo
        default:
            return false
        }
    }

    private func extensionForMediaType(_ mediaType: String) -> String? {
        Self.extensionForMediaTypeStatic(mediaType)
    }

    private static func extensionForMediaTypeStatic(_ mediaType: String) -> String? {
        let lower = mediaType.lowercased()
        if lower == "image/png" { return "png" }
        if lower == "image/jpeg" { return "jpg" }
        if lower == "image/webp" { return "webp" }
        if lower == "image/gif" { return "gif" }
        if lower == "image/heic" { return "heic" }
        if lower == "video/mp4" { return "mp4" }
        if lower == "video/quicktime" { return "mov" }
        return nil
    }

    private static func mediaTypeForMimeTypeStatic(_ mimeType: String) -> String? {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") { return "image" }
        if lower.hasPrefix("video/") { return "video" }
        return nil
    }

    private static func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
