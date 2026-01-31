//
//  MCPServerRow.swift
//  CodeAgentsMobile
//
//  Purpose: Row component for displaying an MCP server with status
//

import SwiftUI

struct MCPServerRow: View {
    let server: MCPServer
    
    private var statusColor: Color {
        switch server.status {
        case .connected:
            return .green
        case .disconnected:
            return .red
        case .unknown:
            return .gray
        case .checking:
            return .blue
        }
    }
    
    private var statusIcon: String {
        switch server.status {
        case .connected:
            return "checkmark.circle.fill"
        case .disconnected:
            return "xmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        case .checking:
            return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.title3)
                .frame(width: 24)
            
            // Server details
            VStack(alignment: .leading, spacing: 4) {
                Text(cleanServerName(server.name))
                    .font(.headline)
                    .lineLimit(1)
                
                Text(server.fullCommand)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                if !server.env.isNilOrEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .font(.caption2)
                        Text("\(server.env!.count) env var\(server.env!.count == 1 ? "" : "s")")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Status text
            VStack(alignment: .trailing, spacing: 2) {
                Text(server.status.displayText)
                    .font(.caption)
                    .foregroundColor(server.status == .checking ? .primary : statusColor)
                
                if server.status == .checking {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                if server.isRemote {
                    Label("Remote", systemImage: "network")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
            
            // Edit indicator
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
    
    private func cleanServerName(_ name: String) -> String {
        // Remove (HTTP) or (SSE) suffixes from server names
        let cleaned = name
            .replacingOccurrences(of: " (HTTP)", with: "")
            .replacingOccurrences(of: " (SSE)", with: "")
            .replacingOccurrences(of: "(HTTP)", with: "")
            .replacingOccurrences(of: "(SSE)", with: "")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Helper Extensions
private extension Optional where Wrapped: Collection {
    var isNilOrEmpty: Bool {
        return self?.isEmpty ?? true
    }
}

#Preview {
    List {
        MCPServerRow(server: MCPServer(
            name: "firecrawl",
            command: "npx",
            args: ["-y", "firecrawl-mcp"],
            env: nil,
            status: .connected
        ))
        
        MCPServerRow(server: MCPServer(
            name: "sqlite",
            command: "uv",
            args: ["--directory", "/Users/path/to/agent", "run", "mcp-server-sqlite"],
            env: ["DB_PATH": "/path/to/db.sqlite"],
            status: .disconnected
        ))
        
        MCPServerRow(server: MCPServer(
            name: "playwright",
            command: "npx",
            args: ["@playwright/mcp@latest"],
            env: nil,
            status: .checking
        ))
        
        MCPServerRow(server: MCPServer(
            name: "remote-api",
            command: "https://api.example.com/mcp",
            args: nil,
            env: nil,
            status: .connected
        ))
    }
    .listStyle(InsetGroupedListStyle())
}
