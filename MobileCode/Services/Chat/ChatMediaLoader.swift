//
//  ChatMediaLoader.swift
//  CodeAgentsMobile
//
//  Purpose: Resolve CodeAgents UI media sources to local or remote URLs.
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

    private var cache: [String: URL] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var previewCache: [String: URL] = [:]
    private var previewInFlight: [String: Task<URL?, Never>] = [:]
    private var aspectRatioCache: [String: Double] = [:]

    private let maxProjectImageBytes = 25 * 1024 * 1024
    private let maxProjectVideoBytes = 200 * 1024 * 1024
    private let maxBase64Bytes = 1 * 1024 * 1024

    private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic"]
    private let videoExtensions: Set<String> = ["mp4", "mov"]

    private init() { }

    func resolveMedia(
        _ source: CodeAgentsUIMediaSource,
        project: RemoteProject?
    ) async -> CodeAgentsUIMediaResolved? {
        switch source {
        case .url(let url):
            guard isAllowedURL(url) else { return nil }
            return .remote(url)
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
            return .remote(url)
        case .projectFile(let path):
            guard let project else { return nil }
            let cacheKey = "project:\(project.id.uuidString):\(path)"
            if let cached = cache[cacheKey] {
                if fileManager.fileExists(atPath: cached.path) {
                    return .local(cached)
                }
                cache[cacheKey] = nil
                aspectRatioCache[cacheKey] = nil
            }
            return nil
        case .base64(_, let data):
            let cacheKey = "base64:\(data.hashValue)"
            if let cached = cache[cacheKey] {
                if fileManager.fileExists(atPath: cached.path) {
                    return .local(cached)
                }
                cache[cacheKey] = nil
                aspectRatioCache[cacheKey] = nil
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
            return aspectRatioCache["url:\(url.absoluteString)"]
        case .projectFile(let path):
            guard let project else { return nil }
            return aspectRatioCache["project:\(project.id.uuidString):\(path)"]
        case .base64(_, let data):
            return aspectRatioCache["base64:\(data.hashValue)"]
        }
    }

    func preparePreviewURL(
        for source: CodeAgentsUIMediaSource,
        project: RemoteProject?
    ) async -> URL? {
        switch source {
        case .url(let url):
            return await downloadRemotePreview(url)
        case .projectFile(let path):
            guard let project else { return nil }
            if let resolved = await resolveProjectFile(path: path, project: project) {
                switch resolved {
                case .local(let url):
                    return url
                case .remote:
                    return nil
                }
            }
            return nil
        case .base64(let mediaType, let data):
            if let resolved = await resolveBase64(mediaType: mediaType, data: data) {
                switch resolved {
                case .local(let url):
                    return url
                case .remote:
                    return nil
                }
            }
            return nil
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

    // MARK: - Private

    private func resolveProjectFile(path: String, project: RemoteProject) async -> CodeAgentsUIMediaResolved? {
        let lowercasedExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        let mediaType = mediaTypeForExtension(lowercasedExtension)
        guard mediaType != nil else { return nil }

        let cacheKey = "project:\(project.id.uuidString):\(path)"
        if let cached = cache[cacheKey] {
            if fileManager.fileExists(atPath: cached.path) {
                return .local(cached)
            }
            cache[cacheKey] = nil
            aspectRatioCache[cacheKey] = nil
        }

        if let task = inFlight[cacheKey] {
            if let url = await task.value {
                return .local(url)
            }
            return nil
        }

        let task = Task<URL?, Never> {
            guard let session = try? await sshService.getConnection(for: project, purpose: .fileOperations) else {
                return nil
            }
            let remotePath = "\(project.path)/\(path)"
            guard let size = await remoteFileSize(remotePath, session: session) else {
                return nil
            }
            if let mediaType, !isSizeAllowed(size: size, mediaType: mediaType) {
                return nil
            }

            let tempURL = makeTempURL(extension: lowercasedExtension)
            do {
                try await session.downloadFile(remotePath: remotePath, localPath: tempURL)
                return tempURL
            } catch {
                return nil
            }
        }

        inFlight[cacheKey] = task
        let result = await task.value
        inFlight[cacheKey] = nil

        if let result {
            cache[cacheKey] = result
            if mediaType == "image" {
                if let ratio = await imageAspectRatio(for: result) {
                    aspectRatioCache[cacheKey] = ratio
                }
            }
            return .local(result)
        }

        return nil
    }

    private func resolveBase64(mediaType: String, data: Data) async -> CodeAgentsUIMediaResolved? {
        guard mediaType.lowercased().hasPrefix("image/") else { return nil }
        guard data.count <= maxBase64Bytes else { return nil }

        let cacheKey = "base64:\(data.hashValue)"
        if let cached = cache[cacheKey] {
            if fileManager.fileExists(atPath: cached.path) {
                return .local(cached)
            }
            cache[cacheKey] = nil
            aspectRatioCache[cacheKey] = nil
        }

        let ext = extensionForMediaType(mediaType)
        let tempURL = makeTempURL(extension: ext)
        do {
            try data.write(to: tempURL, options: [.atomic])
            cache[cacheKey] = tempURL
            if let ratio = await imageAspectRatio(for: tempURL) {
                aspectRatioCache[cacheKey] = ratio
            }
            return .local(tempURL)
        } catch {
            return nil
        }
    }

    private func downloadRemotePreview(_ url: URL) async -> URL? {
        guard isAllowedURL(url) else { return nil }
        let cacheKey = "url:\(url.absoluteString)"
        if let cached = previewCache[cacheKey] {
            if fileManager.fileExists(atPath: cached.path) {
                return cached
            }
            previewCache[cacheKey] = nil
            aspectRatioCache[cacheKey] = nil
        }
        if let task = previewInFlight[cacheKey] {
            return await task.value
        }

        let task = Task<URL?, Never> {
            let ext = url.pathExtension.lowercased()
            let allowedExt = ext.isEmpty ? nil : ext
            let mediaTypeFromExt = allowedExt.flatMap { mediaTypeForExtension($0) }
            guard mediaTypeFromExt != nil || allowedExt == nil else { return nil }

            do {
                let (tempURL, response) = try await URLSession.shared.download(from: url)
                let mimeType = response.mimeType
                let mediaType = mediaTypeFromExt ?? mimeType.flatMap { mediaTypeForMimeType($0) }
                guard let mediaType else { return nil }

                let finalExt = allowedExt
                    ?? mimeType.flatMap { extensionForMediaType($0) }
                let destination = makeTempURL(extension: finalExt)

                do {
                    try? fileManager.removeItem(at: destination)
                    try fileManager.moveItem(at: tempURL, to: destination)
                } catch {
                    return nil
                }

                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if !isSizeAllowed(size: Int64(size), mediaType: mediaType) {
                    try? fileManager.removeItem(at: destination)
                    return nil
                }

                if mediaType == "image" {
                    if let ratio = await imageAspectRatio(for: destination) {
                        await MainActor.run {
                            aspectRatioCache[cacheKey] = ratio
                        }
                    }
                }

                return destination
            } catch {
                return nil
            }
        }

        previewInFlight[cacheKey] = task
        let result = await task.value
        previewInFlight[cacheKey] = nil

        if let result {
            previewCache[cacheKey] = result
        }

        return result
    }

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

    private func remoteFileSize(_ path: String, session: SSHSession) async -> Int64? {
        let escaped = shellEscaped(path)
        let command = "stat -f%z \(escaped) 2>/dev/null || stat -c%s \(escaped) 2>/dev/null"
        guard let output = try? await session.execute(command) else {
            return nil
        }
        return parseFirstInt64(from: output)
    }

    private func parseFirstInt64(from output: String) -> Int64? {
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
        if imageExtensions.contains(ext) {
            return "image"
        }
        if videoExtensions.contains(ext) {
            return "video"
        }
        return nil
    }

    private func isSizeAllowed(size: Int64, mediaType: String) -> Bool {
        switch mediaType {
        case "image":
            return size <= maxProjectImageBytes
        case "video":
            return size <= maxProjectVideoBytes
        default:
            return false
        }
    }

    private func extensionForMediaType(_ mediaType: String) -> String? {
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

    private func mediaTypeForMimeType(_ mimeType: String) -> String? {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") {
            return "image"
        }
        if lower.hasPrefix("video/") {
            return "video"
        }
        return nil
    }

    private func makeTempURL(extension ext: String?) -> URL {
        let name = "codeagents-\(UUID().uuidString)"
        var url = fileManager.temporaryDirectory.appendingPathComponent(name)
        if let ext, !ext.isEmpty {
            url = url.appendingPathExtension(ext)
        }
        return url
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
