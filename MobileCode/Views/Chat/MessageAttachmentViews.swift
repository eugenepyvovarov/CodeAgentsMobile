//
//  MessageAttachmentViews.swift
//  CodeAgentsMobile
//
//  Purpose: Quiet attachment previews + light upload status for chat bubbles.
//

import SwiftUI
import UIKit

// MARK: - Attachment strip

struct MessageAttachmentsStrip: View {
    let attachments: [ChatMessageAttachment]
    let isUser: Bool

    var body: some View {
        if attachments.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                ForEach(attachments) { attachment in
                    MessageAttachmentCard(attachment: attachment, isUser: isUser)
                }
            }
        }
    }
}

// MARK: - Single attachment card

private struct MessageAttachmentCard: View {
    let attachment: ChatMessageAttachment
    let isUser: Bool

    @State private var previewPayload: CodeAgentsUIMediaPreviewPayload?
    @State private var fullscreenPayload: FullscreenImagePayload?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            preview
                .frame(width: 148, height: 148)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture {
                    openPreview()
                }

            if showsStatusBadge {
                MessageAttachmentStatusBadge(status: attachment.uploadStatus)
                    .padding(6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(canPreview ? "Shows full size" : "")
        .sheet(item: $previewPayload) { payload in
            CodeAgentsUIMediaPreviewController(urls: payload.urls, startIndex: payload.startIndex)
        }
        .fullScreenCover(item: $fullscreenPayload) { payload in
            MessageAttachmentFullscreenImageView(image: payload.image)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if attachment.isImage, let image = loadedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            filePlaceholder
        }
    }

    private var filePlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .font(.title2.weight(.medium))
                .foregroundStyle(isUser ? Color.white.opacity(0.9) : Color.secondary)
            Text(attachment.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isUser ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(placeholderBackground)
    }

    private var loadedImage: UIImage? {
        guard let path = attachment.localPath, !path.isEmpty else { return nil }
        return UIImage(contentsOfFile: path)
    }

    private var localFileURL: URL? {
        guard let path = attachment.localPath, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var canPreview: Bool {
        localFileURL != nil || loadedImage != nil
    }

    /// Only surface in-progress / failure — success is silent.
    private var showsStatusBadge: Bool {
        switch attachment.uploadStatus {
        case .uploading, .failed:
            return true
        case .pending, .uploaded:
            return false
        }
    }

    private var placeholderBackground: Color {
        isUser ? Color.white.opacity(0.16) : Color(.secondarySystemFill)
    }

    private var borderColor: Color {
        if attachment.uploadStatus == .failed {
            return Color.orange.opacity(0.55)
        }
        return isUser ? Color.white.opacity(0.22) : Color(.separator).opacity(0.35)
    }

    private var accessibilityLabel: String {
        switch attachment.uploadStatus {
        case .uploading:
            return "\(attachment.displayName), uploading"
        case .failed:
            return "\(attachment.displayName), upload failed"
        case .pending, .uploaded:
            return attachment.displayName
        }
    }

    private func openPreview() {
        if attachment.isImage, let image = loadedImage {
            fullscreenPayload = FullscreenImagePayload(image: image)
            return
        }
        if let url = localFileURL {
            previewPayload = CodeAgentsUIMediaPreviewPayload(urls: [url], startIndex: 0)
        }
    }
}

// MARK: - Fullscreen image

private struct FullscreenImagePayload: Identifiable {
    let id = UUID()
    let image: UIImage

    init(image: UIImage) {
        self.image = image
    }
}

private struct MessageAttachmentFullscreenImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(1, min(lastScale * value, 4))
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale < 1.05 {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    scale = 1
                                    lastScale = 1
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1.1 {
                            scale = 1
                            lastScale = 1
                        } else {
                            scale = 2.2
                            lastScale = 2.2
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityLabel("Close")
        }
    }
}

// MARK: - Light status badge

/// Only used for in-progress / failure — success is intentionally silent.
struct MessageAttachmentStatusBadge: View {
    let status: ChatMessageAttachmentUploadStatus

    var body: some View {
        Group {
            switch status {
            case .uploading:
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.black.opacity(0.4)))
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            case .pending, .uploaded:
                EmptyView()
            }
        }
        .accessibilityHidden(true)
    }
}
