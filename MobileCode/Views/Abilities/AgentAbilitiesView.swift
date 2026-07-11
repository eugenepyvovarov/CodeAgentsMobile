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
    @StateObject private var projectContext = ProjectContext.shared

    @Query private var skillAssignments: [AgentSkillAssignment]
    @Query(sort: [SortDescriptor(\AgentEnvironmentVariable.key, order: .forward)])
    private var allEnvironmentVariables: [AgentEnvironmentVariable]

    @State private var mcpServerCount: Int?
    @State private var isLoadingMCP = false
    @State private var showingModelChange = false
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
            }
            .task(id: project?.id) {
                await refreshOverview()
            }
            .refreshable {
                await refreshOverview()
            }
            .sheet(isPresented: $showingModelChange, onDismiss: {
                modelSummaryEpoch += 1
            }) {
                if let server = projectContext.activeServer {
                    OpenCodeChatModelChangeSheet(server: server)
                }
            }
        }
        .accessibilityIdentifier("agent-abilities-root")
    }

    // MARK: - Sections

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(agentLabel)
                    .font(.headline)
                    .accessibilityIdentifier("abilities-agent-label")

                Text(openCodeModelSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("abilities-model-summary")

                HStack(spacing: 16) {
                    overviewStat(title: "Skills", value: "\(enabledSkillsCount)")
                    overviewStat(title: "MCP", value: mcpCountLabel)
                    overviewStat(title: "Rules", value: rulesStatus.shortLabel)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        } header: {
            Text("Overview")
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

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadMCPCount(for: project) }
            group.addTask { await self.loadRulesStatus(for: project) }
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
