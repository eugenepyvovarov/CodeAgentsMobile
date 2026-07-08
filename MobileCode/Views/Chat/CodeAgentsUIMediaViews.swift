//
//  CodeAgentsUIMediaViews.swift
//  CodeAgentsMobile
//
//  Purpose: Image, gallery, and video widgets for codeagents_ui blocks
//

import SwiftUI
import AVKit
import ImageIO
import UIKit

struct CodeAgentsUIMediaPreviewPayload: Identifiable {
    let id = UUID()
    let urls: [URL]
    let startIndex: Int
}

final class CodeAgentsUIMediaImageCache {
    static let shared = CodeAgentsUIMediaImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 60 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ image: UIImage, for url: URL) {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        let estimatedBytes = max(1, pixelWidth * pixelHeight * 4)
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: estimatedBytes)
    }
}

struct CodeAgentsUIImageView: View {
    let image: CodeAgentsUIImage
    let project: RemoteProject?
    @State private var previewPayload: CodeAgentsUIMediaPreviewPayload?
    @State private var isPreparingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeAgentsUIMediaImageView(
                source: image.source,
                project: project,
                aspectRatio: image.aspectRatio
            )
            if let caption = image.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openPreview()
        }
        .sheet(item: $previewPayload) { payload in
            CodeAgentsUIMediaPreviewController(urls: payload.urls, startIndex: payload.startIndex)
        }
    }

    private func openPreview() {
        guard !isPreparingPreview else { return }
        isPreparingPreview = true
        Task {
            let project = project ?? ProjectContext.shared.activeProject
            let urls = await ChatMediaLoader.shared.preparePreviewItems(sources: [image.source], project: project)
            let existing = urls.filter { fileURLExists($0) }
            await MainActor.run {
                if let first = existing.first {
                    previewPayload = CodeAgentsUIMediaPreviewPayload(urls: [first], startIndex: 0)
                }
                isPreparingPreview = false
            }
        }
    }
}

struct CodeAgentsUIGalleryView: View {
    let gallery: CodeAgentsUIGallery
    let project: RemoteProject?
    @State private var previewPayload: CodeAgentsUIMediaPreviewPayload?
    @State private var isPreparingPreview = false
    private let thumbnailHeight: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(gallery.images.enumerated()), id: \.element.id) { index, image in
                        let ratio = image.aspectRatio ?? CodeAgentsUIMediaImageView.fallbackAspectRatio
                        let pixelSize = Int(max(thumbnailHeight, thumbnailHeight * ratio) * UIScreen.main.scale)
                        CodeAgentsUIMediaImageView(
                            source: image.source,
                            project: project,
                            aspectRatio: image.aspectRatio,
                            maxPixelSize: max(1, pixelSize)
                        )
                        .frame(width: thumbnailHeight * ratio, height: thumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openPreview(startIndex: index)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if let caption = gallery.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(item: $previewPayload) { payload in
            CodeAgentsUIMediaPreviewController(urls: payload.urls, startIndex: payload.startIndex)
        }
    }

    private func openPreview(startIndex: Int) {
        guard !isPreparingPreview else { return }
        isPreparingPreview = true
        Task {
            let project = project ?? ProjectContext.shared.activeProject
            let sources = gallery.images.map { $0.source }
            var resolved: [URL] = []
            resolved.reserveCapacity(sources.count)
            var indexMap: [Int: Int] = [:]
            for (idx, source) in sources.enumerated() {
                if let url = await ChatMediaLoader.shared.preparePreviewURL(for: source, project: project) {
                    if fileURLExists(url) {
                        indexMap[idx] = resolved.count
                        resolved.append(url)
                    }
                }
            }

            await MainActor.run {
                if let mappedIndex = indexMap[startIndex], !resolved.isEmpty {
                    previewPayload = CodeAgentsUIMediaPreviewPayload(urls: resolved, startIndex: mappedIndex)
                }
                isPreparingPreview = false
            }
        }
    }
}

struct CodeAgentsUIVideoView: View {
    let video: CodeAgentsUIVideo
    let project: RemoteProject?
    @State private var previewPayload: CodeAgentsUIMediaPreviewPayload?
    @State private var isPreparingPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CodeAgentsUIMediaVideoView(source: video.source, poster: video.poster, project: project)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let caption = video.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openPreview()
        }
        .sheet(item: $previewPayload) { payload in
            CodeAgentsUIMediaPreviewController(urls: payload.urls, startIndex: payload.startIndex)
        }
    }

    private func openPreview() {
        guard !isPreparingPreview else { return }
        isPreparingPreview = true
        Task {
            let project = project ?? ProjectContext.shared.activeProject
            let urls = await ChatMediaLoader.shared.preparePreviewItems(sources: [video.source], project: project)
            let existing = urls.filter { fileURLExists($0) }
            await MainActor.run {
                if let first = existing.first {
                    previewPayload = CodeAgentsUIMediaPreviewPayload(urls: [first], startIndex: 0)
                }
                isPreparingPreview = false
            }
        }
    }
}

fileprivate func fileURLExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
}

fileprivate extension CodeAgentsUIMediaResolved {
    var cacheKeyURL: URL {
        switch self {
        case .remote(let url):
            return url
        case .local(let url):
            return url
        }
    }
}

struct CodeAgentsUIMediaImageView: View {
    static let fallbackAspectRatio: Double = 4.0 / 3.0

    let source: CodeAgentsUIMediaSource
    let project: RemoteProject?
    let aspectRatio: Double?
    let maxPixelSize: Int?

    @State private var resolved: CodeAgentsUIMediaResolved?
    @State private var didFail = false
    @State private var resolvedImage: UIImage?
    @State private var resolvedAspectRatio: Double?

    init(
        source: CodeAgentsUIMediaSource,
        project: RemoteProject?,
        aspectRatio: Double?,
        maxPixelSize: Int? = nil
    ) {
        self.source = source
        self.project = project
        self.aspectRatio = aspectRatio
        self.maxPixelSize = maxPixelSize

        let resolvedProject = project ?? ProjectContext.shared.activeProject
        let cachedResolved = ChatMediaLoader.shared.cachedResolvedMedia(source, project: resolvedProject)
        _resolved = State(initialValue: cachedResolved)

        let cachedRatio: Double? = {
            guard aspectRatio == nil else { return nil }
            return ChatMediaLoader.shared.cachedAspectRatio(source, project: resolvedProject)
        }()
        _resolvedAspectRatio = State(initialValue: cachedRatio)

        if let cachedResolved,
           let cachedImage = CodeAgentsUIMediaImageCache.shared.image(for: cachedResolved.cacheKeyURL) {
            _resolvedImage = State(initialValue: cachedImage)
            if aspectRatio == nil, cachedRatio == nil, cachedImage.size.width > 0 {
                _resolvedAspectRatio = State(initialValue: cachedImage.size.width / cachedImage.size.height)
            }
        }
    }

    var body: some View {
        ZStack {
            if let resolvedImage {
                formattedImage(Image(uiImage: resolvedImage).resizable())
            } else if didFail {
                EmptyView()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGray6).opacity(0.25))
        .aspectRatio(currentAspectRatio, contentMode: .fit)
        .transaction { transaction in
            transaction.animation = nil
        }
        .task {
            guard resolved == nil, !didFail else { return }
            let resolved = await ChatMediaLoader.shared.resolveMedia(source, project: project ?? ProjectContext.shared.activeProject)
            if let resolved {
                self.resolved = resolved
                if aspectRatio == nil, resolvedAspectRatio == nil {
                    resolvedAspectRatio = ChatMediaLoader.shared.cachedAspectRatio(
                        source,
                        project: project ?? ProjectContext.shared.activeProject
                    )
                }
            } else {
                didFail = true
            }
        }
        .task(id: mediaTaskId) {
            guard let resolved else { return }

            if aspectRatio == nil, resolvedAspectRatio == nil {
                resolvedAspectRatio = ChatMediaLoader.shared.cachedAspectRatio(
                    source,
                    project: project ?? ProjectContext.shared.activeProject
                )
            }

            if resolvedImage != nil {
                return
            }

            if let cached = CodeAgentsUIMediaImageCache.shared.image(for: resolved.cacheKeyURL) {
                resolvedImage = cached
                if aspectRatio == nil {
                    resolvedAspectRatio = cached.size.width > 0 ? cached.size.width / cached.size.height : nil
                }
                return
            }

            let loaded: UIImage?
            switch resolved {
            case .local(let url):
                loaded = await loadLocalImage(url: url, maxPixelSize: effectiveMaxPixelSize)
            case .remote(let url):
                loaded = await loadRemoteImage(url: url, maxPixelSize: effectiveMaxPixelSize)
            }

            if let loaded {
                CodeAgentsUIMediaImageCache.shared.store(loaded, for: resolved.cacheKeyURL)
                resolvedImage = loaded
                if aspectRatio == nil {
                    resolvedAspectRatio = loaded.size.width > 0 ? loaded.size.width / loaded.size.height : nil
                }
            } else {
                didFail = true
            }
        }
    }

    private func formattedImage(_ image: Image) -> some View {
        AnyView(
            image
                .scaledToFit()
                .frame(maxWidth: .infinity)
        )
    }

    private var currentAspectRatio: Double {
        let ratio = aspectRatio ?? resolvedAspectRatio ?? Self.fallbackAspectRatio
        if ratio > 0 {
            return ratio
        }
        return Self.fallbackAspectRatio
    }

    private var mediaTaskId: String {
        resolved?.cacheKeyURL.absoluteString ?? ""
    }

    private var effectiveMaxPixelSize: Int {
        if let maxPixelSize {
            return maxPixelSize
        }
        let bubbleWidth = UIScreen.main.bounds.width * 0.78
        let paddedWidth = max(0, bubbleWidth - 32)
        return max(1, Int(paddedWidth * UIScreen.main.scale))
    }

    private func loadLocalImage(url: URL, maxPixelSize: Int) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let (image, _) = downsampleImage(from: url, maxPixelSize: maxPixelSize) else {
                    continuation.resume(returning: UIImage(contentsOfFile: url.path))
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func loadRemoteImage(url: URL, maxPixelSize: Int) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let mimeType = response.mimeType, !mimeType.hasPrefix("image/") {
                return nil
            }
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if let (image, _) = downsampleImage(from: data, maxPixelSize: maxPixelSize) {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(returning: UIImage(data: data))
                    }
                }
            }
        } catch {
            return nil
        }
    }
}

fileprivate func downsampleImage(from url: URL, maxPixelSize: Int) -> (UIImage, Double?)? {
    let options: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldCacheImmediately: false
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
    return downsampleImage(from: source, maxPixelSize: maxPixelSize)
}

fileprivate func downsampleImage(from data: Data, maxPixelSize: Int) -> (UIImage, Double?)? {
    let options: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceShouldCacheImmediately: false
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
    return downsampleImage(from: source, maxPixelSize: maxPixelSize)
}

fileprivate func downsampleImage(from source: CGImageSource, maxPixelSize: Int) -> (UIImage, Double?)? {
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Double
    let height = properties?[kCGImagePropertyPixelHeight] as? Double
    let ratio: Double? = {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return width / height
    }()

    let clampedMaxPixelSize = max(1, maxPixelSize)
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: clampedMaxPixelSize,
        kCGImageSourceShouldCacheImmediately: true
    ]

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        return nil
    }

    return (UIImage(cgImage: cgImage), ratio)
}

struct CodeAgentsUIMediaVideoView: View {
    let source: CodeAgentsUIMediaSource
    let poster: CodeAgentsUIMediaSource?
    let project: RemoteProject?

    @State private var resolved: CodeAgentsUIMediaResolved?
    @State private var didFail = false

    var body: some View {
        Group {
            if let resolved {
                videoView(for: resolved)
            } else if didFail {
                EmptyView()
            } else if let poster {
                CodeAgentsUIMediaImageView(source: poster, project: project, aspectRatio: nil)
            } else {
                ProgressView()
            }
        }
        .task {
            guard resolved == nil, !didFail else { return }
            let resolved = await ChatMediaLoader.shared.resolveMedia(source, project: project ?? ProjectContext.shared.activeProject)
            if let resolved {
                self.resolved = resolved
            } else {
                didFail = true
            }
        }
    }

    private func videoView(for resolved: CodeAgentsUIMediaResolved) -> some View {
        switch resolved {
        case .remote(let url):
            return VideoPlayer(player: AVPlayer(url: url))
        case .local(let url):
            return VideoPlayer(player: AVPlayer(url: url))
        }
    }
}
