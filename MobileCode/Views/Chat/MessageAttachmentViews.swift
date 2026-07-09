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
    var onRetryUpload: (() -> Void)? = nil

    var body: some View {
        if attachments.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                ForEach(attachments) { attachment in
                    MessageAttachmentCard(
                        attachment: attachment,
                        isUser: isUser,
                        onRetryUpload: canRetry(attachment) ? onRetryUpload : nil
                    )
                }
            }
        }
    }

    private func canRetry(_ attachment: ChatMessageAttachment) -> Bool {
        guard attachment.uploadStatus == .failed, attachment.remoteReference == nil else { return false }
        return ChatAttachmentLocalStore.resolveExistingFile(at: attachment.localPath) != nil
    }
}

// MARK: - Single attachment card

private struct MessageAttachmentCard: View {
    let attachment: ChatMessageAttachment
    let isUser: Bool
    var onRetryUpload: (() -> Void)? = nil

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

            statusOverlay
                .padding(6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(accessibilityHint)
        .sheet(item: $previewPayload) { payload in
            CodeAgentsUIMediaPreviewController(urls: payload.urls, startIndex: payload.startIndex)
        }
        .fullScreenCover(item: $fullscreenPayload) { payload in
            MessageAttachmentFullscreenImageView(image: payload.image)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch attachment.uploadStatus {
        case .uploading:
            MessageAttachmentStatusBadge(status: .uploading)
        case .failed:
            if let onRetryUpload {
                MessageAttachmentRetryChirp(action: onRetryUpload)
            } else {
                MessageAttachmentStatusBadge(status: .failed)
            }
        case .pending, .uploaded:
            EmptyView()
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
        guard let url = resolvedLocalURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private var resolvedLocalURL: URL? {
        ChatAttachmentLocalStore.resolveExistingFile(at: attachment.localPath)
    }

    private var canPreview: Bool {
        resolvedLocalURL != nil || loadedImage != nil
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
            if onRetryUpload != nil {
                return "\(attachment.displayName), upload failed, retry available"
            }
            return "\(attachment.displayName), upload failed"
        case .pending, .uploaded:
            return attachment.displayName
        }
    }

    private var accessibilityHint: String {
        if attachment.uploadStatus == .failed, onRetryUpload != nil {
            return "Retries upload"
        }
        return canPreview ? "Shows full size" : ""
    }

    private func openPreview() {
        if attachment.isImage, let image = loadedImage {
            fullscreenPayload = FullscreenImagePayload(image: image)
            return
        }
        if let url = resolvedLocalURL {
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

// MARK: - Light status badge / retry chirp

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

/// Small tappable chirp when a cached local file can be re-uploaded.
struct MessageAttachmentRetryChirp: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Retry?")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.orange.opacity(0.92))
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Retry upload")
    }
}
