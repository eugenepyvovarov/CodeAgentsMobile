//
//  ContentView.swift
//  CodeAgentsMobile
//
//  Created by Eugene Pyvovarov on 2025-06-10.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @StateObject private var navigationState = AppNavigationState.shared
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var serverManager = ServerManager.shared
    @StateObject private var cloudInitMonitor = CloudInitMonitor.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        Group {
            if projectContext.activeProject == nil {
                // Show projects list when no project is active
                ProjectsView()
                    .onAppear {
                        configureManagers()
                    }
            } else {
                // Show tabs when a project is active
                TabView(selection: $navigationState.selectedTab) {
                    ChatView()
                        .tabItem {
                            Label("Chat", systemImage: "message")
                        }
                        .tag(AppTab.chat)
                    
                    FileBrowserView()
                        .tabItem {
                            Label("Files", systemImage: "doc.text")
                        }
                        .tag(AppTab.files)
                    
                    RegularTasksView()
                        .tabItem {
                            Label("Regular Tasks", systemImage: "clock.badge.checkmark")
                        }
                        .tag(AppTab.tasks)
                }
                .onAppear {
                    configureManagers()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // App became active - start monitoring
                startCloudInitMonitoring()
                Task { await PushNotificationsManager.shared.syncDeliveredReplyFinishedNotifications() }
            case .inactive, .background:
                // App went to background - stop monitoring to save resources
                cloudInitMonitor.stopAllMonitoring()
            @unknown default:
                break
            }
        }
        .onChange(of: projectContext.activeProject?.id) { _, _ in
            configureManagers()
        }
        .task {
            seedAIProvidersEvidenceStateIfNeeded()
            seedSettingsListsEvidenceStateIfNeeded()
            seedChatOpenDeferredStartupEvidenceStateIfNeeded()
        }
    }
    
    private func configureManagers() {
        // Load servers for ServerManager
        serverManager.loadServers(from: modelContext)
        // Ensure built-in skill marketplaces are available by default.
        SkillMarketplaceSeedService.shared.ensureBuiltinSourcesExist(in: modelContext)
        // Start cloud-init monitoring for servers that need it
        startCloudInitMonitoring()
        ShortcutSyncService.shared.sync(using: modelContext)
        
        if let project = projectContext.activeProject {
            if let server = projectContext.activeServer {
                let agentDisplayName = "\(project.displayTitle)@\(server.name)"
                Task {
                    await PushNotificationsManager.shared.registerProjectSubscription(
                        project: project,
                        server: server,
                        agentDisplayName: agentDisplayName
                    )
                }
            }

            Task {
                do {
                    try await CodingAgentMCPService.shared.ensureManagedSchedulerServerIfNeeded(for: project)
                } catch {
                    SSHLogger.log("Failed to ensure managed scheduler MCP server: \(error)", level: .warning)
                }
            }
        }
    }
    
    private func startCloudInitMonitoring() {
        cloudInitMonitor.startMonitoring(modelContext: modelContext)
    }

    private func seedAIProvidersEvidenceStateIfNeeded() {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("--ui-testing") else { return }

        if processInfo.arguments.contains("--ui-test-ai-providers-legacy-key") {
            try? KeychainManager.shared.deleteOpenCodeAPIKey(providerID: "anthropic")
            try? KeychainManager.shared.storeAPIKey("codeagents-ui-test-anthropic-key", provider: .anthropic)
        }

        guard processInfo.arguments.contains("--ui-test-ai-providers-legacy-project"),
              projectContext.activeProject == nil else {
            return
        }

        let server = Server(
            name: "Evidence Legacy Server",
            host: "127.0.0.1",
            username: "codeagents"
        )
        let project = RemoteProject(
            name: "legacy-claude-proxy-agent",
            displayName: "Legacy Claude Proxy Agent",
            serverId: server.id,
            basePath: "/tmp/codeagents-evidence"
        )
        // Seed as pre-migration legacy Claude so migration path can be exercised in evidence runs.
        project.agentRuntimeRawValue = CodingAgentRuntimeKind.claudeProxy.rawValue
        project.openCodeMigrationVersion = nil
        project.lastSuccessfulClaudeProviderRawValue = ClaudeModelProvider.miniMax.rawValue

        modelContext.insert(server)
        modelContext.insert(project)
        try? modelContext.save()

        serverManager.loadServers(from: modelContext)
        projectContext.setActiveProject(project)
    }

    private func seedSettingsListsEvidenceStateIfNeeded() {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("--ui-testing"),
              processInfo.arguments.contains("--ui-test-settings-lists-consistent") else {
            return
        }

        let providerName = "Evidence DigitalOcean"
        let keyName = "evidence-ed25519"

        let providerDescriptor = FetchDescriptor<ServerProvider>(
            predicate: #Predicate { $0.name == providerName }
        )
        if (try? modelContext.fetch(providerDescriptor).isEmpty) == false {
            return
        }

        let activeProvider = ServerProvider(providerType: "digitalocean", name: providerName)
        let unusedProvider = ServerProvider(providerType: "hetzner", name: "Evidence Hetzner")
        let sshKey = SSHKey(
            name: keyName,
            keyType: "Ed25519",
            privateKeyIdentifier: "ui-test-settings-lists-consistent-key"
        )
        sshKey.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvidenceOnlySettingsLists codeagents-ui-test"

        let server = Server(
            name: "Evidence Server",
            host: "127.0.0.1",
            username: "codeagents",
            authMethodType: "key"
        )
        server.providerId = activeProvider.id
        server.sshKeyId = sshKey.id

        modelContext.insert(activeProvider)
        modelContext.insert(unusedProvider)
        modelContext.insert(sshKey)
        modelContext.insert(server)
        try? modelContext.save()
        serverManager.loadServers(from: modelContext)
    }

    private func seedChatOpenDeferredStartupEvidenceStateIfNeeded() {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.arguments.contains("--ui-testing"),
              processInfo.arguments.contains("--ui-test-chat-open-deferred-startup"),
              projectContext.activeProject == nil else {
            return
        }

        let server = Server(
            name: "Evidence Deferred Startup Server",
            host: "127.0.0.1",
            username: "codeagents"
        )
        let project = RemoteProject(
            name: "deferred-startup-agent",
            displayName: "Deferred Startup Agent",
            serverId: server.id,
            basePath: "/tmp/codeagents-evidence"
        )
        project.selectedAgentRuntime = .openCode
        project.openCodeMigrationVersion = ClaudeToOpenCodeMigration.currentVersion
        project.proxyAgentId = "evidence-deferred-startup-agent"
        project.proxyConversationId = "evidence-deferred-startup-conversation"
        project.lastSuccessfulClaudeProviderRawValue = ClaudeModelProvider.anthropic.rawValue

        let now = Date()
        let userMessage = Message(
            content: "Local question ready from storage.",
            role: .user,
            projectId: project.id
        )
        userMessage.timestamp = now.addingTimeInterval(-90)
        let assistantMessage = Message(
            content: "Local response is visible while startup work is deferred.",
            role: .assistant,
            projectId: project.id
        )
        assistantMessage.timestamp = now.addingTimeInterval(-60)

        modelContext.insert(server)
        modelContext.insert(project)
        modelContext.insert(userMessage)
        modelContext.insert(assistantMessage)
        try? modelContext.save()

        serverManager.loadServers(from: modelContext)
        projectContext.setActiveProject(project)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [RemoteProject.self, Server.self], inMemory: true)
}
