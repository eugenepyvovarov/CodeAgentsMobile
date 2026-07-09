//
//  ChatView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI

struct ChatView: View {
    @State private var viewModel = ChatViewModel()
    @StateObject private var projectContext = ProjectContext.shared
    @Environment(\.modelContext) private var modelContext
    @State private var showingMCPServers = false
    @State private var showingAgentSkills = false
    @State private var showingPermissions = false
    @State private var showingRules = false
    @State private var showingEnvironment = false
    @State private var showingServerSettings = false
    @State private var showingModelChange = false
    /// Bumps when the model sheet closes so the overflow menu summary reloads from the store.
    @State private var modelSummaryEpoch = 0
    @State private var openCodeRuntimeStatus: OpenCodeRuntimeSetupStatus?
    @State private var isCheckingOpenCodeRuntime = false
    
    var body: some View {
        NavigationStack {
            Group {
                if let server = projectContext.activeServer,
                   let openCodeRuntimeStatus,
                   openCodeRuntimeStatus.blocksForegroundChat {
                    OpenCodeUnavailableView(
                        server: server,
                        status: openCodeRuntimeStatus,
                        isChecking: isCheckingOpenCodeRuntime,
                        onCheckAgain: {
                            Task {
                                await refreshOpenCodeRuntimeStatus()
                            }
                        },
                        onOpenServerSettings: {
                            showingServerSettings = true
                        }
                    )
                } else {
                    // Normal chat UI (OpenCode-only)
                    ChatDetailView(viewModel: viewModel, assistantLabel: assistantLabel)
                }
            }
            .navigationTitle(chatTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusView()
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if projectContext.activeServer != nil {
                            Section(openCodeModelSummary) {
                                Button {
                                    showingModelChange = true
                                } label: {
                                    Label("Change Model…", systemImage: "cpu")
                                }
                                .accessibilityIdentifier("chat-change-model-button")
                            }
                        }

                        Button {
                            showingMCPServers = true
                        } label: {
                            Label("MCP Servers", systemImage: "server.rack")
                        }
                        .accessibilityIdentifier("chat-mcp-servers-button")

                        Button {
                            showingAgentSkills = true
                        } label: {
                            Label("Agent Skills", systemImage: "sparkles")
                        }
                        .accessibilityIdentifier("chat-agent-skills-button")

                        Button {
                            showingPermissions = true
                        } label: {
                            Label("Permissions", systemImage: "checkmark.shield")
                        }

                        Button {
                            showingRules = true
                        } label: {
                            Label("Rules", systemImage: "doc.text")
                        }

                        Button {
                            showingEnvironment = true
                        } label: {
                            Label("Environment", systemImage: "terminal")
                        }

                        if viewModel.isProcessing {
                            Divider()

                            Button(role: .destructive) {
                                Task {
                                    await viewModel.abortCurrentResponse()
                                }
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        }

                        Divider()

                        Button {
                            Task {
                                await viewModel.refreshProxyEvents()
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }

                        Button(role: .destructive) {
                            clearChat()
                        } label: {
                            Label("Clear Chat", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("chat-more-menu-button")
                }
            }
        }
        .task(id: projectContext.activeProject?.id) {
            guard let project = projectContext.activeProject else { return }
            viewModel.configure(modelContext: modelContext, projectId: project.id)
            await refreshOpenCodeRuntimeStatus()
        }
        .onAppear {
            // Proxy chat polling retired; method is a no-op kept for call-site compatibility.
            viewModel.startProxyPolling()
            Task {
                if let project = projectContext.activeProject,
                   let server = projectContext.activeServer {
                    await PushNotificationsManager.shared.recordChatOpened(
                        project: project,
                        server: server,
                        agentDisplayName: assistantLabel
                    )
                }
            }
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .onChange(of: projectContext.activeProject) { oldValue, newValue in
            if let project = newValue {
                if let server = projectContext.activeServer {
                    Task {
                        let agentDisplayName = "\(project.displayTitle)@\(server.name)"
                        await PushNotificationsManager.shared.recordChatOpened(
                            project: project,
                            server: server,
                            agentDisplayName: agentDisplayName
                        )
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .projectChatDidReset)) { notification in
            guard let projectId = notification.userInfo?["projectId"] as? UUID else { return }
            guard projectContext.activeProject?.id == projectId else { return }
            viewModel.reloadMessages()
        }
        .onReceive(NotificationCenter.default.publisher(for: .replyFinishedPushReceived)) { notification in
            guard let projectId = notification.userInfo?[ReplyFinishedPushEventKey.projectId] as? UUID else { return }
            guard projectContext.activeProject?.id == projectId else { return }
            let conversationId = notification.userInfo?[ReplyFinishedPushEventKey.conversationId] as? String
            Task {
                await viewModel.refreshProxyEvents(conversationId: conversationId)
            }
        }
        .sheet(isPresented: $showingMCPServers) {
            MCPServersListView()
                .onDisappear {
                    // Refresh MCP servers when sheet is dismissed
                    Task {
                        await viewModel.refreshMCPServers()
                    }
                }
        }
        .sheet(isPresented: $showingAgentSkills) {
            AgentSkillsPickerView()
        }
        .sheet(isPresented: $showingPermissions) {
            PermissionsListView()
        }
        .sheet(isPresented: $showingRules) {
            AgentRulesView()
        }
        .sheet(isPresented: $showingEnvironment) {
            AgentEnvironmentVariablesView()
        }
        .sheet(isPresented: $showingModelChange, onDismiss: {
            modelSummaryEpoch += 1
        }) {
            if let server = projectContext.activeServer {
                OpenCodeChatModelChangeSheet(server: server)
            }
        }
        .sheet(isPresented: $showingServerSettings) {
            if let server = projectContext.activeServer {
                EditServerSheet(server: server)
            }
        }
    }
    
    private func clearChat() {
        viewModel.clearChat()
    }

    private var assistantLabel: String {
        guard let project = projectContext.activeProject else { return "Agent" }
        if let server = projectContext.activeServer {
            return "\(project.displayTitle)@\(server.name)"
        }
        return project.displayTitle
    }

    private var chatTitle: String {
        assistantLabel
    }

    /// Compact provider · model · thinking label for the chat overflow menu.
    /// Depends on `modelSummaryEpoch` so Apply/dismiss from the change sheet refreshes the title.
    private var openCodeModelSummary: String {
        _ = modelSummaryEpoch
        guard let serverId = projectContext.activeProject?.serverId else {
            return "No model selected"
        }
        let profile = OpenCodeAIProviderSettingsStore().effectiveProfile(for: serverId)
        let providerName = OpenCodeProviderPreset.name(for: profile.normalizedProviderID)
            ?? profile.trimmedProviderName
        guard let modelID = profile.resolvedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty else {
            return "\(providerName) · No model"
        }
        if let variant = profile.resolvedVariant {
            let thinking = OpenCodeThinkingSupport.displayTitle(for: variant)
            return "\(providerName) · \(modelID) · \(thinking)"
        }
        return "\(providerName) · \(modelID)"
    }

    private var activeRuntimeKind: CodingAgentRuntimeKind { .openCode }

    @MainActor
    private func refreshOpenCodeRuntimeStatus() async {
        guard let server = projectContext.activeServer else {
            openCodeRuntimeStatus = nil
            return
        }
        guard !isCheckingOpenCodeRuntime else { return }

        isCheckingOpenCodeRuntime = true
        defer {
            isCheckingOpenCodeRuntime = false
        }

        let status = await OpenCodeInstallerService.shared.checkRuntimeStatus(on: server)
        openCodeRuntimeStatus = status.blocksForegroundChat ? status : nil
    }
}

#Preview {
    ChatView()
}
