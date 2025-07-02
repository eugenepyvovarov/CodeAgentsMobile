//
//  ConnectionStatusView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Shows current connection status across all views
//  - Displays server name when connected
//  - Shows disconnected state with quick connect option
//  - Provides visual indicators for connection state
//

import SwiftUI
import SwiftData

/// Connection status indicator for navigation bar
struct ConnectionStatusView: View {
    @State private var connectionManager = ConnectionManager.shared
    @StateObject private var projectContext = ProjectContext.shared
    
    var body: some View {
        Button {
            // Clear active project to go back to projects list
            projectContext.clearActiveProject()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                if let project = connectionManager.activeProject {
                    Text(project.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if connectionManager.activeServer != nil {
                    Text("No Project")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Not Connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.systemGray5))
            .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    private var statusColor: Color {
        connectionManager.isConnected ? .green : .gray
    }
}

/// Connection required wrapper view
struct ConnectionRequiredView<Content: View>: View {
    @State private var connectionManager = ConnectionManager.shared
    
    let title: String
    let message: String
    @ViewBuilder let content: () -> Content
    
    init(
        title: String = "Connection Required",
        message: String = "Connect to a server to use this feature",
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.message = message
        self.content = content
    }
    
    var body: some View {
        if connectionManager.isConnected {
            content()
        } else {
            VStack(spacing: 20) {
                Spacer()
                
                Image(systemName: "network.slash")
                    .font(.system(size: 60))
                    .foregroundColor(.gray)
                
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                // Server list is shown in a separate view with model context
                ServerQuickConnectList()
                    .padding(.horizontal)
                
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Go to Settings", systemImage: "gear")
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConnectionStatusView()
                }
            }
        }
    }
}

/// List of servers for quick connect
struct ServerQuickConnectList: View {
    @Query(sort: \Server.lastConnected, order: .reverse) private var servers: [Server]
    
    var body: some View {
        if !servers.isEmpty {
            VStack(spacing: 12) {
                Text("Recent Servers")
                    .font(.headline)
                    .padding(.top)
                
                ForEach(Array(servers.prefix(3))) { server in
                    ServerQuickConnectView(server: server)
                }
            }
        }
    }
}

/// Quick connect button for servers
struct ServerQuickConnectView: View {
    let server: Server
    @State private var connectionManager = ConnectionManager.shared
    @State private var isConnecting = false
    
    var body: some View {
        Button {
            connect()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("\(server.username)@\(server.host)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if let lastConnected = server.lastConnected {
                        Text("Last: \(lastConnected, style: .relative) ago")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isConnecting {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.8)
                } else {
                    Text("Connect")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isConnecting)
    }
    
    private func connect() {
        isConnecting = true
        
        Task {
            await connectionManager.connect(to: server)
            
            await MainActor.run {
                isConnecting = false
            }
        }
    }
}

#Preview {
    NavigationStack {
        ConnectionRequiredView {
            Text("Connected Content")
        }
    }
    .modelContainer(for: Server.self, inMemory: true)
}