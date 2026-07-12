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
    // MARK: - Environment / queries

    @Environment(\.modelContext) private var modelContext
    @StateObject private var projectContext = ProjectContext.shared

    @Query private var skillAssignments: [AgentSkillAssignment]
    @Query(sort: [SortDescriptor(\AgentEnvironmentVariable.key, order: .forward)])
    private var allEnvironmentVariables: [AgentEnvironmentVariable]

    // MARK: - State

    @State private var mcpServerCount: Int?
    @State private var isLoadingMCP = false
    @State private var showingModelChange = false
    @State private var showingDuplicate = false
    @State private var showingAvatarEditor = false
    @State private var showingEditAgent = false
    @State private var modelSummaryEpoch = 0
    @State private var rulesStatus: RulesOverviewStatus = .unknown

    // MARK: - Derived

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

    private var agentLabel: String {
        project?.displayTitle ?? "Agent"
    }

    private var serverLabel: String {
        projectContext.activeServer?.name ?? "No server"
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



    // MARK: - Body

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
            .toolbar { toolbarContent }
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
            .sheet(isPresented: $showingEditAgent) {
                if let project {
                    EditProjectSheet(project: project)
                }
            }
            .sheet(isPresented: $showingModelChange, onDismiss: {
                modelSummaryEpoch += 1
            }) {
                modelChangeSheet
            }
        }
        .accessibilityIdentifier("agent-abilities-root")
    }

    // MARK: - Sections

    @ViewBuilder
    private var overviewSection: some View {
        if let project {
            Section {
                AbilitiesOverviewCard(
                    project: project,
                    agentLabel: agentLabel,
                    modelSummary: openCodeModelSummary,
                    serverLabel: serverLabel,
                    skillsCount: enabledSkillsCount,
                    mcpLabel: mcpCountLabel,
                    rulesLabel: rulesStatus.shortLabel,
                    onAvatarTap: { showingAvatarEditor = true },
                    onEditTap: { showingEditAgent = true }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } header: {
                Text("Overview")
            }
        }
    }

    private var configurationSection: some View {
        Section {
            NavigationLink {
                AgentRulesView(embedsInNavigationStack: false)
            } label: {
                abilitiesRow(
                    title: "Personality",
                    subtitle: "Aspects linked into AGENTS.md",
                    systemImage: "person.text.rectangle",
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    @ViewBuilder
    private var modelChangeSheet: some View {
        // Same sheet as chat: edits the *effective* profile (global or server override).
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

    // MARK: - Row helpers

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

    @MainActor
    private func refreshOverview() async {
        guard let project else {
            mcpServerCount = nil
            rulesStatus = .unknown
            return
        }

        await AgentAvatarService.shared.refresh(for: project, modelContext: modelContext)
        await withTaskGroup(of: Void.self) { group in
            // Count is a fast config+status read — never provision/connect here.
            group.addTask { await self.loadMCPCount(for: project) }
            group.addTask { await self.loadRulesStatus(for: project) }
            // Avatar ensure is best-effort background; skipped when already provisioned.
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
        } else if viewModel.hasPersonalityContent {
            rulesStatus = .configured
        } else {
            rulesStatus = .empty
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

// MARK: - Overview card

private struct AbilitiesOverviewCard: View {
    let project: RemoteProject
    let agentLabel: String
    let modelSummary: String
    let serverLabel: String
    let skillsCount: Int
    let mcpLabel: String
    let rulesLabel: String
    let onAvatarTap: () -> Void
    let onEditTap: () -> Void

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 16) {
            identityRow
            statsRow
            editIdentityButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)

        Group {
            if #available(iOS 26.0, *) {
                card
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.12)),
                        in: .rect(cornerRadius: 20)
                    )
            } else {
                card
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color(.separator).opacity(0.35), lineWidth: 0.5)
                    )
            }
        }
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: onAvatarTap) {
                AgentAvatarView(project: project, size: 68)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.system(size: 18))
                            .offset(x: 2, y: 2)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change avatar")
            .accessibilityIdentifier("abilities-avatar-button")
            .modifier(AbilitiesInteractiveGlassCircle())

            VStack(alignment: .leading, spacing: 6) {
                Text(agentLabel)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .accessibilityIdentifier("abilities-agent-label")

                if let overviewDescription = project.overviewDescriptionText {
                    Text(overviewDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("abilities-agent-description")
                } else {
                    Text("No overview description")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "cpu")
                        .imageScale(.small)
                    Text(modelSummary)
                        .lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("abilities-model-summary")

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "server.rack")
                        .imageScale(.small)
                    Text(serverLabel)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("abilities-server-label")
            }
        }
    }

    private var statsRow: some View {
        let chips = HStack(spacing: 10) {
            AbilitiesStatChip(title: "Skills", value: "\(skillsCount)", systemImage: "wand.and.stars")
            AbilitiesStatChip(title: "MCP", value: mcpLabel, systemImage: "server.rack")
            AbilitiesStatChip(title: "Rules", value: rulesLabel, systemImage: "person.text.rectangle")
        }

        return Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 10) {
                    chips
                }
            } else {
                chips
            }
        }
    }

    private var editIdentityButton: some View {
        Button(action: onEditTap) {
            Label(
                project.overviewDescriptionText == nil
                    ? "Rename or add description"
                    : "Edit name or description",
                systemImage: "pencil.line"
            )
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("abilities-edit-agent-row")
        .modifier(AbilitiesGlassButtonStyle())
    }
}

private struct AbilitiesStatChip: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.1)),
                        in: .rect(cornerRadius: 14)
                    )
            } else {
                content
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

private struct AbilitiesInteractiveGlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
        }
    }
}

private struct AbilitiesGlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
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
        case .configured: return "Set"
        case .error: return "Unavailable"
        }
    }
}

#Preview {
    AgentAbilitiesView()
        .modelContainer(for: [RemoteProject.self, Server.self, AgentSkill.self, AgentSkillAssignment.self], inMemory: true)
}
