//
//  CodeAgentsUIMediaPreviewController.swift
//  CodeAgentsMobile
//
//  Purpose: QuickLook preview sheet for chat media with Close / Share chrome.
//

import SwiftUI
import QuickLook
import UIKit

/// Sheet used by chat image/gallery/video/attachment previews.
/// Matches the Files viewer toolbar: Close (leading) + Share (trailing).
struct CodeAgentsUIMediaPreviewController: View {
    // MARK: - Inputs

    let urls: [URL]
    let startIndex: Int

    // MARK: - Environment / state

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int

    // MARK: - Init

    init(urls: [URL], startIndex: Int) {
        self.urls = urls
        self.startIndex = startIndex
        let clamped = urls.isEmpty
            ? 0
            : min(max(startIndex, 0), urls.count - 1)
        _currentIndex = State(initialValue: clamped)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if urls.isEmpty {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "eye.slash",
                        description: Text("No file to preview.")
                    )
                } else {
                    CodeAgentsUIQuickLookRepresentable(
                        urls: urls,
                        currentIndex: $currentIndex
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        shareCurrentItem()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(urls.isEmpty || !fileExists(at: currentURL))
                    .accessibilityLabel("Share")
                }
            }
        }
    }

    // MARK: - Helpers

    private var navigationTitle: String {
        guard let url = currentURL else { return "Preview" }
        let name = url.lastPathComponent
        return name.isEmpty ? "Preview" : name
    }

    private var currentURL: URL? {
        guard !urls.isEmpty, currentIndex >= 0, currentIndex < urls.count else {
            return urls.first
        }
        return urls[currentIndex]
    }

    private func fileExists(at url: URL?) -> Bool {
        guard let url else { return false }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    private func shareCurrentItem() {
        guard let url = currentURL, fileExists(at: url) else { return }
        ShareSheetPresenter.present(urls: [url])
    }
}

// MARK: - Quick Look bridge

private struct CodeAgentsUIQuickLookRepresentable: UIViewControllerRepresentable {
    let urls: [URL]
    @Binding var currentIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls, currentIndex: $currentIndex)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        let index = Self.clampedIndex(for: urls, preferred: currentIndex)
        controller.currentPreviewItemIndex = index
        context.coordinator.attach(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        let urlsChanged = context.coordinator.urls.map(\.path) != urls.map(\.path)
        context.coordinator.urls = urls
        context.coordinator.currentIndex = $currentIndex

        if urlsChanged {
            controller.reloadData()
            let index = Self.clampedIndex(for: urls, preferred: currentIndex)
            controller.currentPreviewItemIndex = index
        }
    }

    static func dismantleUIViewController(_ controller: QLPreviewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    private static func clampedIndex(for urls: [URL], preferred: Int) -> Int {
        guard !urls.isEmpty else { return 0 }
        return min(max(preferred, 0), urls.count - 1)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var urls: [URL]
        var currentIndex: Binding<Int>
        private weak var previewController: QLPreviewController?
        private var isObservingIndex = false

        init(urls: [URL], currentIndex: Binding<Int>) {
            self.urls = urls
            self.currentIndex = currentIndex
        }

        deinit {
            detach()
        }

        func attach(to controller: QLPreviewController) {
            detach()
            previewController = controller
            controller.addObserver(
                self,
                forKeyPath: #keyPath(QLPreviewController.currentPreviewItemIndex),
                options: [.new],
                context: nil
            )
            isObservingIndex = true
            syncIndex(from: controller)
        }

        func detach() {
            guard isObservingIndex, let previewController else {
                isObservingIndex = false
                self.previewController = nil
                return
            }
            previewController.removeObserver(
                self,
                forKeyPath: #keyPath(QLPreviewController.currentPreviewItemIndex)
            )
            isObservingIndex = false
            self.previewController = nil
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            urls.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }

        func previewController(
            _ controller: QLPreviewController,
            editingModeFor previewItem: QLPreviewItem
        ) -> QLPreviewItemEditingMode {
            .disabled
        }

        override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard keyPath == #keyPath(QLPreviewController.currentPreviewItemIndex),
                  let controller = object as? QLPreviewController else {
                return
            }
            syncIndex(from: controller)
        }

        private func syncIndex(from controller: QLPreviewController) {
            let index = controller.currentPreviewItemIndex
            guard index >= 0, index < urls.count else { return }
            if currentIndex.wrappedValue != index {
                DispatchQueue.main.async {
                    self.currentIndex.wrappedValue = index
                }
            }
        }
    }
}
