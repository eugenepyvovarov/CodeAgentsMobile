//
//  CodeAgentsUIMediaViews.swift
//  CodeAgentsMobile
//
//  Purpose: Image, gallery, and video widgets for codeagents_ui blocks
//

import SwiftUI
import AVFoundation
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
    // MARK: - Inputs

    let video: CodeAgentsUIVideo
    let project: RemoteProject?

    // MARK: - State

    @State private var previewPayload: CodeAgentsUIMediaPreviewPayload?
    @State private var isPreparingPreview = false

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CodeAgentsUIMediaVideoView(source: video.source, poster: video.poster, project: project)
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)

            if let caption = video.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openPreview()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Plays video")
        .sheet(item: $previewPayload) { payload in
            CodeAgentsUIMediaPreviewController(urls: payload.urls, startIndex: payload.startIndex)
        }
    }

    // MARK: - Helpers

    private var accessibilityLabel: String {
        if let caption = video.caption, !caption.isEmpty {
            return "Video, \(caption)"
        }
        return "Video"
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

// MARK: - Inline video poster (no live VideoPlayer in bubble)

/// Caches first-frame posters extracted from local/remote video URLs (memory + disk).
actor ChatVideoPosterCache {
    static let shared = ChatVideoPosterCache()

    private let imageCache = NSCache<NSString, UIImage>()
    private var durationCache: [String: TimeInterval] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        imageCache.countLimit = 80
        imageCache.totalCostLimit = 40 * 1024 * 1024
    }

    func cachedPoster(for url: URL) -> UIImage? {
        let key = cacheKey(url)
        if let memory = imageCache.object(forKey: key as NSString) {
            return memory
        }
        if let disk = loadDiskPoster(forKey: key) {
            storeInMemory(disk, key: key)
            return disk
        }
        return nil
    }

    func cachedDuration(for url: URL) -> TimeInterval? {
        durationCache[cacheKey(url)]
    }

    func poster(for url: URL, maxPixelSize: CGFloat = 720) async -> UIImage? {
        let key = cacheKey(url)
        if let cached = imageCache.object(forKey: key as NSString) {
            return cached
        }
        if let disk = loadDiskPoster(forKey: key) {
            storeInMemory(disk, key: key)
            return disk
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            await Self.generatePoster(url: url, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            storeInMemory(image, key: key)
            persistPoster(image, forKey: key)
        }
        return image
    }

    func duration(for url: URL) async -> TimeInterval? {
        let key = cacheKey(url)
        if let cached = durationCache[key] {
            return cached
        }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            durationCache[key] = seconds
            return seconds
        } catch {
            return nil
        }
    }

    private func cacheKey(_ url: URL) -> String {
        if url.isFileURL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize.map(String.init) ?? "0"
            let mtime = values?.contentModificationDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            return "video-poster:\(url.path)|\(size)|\(mtime)"
        }
        return "video-poster:\(url.absoluteString)"
    }

    private func storeInMemory(_ image: UIImage, key: String) {
        let cost = max(1, Int(image.size.width * image.scale * image.size.height * image.scale * 4))
        imageCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func loadDiskPoster(forKey key: String) -> UIImage? {
        guard let url = ChatMediaDiskCache.existingFile(forKey: key, pathExtension: "jpg") else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    private func persistPoster(_ image: UIImage, forKey key: String) {
        guard let data = image.jpegData(compressionQuality: 0.82) else { return }
        _ = try? ChatMediaDiskCache.storeData(data, forKey: key, pathExtension: "jpg")
    }

    private static func generatePoster(url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Slightly after zero to avoid pure-black first frames on some encodes.
        let times: [CMTime] = [
            CMTime(seconds: 0.15, preferredTimescale: 600),
            CMTime(seconds: 0.0, preferredTimescale: 600),
            CMTime(seconds: 1.0, preferredTimescale: 600)
        ]

        for time in times {
            if let image = await generateImage(generator: generator, at: time) {
                return image
            }
        }
        return nil
    }

    private static func generateImage(generator: AVAssetImageGenerator, at time: CMTime) async -> UIImage? {
        await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, result, _ in
                if result == .succeeded, let cgImage {
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

struct CodeAgentsUIMediaVideoView: View {
    // MARK: - Inputs

    let source: CodeAgentsUIMediaSource
    let poster: CodeAgentsUIMediaSource?
    let project: RemoteProject?

    // MARK: - State

    @State private var resolvedVideo: CodeAgentsUIMediaResolved?
    @State private var posterImage: UIImage?
    @State private var durationSeconds: TimeInterval?
    @State private var isLoading = true
    @State private var didFail = false

    // MARK: - Body

    var body: some View {
        ZStack {
            posterLayer
            scrimGradient
            playButton
            if let durationSeconds {
                durationBadge(seconds: durationSeconds)
            }
            if isLoading && posterImage == nil {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
            }
        }
        .background(Color.black.opacity(0.12))
        .task(id: taskID) {
            await loadPosterAndMetadata()
        }
    }

    // MARK: - Layers

    @ViewBuilder
    private var posterLayer: some View {
        if let posterImage {
            Image(uiImage: posterImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .transition(.opacity)
        } else if didFail {
            failedPlaceholder
        } else {
            // Soft gradient while resolving — never show live VideoPlayer chrome.
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.18, blue: 0.24),
                        Color(red: 0.08, green: 0.09, blue: 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "film")
                    .font(.system(size: 28, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var scrimGradient: some View {
        LinearGradient(
            colors: [
                .black.opacity(0.05),
                .black.opacity(0.0),
                .black.opacity(0.35)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    private var playButton: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.leading, 3) // optical center for play triangle
            .frame(width: 56, height: 56)
            .modifier(ChatVideoPlayGlassModifier())
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .accessibilityHidden(true)
    }

    private func durationBadge(seconds: TimeInterval) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(Self.formatDuration(seconds))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .modifier(ChatVideoDurationGlassModifier())
                    .padding(10)
            }
        }
        .allowsHitTesting(false)
    }

    private var failedPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Video unavailable")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemFill))
    }

    // MARK: - Loading

    private var taskID: String {
        "\(sourceStableID)|\(posterStableID)|\(project?.id.uuidString ?? "none")"
    }

    private var sourceStableID: String {
        switch source {
        case .projectFile(let path):
            return "project:\(path)"
        case .url(let url):
            return "url:\(url.absoluteString)"
        case .base64(let mediaType, let data):
            return "b64:\(mediaType):\(data.count)"
        }
    }

    private var posterStableID: String {
        guard let poster else { return "nil" }
        switch poster {
        case .projectFile(let path):
            return "project:\(path)"
        case .url(let url):
            return "url:\(url.absoluteString)"
        case .base64(let mediaType, let data):
            return "b64:\(mediaType):\(data.count)"
        }
    }

    private func loadPosterAndMetadata() async {
        isLoading = true
        didFail = false

        let activeProject = project ?? ProjectContext.shared.activeProject

        // 1) Explicit poster from the widget (if any).
        if posterImage == nil, let poster {
            if let resolvedPoster = await ChatMediaLoader.shared.resolveMedia(poster, project: activeProject) {
                if let image = await loadImage(from: resolvedPoster) {
                    posterImage = image
                }
            }
        }

        // 2) Resolve the video itself for frame extraction + duration + tap-to-play.
        let videoResolved = await ChatMediaLoader.shared.resolveMedia(source, project: activeProject)
        guard let videoResolved else {
            if posterImage == nil {
                didFail = true
            }
            isLoading = false
            return
        }
        resolvedVideo = videoResolved

        let videoURL = videoURL(for: videoResolved)

        if let videoURL {
            if posterImage == nil {
                if let cached = await ChatVideoPosterCache.shared.cachedPoster(for: videoURL) {
                    posterImage = cached
                } else if let generated = await ChatVideoPosterCache.shared.poster(for: videoURL) {
                    posterImage = generated
                }
            }

            if let cachedDuration = await ChatVideoPosterCache.shared.cachedDuration(for: videoURL) {
                durationSeconds = cachedDuration
            } else if let duration = await ChatVideoPosterCache.shared.duration(for: videoURL) {
                durationSeconds = duration
            }
        }

        if posterImage == nil {
            // Keep a calm placeholder rather than broken AVPlayer chrome.
            didFail = videoURL == nil
        }
        isLoading = false
    }

    private func videoURL(for resolved: CodeAgentsUIMediaResolved) -> URL? {
        switch resolved {
        case .local(let url), .remote(let url):
            return url
        }
    }

    private func loadImage(from resolved: CodeAgentsUIMediaResolved) async -> UIImage? {
        switch resolved {
        case .local(let url):
            if let cached = CodeAgentsUIMediaImageCache.shared.image(for: url) {
                return cached
            }
            let image = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: UIImage(contentsOfFile: url.path))
                }
            }
            if let image {
                CodeAgentsUIMediaImageCache.shared.store(image, for: url)
            }
            return image
        case .remote(let url):
            if let cached = CodeAgentsUIMediaImageCache.shared.image(for: url) {
                return cached
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let mimeType = response.mimeType, !mimeType.hasPrefix("image/") {
                    return nil
                }
                guard let image = UIImage(data: data) else { return nil }
                CodeAgentsUIMediaImageCache.shared.store(image, for: url)
                return image
            } catch {
                return nil
            }
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Glass chrome for video controls

private struct ChatVideoPlayGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(.white.opacity(0.18)).interactive(), in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
                }
        }
    }
}

private struct ChatVideoDurationGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                }
        }
    }
}
