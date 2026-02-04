//
//  PhotoLibraryPicker.swift
//  CodeAgentsMobile
//
//  Purpose: PHPicker wrapper for multi-select image picking.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    let directoryName: String
    let onComplete: ([StagedImageAttachment], Error?) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = selectionLimit

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
                var staged: [StagedImageAttachment] = []
                var firstError: Error?

                for result in results {
                    do {
                        let item = try await stage(result)
                        staged.append(item)
                    } catch {
                        if firstError == nil {
                            firstError = error
                        }
                    }
                }

                await MainActor.run {
                    parent.onComplete(staged, firstError)
                }
            }
        }

        private func stage(_ result: PHPickerResult) async throws -> StagedImageAttachment {
            let suggestedName = result.itemProvider.suggestedName
            if let url = try await loadFileURL(from: result.itemProvider) {
                defer { try? FileManager.default.removeItem(at: url) }
                return try ImageAttachmentStager.stageImage(
                    at: url,
                    preferredName: suggestedName ?? url.lastPathComponent,
                    directoryName: parent.directoryName
                )
            }

            if let image = try await loadUIImage(from: result.itemProvider) {
                return try ImageAttachmentStager.stageImage(
                    from: image,
                    preferredName: suggestedName,
                    directoryName: parent.directoryName
                )
            }

            throw ImageAttachmentStagerError.missingImageData
        }

        private func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else {
                return nil
            }

            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
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
                        let stagingDir = fileManager.temporaryDirectory.appendingPathComponent("photo-library-imports", isDirectory: true)
                        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)

                        let name = url.lastPathComponent.isEmpty ? "photo" : url.lastPathComponent
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
