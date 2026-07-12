//
//  AgentAbilitiesView.swift
//  CodeAgentsMobile
//
//  Purpose: Per-agent hub for personality, skills, MCP, permissions, env, and model.
//

import SwiftUI
import SwiftData

/// Human-facing home for agent configuration (project files + local permissions/env).
/// The agent mutates the same project files via normal OpenCode tools — no parallel MCP API.
struct AgentAbilitiesView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var projectContext = ProjectContext.shared

    @Query private var skillAssignments: [AgentSkillAssignment]
    @Query(sort: [SortDescriptor(\AgentEnvironmentVariable.key, order: .forward)])
    private var allEnvironmentVariables: [AgentEnvironmentVariable]

    @State private var mcpServerCount: Int?
    @State private var isLoadingMCP = false
    @State private var showingModelChange = false
    @State private var showingDuplicate = false
    @State private var showingAvatarEditor = false
    @State private var modelSummaryEpoch = 0
    @State private var rulesStatus: RulesOverviewStatus = .unknown

    private var project: RemoteProject? {
        projectContext.activeProject
    }

    private var enabledSkillsCount: Int {
        guard let project else { return 0 }
        return skillAssignments.filter { $0.projectId == project.id }.count
    }

    private var environmentVariablesCount: Int {
        guard let project else { return 0 }
        return allEnvironmentVariables.filter { $0.projectId == project.id }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if project == nil {
                    ContentUnavailableView {
                        Label("No Active Agent", systemImage: "person.crop.circle.badge.xmark")
                    } description: {
                        Text("Select an agent to manage abilities.")
                    }
                } else {
                    List {
                        overviewSection
                        configurationSection
                        tipSection
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Abilities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    ConnectionStatusView()
                }
                if project != nil {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingDuplicate = true
                        } label: {
                            Image(systemName: "plus.square.on.square")
                        }
                        .accessibilityLabel("Duplicate Agent")
                        .accessibilityIdentifier("abilities-duplicate-button")
                    }
                }
            }
            .task(id: project?.id) {
                await refreshOverview()
            }
            .refreshable {
                await refreshOverview()
            }
            .sheet(isPresented: $showingDuplicate) {
                if let project {
                    DuplicateAgentSheet(source: project) { finish in
                        handleDuplicateFinished(finish)
                    }
                }
            }
            .sheet(isPresented: $showingAvatarEditor) {
                if let project {
                    AgentAvatarEditorSheet(project: project)
                }
            }
            .sheet(isPresented: $showingModelChange, onDismiss: {
                modelSummaryEpoch += 1
            }) {
                // Same sheet as chat: edits the *effective* profile (global or server override).
                // Full Server AI locks Change while "Use Global Defaults" is on — bad for Abilities.
                // OpenCodeChatModelChangeSheet also links to Providers & connection for OAuth/setup.
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
                                    .accessibilityIdentifier("abilities-model-close-button")
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("agent-abilities-root")
    }

    // MARK: - Sections

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let project {
                    HStack(alignment: .center, spacing: 14) {
                        Button {
                            showingAvatarEditor = true
                        } label: {
                            AgentAvatarView(project: project, size: 64)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Change avatar")
                        .accessibilityIdentifier("abilities-avatar-button")

                        VStack(alignment: .leading, spacing: 4) {
                            Text(agentLabel)
                                .font(.headline)
                                .accessibilityIdentifier("abilities-agent-label")

                            Text(openCodeModelSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("abilities-model-summary")

                            Text(avatarStatusLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 16) {
                    overviewStat(title: "Skills", value: "\(enabledSkillsCount)")
                    overviewStat(title: "MCP", value: mcpCountLabel)
                    overviewStat(title: "Rules", value: rulesStatus.shortLabel)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Overview")
        }
    }

    private var avatarStatusLabel: String {
        guard let project else { return "Monogram" }
        switch project.avatarKind {
        case .emoji:
            return "Emoji avatar"
        case .image:
            return "Image avatar"
        case .none:
            return "Tap to set avatar"
        }
    }

    private var configurationSection: some View {
        Section {
            NavigationLink {
                AgentRulesView(embedsInNavigationStack: false)
            } label: {
                abilitiesRow(
                    title: "Personality",
                    subtitle: "Behavioral rules in AGENTS.md",
                    systemImage: "doc.text",
                    value: rulesStatus.detailLabel
                )
            }
            .accessibilityIdentifier("abilities-personality-link")

            NavigationLink {
                AgentSkillsPickerView(embedsInNavigationStack: false)
            } label: {
                abilitiesRow(
                    title: "Skills",
                    subtitle: "Enable global skills for this agent",
                    systemImage: "wand.and.stars",
                    value: enabledSkillsCount == 0 ? "None" : "\(enabledSkillsCount)"
                )
            }
            .accessibilityIdentifier("abilities-skills-link")

            NavigationLink {
                MCPServersListView(embedsInNavigationStack: false)
            } label: {
                abilitiesRow(
                    title: "MCP Servers",
                    subtitle: "Tools and data sources for the agent",
                    systemImage: "server.rack",
                    value: mcpCountLabel
                )
            }
            .accessibilityIdentifier("abilities-mcp-link")

            NavigationLink {
                PermissionsListView(embedsInNavigationStack: false)
            } label: {
                abilitiesRow(
                    title: "Permissions",
                    subtitle: "Tool approval defaults for this agent",
                    systemImage: "checkmark.shield",
                    value: nil
                )
            }
            .accessibilityIdentifier("abilities-permissions-link")

            NavigationLink {
                AgentEnvironmentVariablesView(embedsInNavigationStack: false)
            } label: {
                abilitiesRow(
                    title: "Environment",
                    subtitle: "Per-agent environment variables",
                    systemImage: "terminal",
                    value: environmentVariablesCount == 0 ? "None" : "\(environmentVariablesCount)"
                )
            }
            .accessibilityIdentifier("abilities-environment-link")

            Button {
                showingModelChange = true
            } label: {
                abilitiesRow(
                    title: "Model",
                    subtitle: "Provider, model, and thinking",
                    systemImage: "cpu",
                    value: openCodeModelSummary
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("abilities-model-button")
        } header: {
            Text("Configure")
        }
    }

    private var tipSection: some View {
        Section {
            Text(
                "The agent can also update personality, skills, and MCP by editing project files "
                    + "(`AGENTS.md`, `.opencode/skills`, OpenCode MCP config). Changes appear here after refresh."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("abilities-file-tip")
        }
    }

    // MARK: - Row helpers

    private func overviewStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func abilitiesRow(
        title: String,
        subtitle: String,
        systemImage: String,
        value: String?
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let value, !value.isEmpty {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Data

    private var agentLabel: String {
        guard let project else { return "Agent" }
        if let server = projectContext.activeServer {
            return "\(project.displayTitle)@\(server.name)"
        }
        return project.displayTitle
    }

    private var mcpCountLabel: String {
        if isLoadingMCP && mcpServerCount == nil {
            return "…"
        }
        if let mcpServerCount {
            return "\(mcpServerCount)"
        }
        return "—"
    }

    /// Compact provider · model · thinking label (same source as chat overflow menu).
    private var openCodeModelSummary: String {
        _ = modelSummaryEpoch
        guard let serverId = project?.serverId else {
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

    @MainActor
    private func refreshOverview() async {
        guard let project else {
            mcpServerCount = nil
            rulesStatus = .unknown
            return
        }

        await AgentAvatarService.shared.refresh(for: project, modelContext: modelContext)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadMCPCount(for: project) }
            group.addTask { await self.loadRulesStatus(for: project) }
            group.addTask {
                try? await CodingAgentMCPService.shared.ensureManagedAvatarServerIfNeeded(for: project)
            }
        }
    }

    @MainActor
    private func loadMCPCount(for project: RemoteProject) async {
        isLoadingMCP = true
        defer { isLoadingMCP = false }
        do {
            let servers = try await CodingAgentMCPService.shared.fetchServers(for: project)
            mcpServerCount = servers.count
        } catch {
            // Keep last known count if refresh fails.
            if mcpServerCount == nil {
                mcpServerCount = nil
            }
            SSHLogger.log("Abilities: failed to load MCP count: \(error)", level: .debug)
        }
    }

    @MainActor
    private func loadRulesStatus(for project: RemoteProject) async {
        let viewModel = AgentRulesViewModel()
        await viewModel.load(for: project)
        if viewModel.loadErrorMessage != nil {
            rulesStatus = .error
        } else if viewModel.isMissingFile || viewModel.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rulesStatus = .empty
        } else {
            rulesStatus = .configured
        }
    }

    private func handleDuplicateFinished(_ finish: DuplicateAgentFinish) {
        showingDuplicate = false
        guard finish.shouldOpen else { return }
        let cloneId = finish.projectId
        let descriptor = FetchDescriptor<RemoteProject>(
            predicate: #Predicate { project in
                project.id == cloneId
            }
        )
        if let clone = try? modelContext.fetch(descriptor).first {
            ProjectContext.shared.setActiveProject(clone)
        }
    }
}

// MARK: - Rules overview

private enum RulesOverviewStatus {
    case unknown
    case empty
    case configured
    case error

    var shortLabel: String {
        switch self {
        case .unknown: return "…"
        case .empty: return "None"
        case .configured: return "Set"
        case .error: return "—"
        }
    }

    var detailLabel: String {
        switch self {
        case .unknown: return "…"
        case .empty: return "Not set"
        case .configured: return "AGENTS.md"
        case .error: return "Unavailable"
        }
    }
}

#Preview {
    AgentAbilitiesView()
        .modelContainer(for: [RemoteProject.self, Server.self, AgentSkill.self, AgentSkillAssignment.self], inMemory: true)
}
