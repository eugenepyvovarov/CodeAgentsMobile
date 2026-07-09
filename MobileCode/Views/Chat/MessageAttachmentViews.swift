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

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            preview
                .frame(width: 148, height: 148)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.5)
                )

            MessageAttachmentStatusBadge(status: attachment.uploadStatus)
                .padding(6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
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

    private var placeholderBackground: Color {
        isUser ? Color.white.opacity(0.16) : Color(.secondarySystemFill)
    }

    private var borderColor: Color {
        isUser ? Color.white.opacity(0.22) : Color(.separator).opacity(0.35)
    }

    private var accessibilityLabel: String {
        let status: String
        switch attachment.uploadStatus {
        case .pending: status = "pending"
        case .uploading: status = "uploading"
        case .uploaded: status = "uploaded"
        case .failed: status = "failed"
        }
        return "\(attachment.displayName), \(status)"
    }
}

// MARK: - Light status badge (checkbox / color dot)

/// Very light status chip — small colored glyph, not a loud banner.
struct MessageAttachmentStatusBadge: View {
    let status: ChatMessageAttachmentUploadStatus

    var body: some View {
        Group {
            switch status {
            case .pending:
                Image(systemName: "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            case .uploading:
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            case .uploaded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.green.opacity(0.92))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
        }
        .frame(width: 18, height: 18)
        .background {
            if status == .pending || status == .uploading {
                Circle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 18, height: 18)
            }
        }
        .accessibilityHidden(true)
    }
}
