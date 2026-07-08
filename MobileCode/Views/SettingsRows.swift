//
//  SettingsRows.swift
//  CodeAgentsMobile
//
//  Shared row components used by SettingsView.
//

import SwiftUI
import SwiftData

struct SettingsAddRow: View {
    let title: String

    var body: some View {
        HStack {
            Image(systemName: "plus.circle.fill")
            Text(title)
        }
        .foregroundColor(.accentColor)
    }
}

struct SettingsUsageIndicator: View {
    let count: Int
    let noun: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundColor(.orange)
            Text("\(count) \(noun)\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct CloudProviderRow: View {
    let provider: ServerProvider
    let serverCount: Int
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon column with fixed width for alignment
            ZStack {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 40, height: 40)
                
                ProviderIcon(
                    providerType: provider.providerType,
                    size: 24,
                    color: provider.providerType == "digitalocean" ? .blue : .orange
                )
            }
            
            // Content
            Text(provider.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(serverCount > 0 ? .secondary : .primary)
            
            Spacer()
            
            // Server count and lock icon
            if serverCount > 0 {
                SettingsUsageIndicator(count: serverCount, noun: "server")
            } else {
                // Provider type label
                Text(provider.providerType == "digitalocean" ? "DigitalOcean" : "Hetzner")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct SSHKeyRow: View {
    let sshKey: SSHKey
    let usageCount: Int
    let onTap: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Key name
            Text(sshKey.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(usageCount > 0 ? .secondary : .primary)
            
            Spacer()
            
            // Right side - usage indicator
            if usageCount > 0 {
                SettingsUsageIndicator(count: usageCount, noun: "server")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

struct ServerRow: View {
    let server: Server
    let projectCount: Int
    @State private var showingEditSheet = false
    @Query private var providers: [ServerProvider]
    
    private var serverProvider: ServerProvider? {
        providers.first { $0.id == server.providerId }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.headline)
                        .foregroundColor(projectCount > 0 ? .secondary : .primary)
                    
                    // Show cloud-init status badge if provisioning incomplete
                    if !server.cloudInitComplete && server.providerId != nil {
                        CloudInitStatusBadge(status: server.cloudInitStatus)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 6) {
                    // Show cloud provider badge if applicable
                    if let provider = serverProvider {
                        ProviderIcon(
                            providerType: provider.providerType,
                            size: 14,
                            color: provider.providerType == "digitalocean" ? .blue : .orange
                        )
                    }
                    if server.authMethodType == "key" {
                        Image(systemName: "key.horizontal.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if projectCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Text("\(projectCount) agent\(projectCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            Text("\(server.username)@\(server.host):\(server.port)")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontDesign(.monospaced)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            showingEditSheet = true
        }
        .sheet(isPresented: $showingEditSheet) {
            EditServerSheet(server: server)
        }
    }
}
