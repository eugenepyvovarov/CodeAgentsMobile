//
//  ShareSheetPresenter.swift
//  CodeAgentsMobile
//
//  Purpose: Present the iOS share sheet for local file URLs
//

import UIKit

struct ShareSheetPresenter {
    static func present(urls: [URL], cleanup: (() -> Void)? = nil) {
        let activityController = UIActivityViewController(
            activityItems: urls,
            applicationActivities: nil
        )

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            var topController = rootViewController
            while let presented = topController.presentedViewController {
                topController = presented
            }

            activityController.completionWithItemsHandler = { _, _, _, _ in
                cleanup?()
            }

            topController.present(activityController, animated: true)
        }
    }
}
