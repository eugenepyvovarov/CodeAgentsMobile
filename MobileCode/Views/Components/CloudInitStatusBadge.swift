//
//  CloudInitStatusBadge.swift
//  CodeAgentsMobile
//
//  Purpose: Visual indicator for cloud-init status on managed servers
//

import SwiftUI

struct CloudInitStatusBadge: View {
    let status: String?
    
    var body: some View {
        if status?.lowercased() != "unknown" && status != nil {
            HStack(spacing: 6) {
                if showSpinner {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                }
                
                Text(statusText)
                    .font(.caption2)
                    .foregroundColor(statusColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.15))
            .cornerRadius(4)
        }
    }
    
    private var statusText: String {
        switch status?.lowercased() {
        case "done":
            return "Ready"
        case "running":
            return "Installing Claude Code..."
        case "error":
            return "Error"
        case "checking":
            return "Checking..."
        default:
            return ""
        }
    }
    
    private var statusColor: Color {
        switch status?.lowercased() {
        case "done":
            return .green
        case "running", "checking":
            return .orange
        case "error":
            return .red
        default:
            return .gray
        }
    }
    
    private var showSpinner: Bool {
        status?.lowercased() == "running" || status?.lowercased() == "checking"
    }
}

// Helper functions for cloud-init status
extension View {
    func cloudInitStatusText(_ status: String?) -> String {
        switch status?.lowercased() {
        case "done":
            return "Ready"
        case "running":
            return "Installing Claude Code..."
        case "checking":
            return "Checking status..."
        case "error":
            return "Configuration failed"
        case "timeout":
            return "Installation timeout"
        default:
            return "Unknown status"
        }
    }
    
    func cloudInitStatusColor(_ status: String?) -> Color {
        switch status?.lowercased() {
        case "done":
            return .green
        case "running", "checking":
            return .orange
        case "error":
            return .red
        default:
            return .gray
        }
    }
    
    func isServerReady(_ server: Server) -> Bool {
        // Server is ready if cloud-init is complete or if it's not a managed server
        return server.cloudInitComplete || server.providerId == nil
    }
}

#Preview {
    VStack(spacing: 20) {
        CloudInitStatusBadge(status: "running")
        CloudInitStatusBadge(status: "done")
        CloudInitStatusBadge(status: "error")
        CloudInitStatusBadge(status: "checking")
        CloudInitStatusBadge(status: "unknown")
        CloudInitStatusBadge(status: nil)
    }
    .padding()
}