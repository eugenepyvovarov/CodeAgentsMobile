//
//  ConnectionStatusView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Simple project navigation button
//  - Shows active project name
//  - Button to go back to projects list
//

import SwiftUI

/// Simple project status for navigation bar
struct ConnectionStatusView: View {
    @StateObject private var projectContext = ProjectContext.shared
    
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
                }
                .foregroundColor(.blue)
            }
            .buttonStyle(PlainButtonStyle())
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
