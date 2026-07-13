//
//  RemoteFileThumbnailLoader.swift
//  CodeAgentsMobile
//
//  Purpose: Download remote media once and produce cached list thumbnails.
//

import AVFoundation
import Foundation
import ImageIO
import UIKit

@MainActor
final class RemoteFileThumbnailLoader {
    static let shared = RemoteFileThumbnailLoader()

    private let sshService = ServiceManager.shared.sshService
    private let fileManager = FileManager.default

    private var memoryCache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// Soft cap so listing a folder of large videos does not thrash the network.
    private let maxImageBytes: Int64 = 12 * 1024 * 1024
    private let maxVideoBytes: Int64 = 40 * 1024 * 1024
    private let thumbnailPixelSize: CGFloat = 160

    private init() {}

    func cachedThumbnail(for node: FileNode, projectId: UUID) -> UIImage? {
        memoryCache[cacheKey(projectId: projectId, node: node)]
    }

    func thumbnail(for node: FileNode, project: RemoteProject) async -> UIImage? {
        guard node.isMediaFile else { return nil }

        let key = cacheKey(projectId: project.id, node: node)
        if let cached = memoryCache[key] {
            return cached
        }
        if let disk = loadDiskThumbnail(key: key) {
            memoryCache[key] = disk
            return disk
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadThumbnail(node: node, project: project, key: key)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            memoryCache[key] = image
        }
        return image
    }

    // MARK: - Private

    private func loadThumbnail(node: FileNode, project: RemoteProject, key: String) async -> UIImage? {
        if let size = node.fileSize {
            if node.isImageFile, size > maxImageBytes { return nil }
            if node.isVideoFile, size > maxVideoBytes { return nil }
        }

        guard let session = try? await sshService.getConnection(for: project, purpose: .fileOperations) else {
            return nil
        }

        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("file-browser-thumbs", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).\(node.fileExtension ?? "bin")")
        try? fileManager.createDirectory(
            at: tempURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: tempURL) }

        do {
            try await session.downloadFile(remotePath: node.path, localPath: tempURL)
        } catch {
            return nil
        }

        let image: UIImage?
        if node.isVideoFile {
            image = await videoThumbnail(at: tempURL)
        } else {
            image = imageThumbnail(at: tempURL)
        }

        if let image, let data = image.jpegData(compressionQuality: 0.82) {
            try? data.write(to: diskURL(for: key), options: .atomic)
        }
        return image
    }

    private func imageThumbnail(at url: URL) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return UIImage(contentsOfFile: url.path)
        }

        let maxPixel = Int(thumbnailPixelSize * UIScreen.main.scale)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(contentsOfFile: url.path)
        }
        return UIImage(cgImage: cgImage)
    }

    private func videoThumbnail(at url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let max = thumbnailPixelSize * UIScreen.main.scale
        generator.maximumSize = CGSize(width: max, height: max)

        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                if let image {
                    continuation.resume(returning: UIImage(cgImage: image))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func cacheKey(projectId: UUID, node: FileNode) -> String {
        let mtime = node.modificationDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        let size = node.fileSize.map(String.init) ?? "0"
        return "\(projectId.uuidString)|\(node.path)|\(size)|\(mtime)"
    }

    private func diskCacheDirectory() -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base.appendingPathComponent("FileBrowserThumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func diskURL(for key: String) -> URL {
        let digest = key.data(using: .utf8).map { Data($0).base64EncodedString() } ?? key
        let safe = digest
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return diskCacheDirectory().appendingPathComponent("\(safe).jpg")
    }

    private func loadDiskThumbnail(key: String) -> UIImage? {
        let url = diskURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
