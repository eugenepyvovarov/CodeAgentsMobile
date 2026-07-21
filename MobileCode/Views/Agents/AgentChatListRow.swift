//
//  AgentChatListRow.swift
//  CodeAgentsMobile
//
//  Purpose: Compact Messages/Telegram-style agent chat row.
//

import SwiftUI
import SwiftData

/// One agent conversation in the Agents list.
struct AgentChatListRow: View {
    // MARK: - Inputs

    let project: RemoteProject
    var isEditing: Bool = false
    var onEdit: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?

    // MARK: - Environment / state

    @StateObject private var projectContext = ProjectContext.shared
    @State private var isActivating = false

    @Query private var servers: [Server]
    @Query private var previewMessages: [Message]

    init(
        project: RemoteProject,
        isEditing: Bool = false,
        onEdit: (() -> Void)? = nil,
        onDuplicate: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.project = project
        self.isEditing = isEditing
        self.onEdit = onEdit
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete

        let projectId = project.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { message in
                message.projectId == projectId
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 12
        _previewMessages = Query(descriptor)
    }

    // MARK: - Computed

    private var server: Server? {
        servers.first { $0.id == project.serverId }
    }

    private var hasUnread: Bool {
        project.unreadCount > 0
    }

    private var titleWeight: Font.Weight {
        hasUnread ? .semibold : .regular
    }

    private struct Presentation {
        let previewText: String
        let activity: AgentChatPreview.Activity
        let timestampText: String?
    }

    private func makePresentation() -> Presentation {
        let preview = AgentChatPreviewLoader.preview(fromNewestFirst: previewMessages)
        let previewText: String
        if let preview {
            previewText = preview.listLine
        } else if let server {
            previewText = "\(server.username)@\(server.host)"
        } else {
            previewText = "No messages yet"
        }

        let timestampText: String?
        if let preview {
            timestampText = AgentChatListTimestamp.format(preview.timestamp)
        } else if let lastMessageAt = project.lastMessageAt {
            timestampText = AgentChatListTimestamp.format(lastMessageAt)
        } else {
            timestampText = AgentChatListTimestamp.format(project.createdAt)
        }

        return Presentation(
            previewText: previewText,
            activity: preview?.activity ?? .none,
            timestampText: timestampText
        )
    }

    // MARK: - Body

    var body: some View {
        let presentation = makePresentation()
        Group {
            if isEditing {
                editingContent(presentation: presentation)
            } else {
                Button {
                    Task { await activateProject() }
                } label: {
                    rowContent(presentation: presentation)
                }
                .buttonStyle(.plain)
                .disabled(isActivating)
                .opacity(isActivating ? 0.65 : 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary(presentation: presentation))
        .accessibilityIdentifier("agent-chat-row-\(project.id.uuidString)")
    }

    // MARK: - Subviews

    private func rowContent(presentation: Presentation) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AgentAvatarView(
                project: project,
                hasUnread: hasUnread
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(project.displayTitle)
                        .font(.body.weight(titleWeight))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let timestampText = presentation.timestampText {
                        Text(timestampText)
                            .font(.caption)
                            .foregroundStyle(hasUnread ? Color.accentColor : Color.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(alignment: .center, spacing: 8) {
                    previewLine(presentation: presentation)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    trailingChrome
                }
            }
        }
        // Compact only via vertical padding — keep type/avatar at Messages-like scale.
        .padding(.vertical, 0)
        .contentShape(Rectangle())
    }

    private func previewLine(presentation: Presentation) -> some View {
        HStack(spacing: 5) {
            if let symbol = presentation.activity.systemImage {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
            }

            Text(presentation.previewText)
                .font(.subheadline.weight(hasUnread ? .medium : .regular))
                .foregroundStyle(hasUnread ? Color.primary.opacity(0.75) : Color.secondary)
                .lineLimit(1)
        }
    }

    private func editingContent(presentation: Presentation) -> some View {
        HStack(spacing: 10) {
            rowContent(presentation: presentation)
            editActions
        }
    }

    @ViewBuilder
    private var trailingChrome: some View {
        if isActivating {
            ProgressView()
                .scaleEffect(0.8)
                .accessibilityLabel("Opening chat")
        } else if let text = project.unreadBadgeText {
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor, in: Capsule())
                .accessibilityLabel(
                    "\(project.unreadCount) unread message\(project.unreadCount == 1 ? "" : "s")"
                )
        }
    }

    private var editActions: some View {
        HStack(spacing: 10) {
            if let onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Edit Agent")
                .modifier(AgentListGlassIconButtonModifier())
            }
            if let onDuplicate {
                Button(action: onDuplicate) {
                    Image(systemName: "plus.square.on.square")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Duplicate Agent")
                .accessibilityIdentifier("agent-duplicate-button")
                .modifier(AgentListGlassIconButtonModifier())
            }
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Delete Agent")
                .modifier(AgentListGlassIconButtonModifier(destructive: true))
            }
        }
        .buttonStyle(.borderless)
    }

    private func accessibilitySummary(presentation: Presentation) -> String {
        var parts = [project.displayTitle]
        if hasUnread {
            parts.append("\(project.unreadCount) unread")
        }
        parts.append(presentation.previewText)
        if let timestampText = presentation.timestampText {
            parts.append(timestampText)
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Actions

    private func activateProject() async {
        isActivating = true
        defer { isActivating = false }
        projectContext.setActiveProject(project)
    }
}

// MARK: - Glass icon chrome

private struct AgentListGlassIconButtonModifier: ViewModifier {
    var destructive: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .foregroundStyle(destructive ? Color.red : Color.accentColor)
                .glassEffect(
                    .regular.tint((destructive ? Color.red : Color.accentColor).opacity(0.14)).interactive(),
                    in: .circle
                )
        } else {
            content
                .foregroundStyle(destructive ? Color.red : Color.accentColor)
                .background(
                    Circle().fill(Color(.secondarySystemFill))
                )
        }
    }
}

#Preview {
    List {
        AgentChatListRow(
            project: {
                let p = RemoteProject(name: "demo", displayName: "Ops Bot", serverId: UUID())
                p.lastMessageAt = Date().addingTimeInterval(-120)
                p.lastKnownUnreadCursor = 3
                p.lastReadUnreadCursor = 1
                return p
            }()
        )
        AgentChatListRow(
            project: RemoteProject(name: "quiet", displayName: "Quiet Agent", serverId: UUID())
        )
    }
    .listStyle(.plain)
}
