//
//  CodeAgentsUIMediaPreviewController.swift
//  CodeAgentsMobile
//
//  Purpose: QuickLook preview for codeagents_ui media.
//

import SwiftUI
import QuickLook

struct CodeAgentsUIMediaPreviewController: UIViewControllerRepresentable {
    let urls: [URL]
    let startIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls, startIndex: startIndex)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        let index = min(max(startIndex, 0), max(0, urls.count - 1))
        controller.currentPreviewItemIndex = index
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.urls = urls
        context.coordinator.startIndex = startIndex
        controller.reloadData()
        let index = min(max(startIndex, 0), max(0, urls.count - 1))
        controller.currentPreviewItemIndex = index
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var urls: [URL]
        var startIndex: Int

        init(urls: [URL], startIndex: Int) {
            self.urls = urls
            self.startIndex = startIndex
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            urls.count
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}
