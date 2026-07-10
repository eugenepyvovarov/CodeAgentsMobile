//
//  ConnectionStatusView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Simple project navigation button
//  - Shows active project name
//  - Badge for unread messages in *other* agents
//  - Button to go back to projects list
//

import SwiftUI
import SwiftData

/// Simple project status for navigation bar
struct ConnectionStatusView: View {
    @StateObject private var projectContext = ProjectContext.shared
    @Query private var projects: [RemoteProject]

    /// Unread count for agents other than the one currently open.
    private var otherAgentsUnread: Int {
        UnreadBadgeMath.totalUnread(
            projectUnreads: projects.map { ($0.id, $0.unreadCount) },
            excludingProjectID: projectContext.activeProject?.id
        )
    }

    var body: some View {
        if let project = projectContext.activeProject {
            Button {
                // Clear active project to go back to projects list
                projectContext.clearActiveProject()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))

                    Text(project.displayTitle)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)

                    if let text = UnreadBadgeMath.badgeText(for: otherAgentsUnread) {
                        Text(text)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .accessibilityIdentifier("other-agents-unread-badge")
                            .accessibilityLabel(
                                "\(otherAgentsUnread) unread message\(otherAgentsUnread == 1 ? "" : "s") in other agents"
                            )
                    }
                }
                .foregroundColor(.blue)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityHint("Returns to the agents list")
        }
    }
}

#Preview {
    NavigationStack {
        VStack {
            Text("Test View")
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConnectionStatusView()
            }
        }
    }
}
