//
//  MediaUploadStager.swift
//  CodeAgentsMobile
//
//  Purpose: Stage images and videos for file-browser upload with human names.
//

import Foundation
import UniformTypeIdentifiers

struct StagedUploadItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case image
        case video
        case file
    }

    let id: UUID
    let displayName: String
    let localURL: URL
    let kind: Kind

    init(displayName: String, localURL: URL, kind: Kind, id: UUID = UUID()) {
        self.id = id
        self.displayName = displayName
        self.localURL = localURL
        self.kind = kind
    }
}

enum MediaUploadStager {
    static func stageVideoFile(
        at url: URL,
        preferredName: String?,
        directoryName: String
    ) throws -> StagedUploadItem {
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension.lowercased()
        let displayName = UploadFilename.humanDisplayName(
            preferred: preferredName ?? url.lastPathComponent,
            fallbackStem: "Video",
            preferredExtension: ext
        )
        let destination = try copyToStaging(
            from: url,
            directoryName: directoryName,
            filename: displayName
        )
        return StagedUploadItem(displayName: displayName, localURL: destination, kind: .video)
    }

    static func stageGenericFile(
        at url: URL,
        directoryName: String
    ) throws -> StagedUploadItem {
        let original = url.lastPathComponent
        let ext = url.pathExtension
        let displayName: String
        if UploadFilename.isLikelyAssetIdentifier(original) {
            displayName = UploadFilename.humanDisplayName(
                preferred: nil,
                fallbackStem: "File",
                preferredExtension: ext
            )
        } else {
            displayName = original.isEmpty
                ? UploadFilename.humanDisplayName(preferred: nil, fallbackStem: "File", preferredExtension: ext)
                : original
        }

        let destination = try copyToStaging(
            from: url,
            directoryName: directoryName,
            filename: displayName
        )
        return StagedUploadItem(
            displayName: displayName,
            localURL: destination,
            kind: kind(forExtension: (displayName as NSString).pathExtension)
        )
    }

    static func kind(forExtension ext: String) -> StagedUploadItem.Kind {
        let lower = ext.lowercased()
        if FileNode.imageFileExtensions.contains(lower) { return .image }
        if FileNode.videoFileExtensions.contains(lower) { return .video }
        return .file
    }

    private static func copyToStaging(
        from url: URL,
        directoryName: String,
        filename: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let stagingDir = base.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let safe = UploadFilename.sanitizeStem((filename as NSString).deletingPathExtension)
        let ext = (filename as NSString).pathExtension
        let finalName = (safe.isEmpty ? "file" : safe) + (ext.isEmpty ? "" : ".\(ext)")
        let destination = stagingDir.appendingPathComponent("\(UUID().uuidString)-\(finalName)")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)
        return destination
    }
}
