//
//  ChatView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//

import SwiftUI

/// OpenCode readiness gate for chat: keep conversation visible while soft-connecting,
/// only full-screen block after all auto-retries fail.
private enum OpenCodeChatConnectionPhase: Equatable {
    case idle
    case connecting(attempt: Int, maxAttempts: Int)
    case ready
    case failed(OpenCodeRuntimeSetupStatus)

    var blocksChat: Bool {
        if case .failed(let status) = self {
            return status.blocksForegroundChat
        }
        return false
    }

    var connectingPillLine: String? {
        guard case .connecting(let attempt, let maxAttempts) = self else { return nil }
        return "Connecting \(attempt)/\(maxAttempts)"
    }

    var failedStatus: OpenCodeRuntimeSetupStatus? {
        if case .failed(let status) = self { return status }
        return nil
    }
}

struct ChatView: View {
    /// Soft connect attempts before full-screen OpenCode unavailable.
    private static let openCodeConnectMaxAttempts = 5
    /// Delay between failed connect attempts (keeps chat usable during brief outages).
    private static let openCodeConnectRetryDelayNanoseconds: UInt64 = 2_500_000_000

    @State private var viewModel = ChatViewModel()
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var navigationState = AppNavigationState.shared
    @Environment(\.modelContext) private var modelContext
    @State private var showingServerSettings = false
    @State private var showingModelChange = false
    /// Bumps when the model sheet closes so the overflow menu summary reloads from the store.
    @State private var modelSummaryEpoch = 0
    @State private var openCodeConnectionPhase: OpenCodeChatConnectionPhase = .idle
    @State private var isCheckingOpenCodeRuntime = false
    @State private var openCodeConnectGeneration = 0

    var body: some View {
        NavigationStack {
            Group {
                if let server = projectContext.activeServer,
                   openCodeConnectionPhase.blocksChat,
                   let failedStatus = openCodeConnectionPhase.failedStatus {
                    OpenCodeUnavailableView(
                        server: server,
                        status: failedStatus,
                        isChecking: isCheckingOpenCodeRuntime,
                        onCheckAgain: {
                            Task {
                                await startOpenCodeConnectLoop(force: true)
                            }
                        },
                        onOpenServerSettings: {
                            showingServerSettings = true
                        }
                    )
                } else {
                    // Keep chat visible during soft connect retries (pill overlays top).
                    ChatDetailView(
                        viewModel: viewModel,
                        assistantLabel: assistantLabel,
                        openCodeConnectingLine: openCodeConnectionPhase.connectingPillLine
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusView()
                }

                ToolbarItem(placement: .principal) {
                    chatHeaderTitle
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
                            navigationState.selectedTab = .abilities
                        } label: {
                            Label("Open Abilities", systemImage: "sparkles")
                        }
                        .accessibilityIdentifier("chat-open-abilities-button")

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
            guard let project = projectContext.activeProject else {
                openCodeConnectionPhase = .idle
                return
            }
            viewModel.configure(modelContext: modelContext, projectId: project.id)
            // Keep list/abilities avatar cache warm without blocking chat open.
            Task {
                await AgentAvatarService.shared.refresh(for: project, modelContext: modelContext)
            }
            await startOpenCodeConnectLoop(force: false)
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
            openCodeConnectGeneration += 1
        }
        .onChange(of: projectContext.activeProject) { oldValue, newValue in
            if let project = newValue {
                if let server = projectContext.activeServer {
                    Task {
                        await PushNotificationsManager.shared.recordChatOpened(
                            project: project,
                            server: server,
                            agentDisplayName: project.displayTitle
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
        .sheet(isPresented: $showingModelChange, onDismiss: {
            modelSummaryEpoch += 1
        }) {
            // Always provide non-empty sheet content — empty `if let` sheets can stick blank in SwiftUI.
            if let server = projectContext.activeServer {
                OpenCodeChatModelChangeSheet(server: server)
            } else {
                NavigationStack {
                    ContentUnavailableView(
                        "No Server",
                        systemImage: "server.rack",
                        description: Text("Select an agent with a connected server to change the model.")
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingModelChange = false }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingServerSettings, onDismiss: {
            // Auth / install changes in Edit Server — soft-connect again instead of staying failed.
            if openCodeConnectionPhase.blocksChat || openCodeConnectionPhase.connectingPillLine != nil {
                Task {
                    await startOpenCodeConnectLoop(force: true)
                }
            }
        }) {
            if let server = projectContext.activeServer {
                EditServerSheet(server: server)
            } else {
                NavigationStack {
                    ContentUnavailableView(
                        "No Server",
                        systemImage: "server.rack",
                        description: Text("Select an agent with a connected server to edit server settings.")
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showingServerSettings = false }
                        }
                    }
                }
            }
        }
    }
    
    private func clearChat() {
        viewModel.clearChat()
    }

    /// Agent display name only (no `@server` — server lives in Abilities).
    private var assistantLabel: String {
        projectContext.activeProject?.displayTitle ?? "Agent"
    }

    private var chatTitle: String {
        assistantLabel
    }

    /// Principal bar: avatar + agent name (tap opens Abilities).
    @ViewBuilder
    private var chatHeaderTitle: some View {
        if let project = projectContext.activeProject {
            Button {
                navigationState.selectedTab = .abilities
            } label: {
                HStack(spacing: 8) {
                    AgentAvatarView(project: project, size: 52)
                        .modifier(ChatHeaderAvatarChrome())

                    Text(chatTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(chatTitle)
            .accessibilityHint("Opens Abilities")
            .accessibilityIdentifier("chat-header-agent")
        } else {
            Text(chatTitle)
                .font(.headline)
                .lineLimit(1)
        }
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

    /// Soft-connect OpenCode with a top pill for each attempt; full-screen only after all retries fail.
    @MainActor
    private func startOpenCodeConnectLoop(force: Bool) async {
        guard let server = projectContext.activeServer else {
            openCodeConnectionPhase = .idle
            isCheckingOpenCodeRuntime = false
            return
        }

        openCodeConnectGeneration += 1
        let generation = openCodeConnectGeneration
        let maxAttempts = Self.openCodeConnectMaxAttempts

        isCheckingOpenCodeRuntime = true
        defer {
            if generation == openCodeConnectGeneration {
                isCheckingOpenCodeRuntime = false
            }
        }

        var lastBlockingStatus: OpenCodeRuntimeSetupStatus?

        for attempt in 1...maxAttempts {
            guard generation == openCodeConnectGeneration else { return }
            guard projectContext.activeServer?.id == server.id else { return }

            openCodeConnectionPhase = .connecting(attempt: attempt, maxAttempts: maxAttempts)

            // First attempt may use cache / warm; later attempts always force a fresh probe.
            // Daemon ensure stays off the chat-ready path (scheduled after ready).
            let status = await OpenCodeInstallerService.shared.checkRuntimeStatus(
                on: server,
                force: force || attempt > 1,
                includeDaemon: false
            )

            guard generation == openCodeConnectGeneration else { return }

            if !status.blocksForegroundChat {
                openCodeConnectionPhase = .ready
                OpenCodeInstallerService.shared.scheduleBackgroundDaemonEnsure(for: server)
                return
            }

            lastBlockingStatus = status

            if attempt < maxAttempts {
                SSHLogger.log(
                    "OpenCode chat connect attempt \(attempt)/\(maxAttempts) blocked (\(status.state)); retrying",
                    level: .warning
                )
                try? await Task.sleep(nanoseconds: Self.openCodeConnectRetryDelayNanoseconds)
            }
        }

        guard generation == openCodeConnectGeneration else { return }
        if let lastBlockingStatus {
            openCodeConnectionPhase = .failed(lastBlockingStatus)
        } else {
            openCodeConnectionPhase = .failed(.unknown("OpenCode is not reachable."))
        }
    }
}

// MARK: - Header chrome

/// Subtle glass ring around the chat-header avatar (interactive because the header is tappable).
private struct ChatHeaderAvatarChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.12)).interactive(),
                    in: .circle
                )
        } else {
            content
                .overlay {
                    Circle()
                        .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
                }
        }
    }
}

#Preview {
    ChatView()
}
