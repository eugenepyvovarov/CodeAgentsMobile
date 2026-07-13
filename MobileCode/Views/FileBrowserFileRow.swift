//
//  FileBrowserFileRow.swift
//  CodeAgentsMobile
//
//  Purpose: File browser list row with image/video thumbnail previews.
//

import SwiftUI
import UIKit

struct FileBrowserFileRow: View {
    let node: FileNode
    let project: RemoteProject?
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onShare: (() -> Void)?

    @State private var thumbnail: UIImage?
    @State private var isLoadingThumbnail = false

    private let thumbSize: CGFloat = 52

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                thumbnailView

                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.leading)

                    if let meta = metadataLine {
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if node.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onShare, !node.isDirectory {
                Button {
                    onShare()
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                Divider()
            }

            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .task(id: thumbnailTaskID) {
            await loadThumbnailIfNeeded()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(placeholderFill)

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: node.icon)
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
            }

            if node.isVideoFile {
                VStack {
                    Spacer()
                    HStack {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(4)
                        Spacer()
                    }
                }
            }

            if isLoadingThumbnail && thumbnail == nil && node.isMediaFile {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(node.isMediaFile && thumbnail != nil ? 0.08 : 0), radius: 2, y: 1)
        .animation(.easeInOut(duration: 0.2), value: thumbnail != nil)
    }

    private var placeholderFill: Color {
        if node.isDirectory {
            return Color.accentColor.opacity(0.12)
        }
        if node.isImageFile {
            return Color.blue.opacity(0.10)
        }
        if node.isVideoFile {
            return Color.purple.opacity(0.10)
        }
        return Color(.secondarySystemFill)
    }

    private var iconColor: Color {
        if node.isDirectory { return .accentColor }
        if node.isImageFile { return .blue.opacity(0.85) }
        if node.isVideoFile { return .purple.opacity(0.85) }
        return .secondary
    }

    // MARK: - Meta

    private var metadataLine: String? {
        var parts: [String] = []
        if let size = node.formattedSize {
            parts.append(size)
        }
        if let date = node.modificationDate {
            parts.append("Modified \(date.formatted(.relative(presentation: .named)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var thumbnailTaskID: String {
        "\(project?.id.uuidString ?? "none")|\(node.path)|\(node.fileSize ?? 0)|\(node.modificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private var accessibilityLabel: String {
        var parts = [node.name]
        if node.isDirectory {
            parts.append("folder")
        } else if node.isImageFile {
            parts.append("image")
        } else if node.isVideoFile {
            parts.append("video")
        }
        if let meta = metadataLine {
            parts.append(meta)
        }
        return parts.joined(separator: ", ")
    }

    private func loadThumbnailIfNeeded() async {
        guard node.isMediaFile, let project else { return }

        if let cached = RemoteFileThumbnailLoader.shared.cachedThumbnail(for: node, projectId: project.id) {
            thumbnail = cached
            return
        }

        isLoadingThumbnail = true
        defer { isLoadingThumbnail = false }
        thumbnail = await RemoteFileThumbnailLoader.shared.thumbnail(for: node, project: project)
    }
}
