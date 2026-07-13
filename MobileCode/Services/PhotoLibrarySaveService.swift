//
//  PhotoLibrarySaveService.swift
//  CodeAgentsMobile
//
//  Purpose: Save local image/video files into the system Photos library (add-only).
//

import Foundation
import Photos
import UniformTypeIdentifiers
import UIKit

enum PhotoLibrarySaveError: LocalizedError, Equatable {
    case fileMissing
    case unsupportedType
    case notAuthorized
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "The media file is no longer available."
        case .unsupportedType:
            return "This file type can’t be saved to Photos."
        case .notAuthorized:
            return "Photos access was denied. Enable “Add Photos Only” for Code Agents in Settings."
        case .saveFailed(let message):
            return message
        }
    }
}

enum PhotoLibraryMediaKind: Equatable {
    case image
    case video
}

/// Saves local media into the user’s Photos library using add-only authorization.
enum PhotoLibrarySaveService {
    /// Returns whether `url` looks like an image or video Photos can accept.
    static func mediaKind(for url: URL) -> PhotoLibraryMediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return .image
        }
        if videoExtensions.contains(ext) {
            return .video
        }

        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) {
                return .image
            }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                return .video
            }
            // Some containers report as audiovisual without pure audio.
            if type.conforms(to: .audiovisualContent), !type.conforms(to: .audio) {
                return .video
            }
        }
        return nil
    }

    static func canSaveToPhotos(url: URL) -> Bool {
        mediaKind(for: url) != nil
    }

    /// Save a local file URL into Photos. Requests add-only permission if needed.
    static func saveFile(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PhotoLibrarySaveError.fileMissing
        }
        guard let kind = mediaKind(for: url) else {
            throw PhotoLibrarySaveError.unsupportedType
        }

        try await requestAddOnlyAccess()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                switch kind {
                case .image:
                    // Prefer UIImage when possible (broader decoder path), else file URL.
                    if let image = UIImage(contentsOfFile: url.path) {
                        PHAssetChangeRequest.creationRequestForAsset(from: image)
                    } else {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    }
                case .video:
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }
        } catch {
            throw PhotoLibrarySaveError.saveFailed(error.localizedDescription)
        }
    }

    /// Save an in-memory image (e.g. attachment fullscreen preview).
    static func saveImage(_ image: UIImage) async throws {
        try await requestAddOnlyAccess()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        } catch {
            throw PhotoLibrarySaveError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mpg", "mpeg", "hevc"
    ]

    private static func requestAddOnlyAccess() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            return
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                throw PhotoLibrarySaveError.notAuthorized
            }
        case .denied, .restricted:
            throw PhotoLibrarySaveError.notAuthorized
        @unknown default:
            throw PhotoLibrarySaveError.notAuthorized
        }
    }
}
