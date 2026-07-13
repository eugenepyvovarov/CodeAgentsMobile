//
//  PhotoLibraryPicker.swift
//  CodeAgentsMobile
//
//  Purpose: PHPicker wrapper for multi-select image/video picking.
//  Uses only PHPicker + NSItemProvider — no PHAsset / Photos library permission.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    enum MediaFilter {
        case images
        case videos
        case imagesAndVideos
    }

    let selectionLimit: Int
    let directoryName: String
    var mediaFilter: MediaFilter = .images
    /// Legacy image-only callback used by chat/tasks.
    var onComplete: (([StagedImageAttachment], Error?) -> Void)?
    /// File-browser callback that supports images + videos.
    var onUploadItems: (([StagedUploadItem], Error?) -> Void)?
    let onCancel: () -> Void

    init(
        selectionLimit: Int,
        directoryName: String,
        mediaFilter: MediaFilter = .images,
        onComplete: (([StagedImageAttachment], Error?) -> Void)? = nil,
        onUploadItems: (([StagedUploadItem], Error?) -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.selectionLimit = selectionLimit
        self.directoryName = directoryName
        self.mediaFilter = mediaFilter
        self.onComplete = onComplete
        self.onUploadItems = onUploadItems
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // Do NOT pass `.shared()` photo library — that enables asset identifiers and
        // invites PHAsset access, which requires NSPhotoLibraryUsageDescription.
        var configuration = PHPickerConfiguration()
        switch mediaFilter {
        case .images:
            configuration.filter = .images
        case .videos:
            configuration.filter = .videos
        case .imagesAndVideos:
            configuration.filter = .any(of: [.images, .videos])
        }
        configuration.selectionLimit = selectionLimit
        // Prefer current representation; still fully usable without library permission.
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoLibraryPicker

        init(_ parent: PhotoLibraryPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }

            Task {
                var images: [StagedImageAttachment] = []
                var uploads: [StagedUploadItem] = []
                var firstError: Error?

                for result in results {
                    do {
                        let item = try await stage(result)
                        uploads.append(item)
                        if item.kind == .image {
                            images.append(
                                StagedImageAttachment(
                                    displayName: item.displayName,
                                    localURL: item.localURL
                                )
                            )
                        }
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }

                await MainActor.run {
                    if let onUploadItems = parent.onUploadItems {
                        onUploadItems(uploads, firstError)
                    } else {
                        parent.onComplete?(images, firstError)
                    }
                }
            }
        }

        private func stage(_ result: PHPickerResult) async throws -> StagedUploadItem {
            // Only use NSItemProvider metadata — never PHAsset (TCC crash without usage string).
            let preferredName = preferredFilename(from: result.itemProvider)

            if isVideo(result.itemProvider) {
                let videoTypes = [
                    UTType.movie.identifier,
                    UTType.video.identifier,
                    UTType.mpeg4Movie.identifier,
                    UTType.quickTimeMovie.identifier
                ]
                var videoURL: URL?
                for typeId in videoTypes {
                    if let url = try await loadFileURL(from: result.itemProvider, typeIdentifier: typeId) {
                        videoURL = url
                        break
                    }
                }

                if let url = videoURL {
                    defer { try? FileManager.default.removeItem(at: url) }
                    return try MediaUploadStager.stageVideoFile(
                        at: url,
                        preferredName: preferredName ?? url.lastPathComponent,
                        directoryName: parent.directoryName
                    )
                }
                throw ImageAttachmentStagerError.missingImageData
            }

            // Image path — reuse JPEG stager for size normalization.
            if let url = try await loadFileURL(
                from: result.itemProvider,
                typeIdentifier: UTType.image.identifier
            ) {
                defer { try? FileManager.default.removeItem(at: url) }
                let staged = try ImageAttachmentStager.stageImage(
                    at: url,
                    preferredName: preferredName ?? url.lastPathComponent,
                    directoryName: parent.directoryName
                )
                return StagedUploadItem(
                    displayName: staged.displayName,
                    localURL: staged.localURL,
                    kind: .image
                )
            }

            if let image = try await loadUIImage(from: result.itemProvider) {
                let staged = try ImageAttachmentStager.stageImage(
                    from: image,
                    preferredName: preferredName,
                    directoryName: parent.directoryName
                )
                return StagedUploadItem(
                    displayName: staged.displayName,
                    localURL: staged.localURL,
                    kind: .image
                )
            }

            throw ImageAttachmentStagerError.missingImageData
        }

        private func preferredFilename(from provider: NSItemProvider) -> String? {
            if let suggested = provider.suggestedName,
               !UploadFilename.isLikelyAssetIdentifier(suggested) {
                return suggested
            }
            return nil
        }

        private func isVideo(_ provider: NSItemProvider) -> Bool {
            provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.mpeg4Movie.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.quickTimeMovie.identifier)
        }

        private func loadFileURL(from provider: NSItemProvider, typeIdentifier: String) async throws -> URL? {
            guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else {
                return nil
            }

            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }

                    do {
                        let fileManager = FileManager.default
                        let stagingDir = fileManager.temporaryDirectory
                            .appendingPathComponent("photo-library-imports", isDirectory: true)
                        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)

                        let name = url.lastPathComponent.isEmpty ? "media" : url.lastPathComponent
                        let destination = stagingDir.appendingPathComponent("\(UUID().uuidString)-\(name)")
                        if fileManager.fileExists(atPath: destination.path) {
                            try fileManager.removeItem(at: destination)
                        }
                        try fileManager.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func loadUIImage(from provider: NSItemProvider) async throws -> UIImage? {
            if provider.canLoadObject(ofClass: UIImage.self) {
                return try await withCheckedThrowingContinuation { continuation in
                    provider.loadObject(ofClass: UIImage.self) { object, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        continuation.resume(returning: object as? UIImage)
                    }
                }
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let data: Data? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                        if let error {
                            continuation.resume(throwing: error)
                            return
                        }
                        continuation.resume(returning: data)
                    }
                }
                if let data {
                    return UIImage(data: data)
                }
            }

            return nil
        }
    }
}
