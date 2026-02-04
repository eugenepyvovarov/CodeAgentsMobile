//
//  ImageAttachmentStager.swift
//  CodeAgentsMobile
//
//  Purpose: Normalize, resize, and stage image attachments as JPEG files.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

struct StagedImageAttachment {
    let displayName: String
    let localURL: URL
}

enum ImageAttachmentStagerError: LocalizedError {
    case missingImageData
    case invalidImageData
    case failedToEncode
    case failedToWrite

    var errorDescription: String? {
        switch self {
        case .missingImageData:
            return "Unable to load the selected image."
        case .invalidImageData:
            return "The selected image could not be decoded."
        case .failedToEncode:
            return "Failed to encode the image."
        case .failedToWrite:
            return "Failed to save the image locally."
        }
    }
}

struct ImageAttachmentStager {
    static let maxDimension: CGFloat = 2048
    static let jpegQuality: CGFloat = 0.85

    static func stageImage(
        from image: UIImage,
        preferredName: String?,
        directoryName: String
    ) throws -> StagedImageAttachment {
        let normalized = normalizedImage(image)
        let resized = resizedImage(normalized, maxDimension: maxDimension)
        guard let data = resized.jpegData(compressionQuality: jpegQuality) else {
            throw ImageAttachmentStagerError.failedToEncode
        }

        let displayName = resolvedDisplayName(from: preferredName)
        let safeName = sanitizedFilename(displayName)
        let destination = try makeDestinationURL(directoryName: directoryName, filename: safeName)

        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw ImageAttachmentStagerError.failedToWrite
        }

        return StagedImageAttachment(displayName: displayName, localURL: destination)
    }

    static func stageImage(
        at url: URL,
        preferredName: String?,
        directoryName: String
    ) throws -> StagedImageAttachment {
        if let image = UIImage(contentsOfFile: url.path) {
            return try stageImage(from: image, preferredName: preferredName ?? url.lastPathComponent, directoryName: directoryName)
        }

        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data) else {
            throw ImageAttachmentStagerError.invalidImageData
        }
        return try stageImage(from: image, preferredName: preferredName ?? url.lastPathComponent, directoryName: directoryName)
    }

    // MARK: - Private

    private static func normalizedImage(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return image
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func resizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let maxSide = max(pixelWidth, pixelHeight)
        guard maxSide > maxDimension else { return image }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: pixelWidth * scale, height: pixelHeight * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func resolvedDisplayName(from preferredName: String?) -> String {
        let trimmed = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (trimmed?.isEmpty == false ? trimmed : fallbackName()) ?? fallbackName()
        let baseName = (candidate as NSString).lastPathComponent
        let withoutExtension = (baseName as NSString).deletingPathExtension
        let finalBase = withoutExtension.isEmpty ? fallbackName() : withoutExtension
        return "\(finalBase).jpg"
    }

    private static func fallbackName() -> String {
        "Photo-\(timestampFormatter.string(from: Date()))"
    }

    private static func makeDestinationURL(directoryName: String, filename: String) throws -> URL {
        let fileManager = FileManager.default
        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let destination = stagingDir.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        return destination
    }

    private static func sanitizedFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "photo.jpg" }

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

        return collapsed.isEmpty ? "photo.jpg" : collapsed
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
