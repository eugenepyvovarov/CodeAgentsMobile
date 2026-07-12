//
//  AgentRulesView.swift
//  CodeAgentsMobile
//
//  Purpose: Personality hub — browse and open linked rules aspects that assemble into AGENTS.md.
//

import SwiftUI

struct AgentRulesView: View {
    /// When false, embed in a parent `NavigationStack` (Abilities tab).
    var embedsInNavigationStack: Bool = true

    // MARK: - State

    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var rulesViewModel = AgentRulesViewModel()
    @AppStorage("agentRulesShowsInfoCard") private var showsInfoCard = true

    // MARK: - Derived

    private var agentLabel: String? {
        projectContext.activeProject?.displayTitle
    }

    private var rulesSubtitle: String {
        if let agentLabel {
            return "How \(agentLabel) should behave. Each aspect is its own file; OpenCode reads assembled AGENTS.md."
        }
        return "How this agent should behave. Each aspect is its own file; OpenCode reads assembled AGENTS.md."
    }

    // MARK: - Body

    var body: some View {
        Group {
            if embedsInNavigationStack {
                NavigationStack { rootContent }
            } else {
                rootContent
            }
        }
        .task(id: projectContext.activeProject?.id) {
            await loadRules()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var rootContent: some View {
        Group {
            if projectContext.activeProject == nil {
                ContentUnavailableView {
                    Label("No Active Agent", systemImage: "person.crop.circle.badge.xmark")
                } description: {
                    Text("Select an agent to view and edit personality.")
                }
            } else {
                List {
                    if showsInfoCard {
                        introSection
                    }
                    statusSections
                    aspectsSection
                    onDiskSection
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Personality")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
    }

    private var introSection: some View {
        Section {
            GlassInfoCard(
                title: "Personality",
                subtitle: rulesSubtitle,
                systemImage: "person.text.rectangle"
            )
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if rulesViewModel.isLoading {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading aspects…")
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let loadError = rulesViewModel.loadErrorMessage {
            Section {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        if rulesViewModel.didMigrateFromLegacy,
           let source = rulesViewModel.migrationSourceRelativePath {
            Section {
                Label(
                    "Split \(source) into linked files under `.codeagents/rules/`. OpenCode still reads AGENTS.md.",
                    systemImage: "arrow.triangle.branch"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var aspectsSection: some View {
        Section {
            ForEach(AgentRulesAspect.allCases) { aspect in
                NavigationLink {
                    AgentRulesAspectEditorView(
                        aspect: aspect,
                        viewModel: rulesViewModel
                    )
                } label: {
                    PersonalityAspectRow(
                        aspect: aspect,
                        draft: rulesViewModel.draft(for: aspect),
                        status: statusLabel(
                            for: rulesViewModel.draft(for: aspect),
                            aspect: aspect
                        )
                    )
                }
                .accessibilityIdentifier("rules-aspect-\(aspect.rawValue)")
            }
        } header: {
            Text("Aspects")
        } footer: {
            Text("Saving an aspect rewrites \(rulesViewModel.assembledRulesRelativePath) so OpenCode sees the full ruleset.")
        }
    }

    private var onDiskSection: some View {
        Section {
            PersonalityPathRow(
                title: "Assembled for OpenCode",
                path: AgentProjectFileLayout.rulesPrimaryRelativePath,
                systemImage: "doc.richtext"
            )
            PersonalityPathRow(
                title: "Aspect folder",
                path: AgentProjectFileLayout.rulesDirectoryRelativePath,
                systemImage: "folder"
            )
        } header: {
            Text("On disk")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsInfoCard.toggle()
                }
            } label: {
                Image(systemName: showsInfoCard ? "info.circle.fill" : "info.circle")
            }
            .accessibilityLabel(showsInfoCard ? "Hide personality info" : "Show personality info")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await loadRules() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(rulesViewModel.isLoading || rulesViewModel.isSaving)
            .accessibilityLabel("Reload aspects")
        }
    }

    // MARK: - Helpers

    private func statusLabel(for draft: AgentRulesAspectDraft, aspect: AgentRulesAspect) -> String {
        if draft.hasUnsavedChanges {
            return "Edited"
        }
        if aspect == .codeAgentsUI {
            return draft.isMissingFile ? "Default" : "Custom"
        }
        if draft.isEmpty {
            return "Empty"
        }
        return "Set"
    }

    @MainActor
    private func loadRules() async {
        guard let project = projectContext.activeProject else {
            rulesViewModel.reset()
            return
        }
        await rulesViewModel.load(for: project)
    }
}

// MARK: - Aspect row

private struct PersonalityAspectRow: View {
    let aspect: AgentRulesAspect
    let draft: AgentRulesAspectDraft
    let status: String

    var body: some View {
        HStack(spacing: 14) {
            aspectIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(aspect.displayTitle)
                    .font(.body.weight(.semibold))
                Text(aspect.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(aspect.relativePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            statusChip
        }
        .padding(.vertical, 4)
    }

    private var aspectIcon: some View {
        Image(systemName: aspect.systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(.tint)
            .frame(width: 40, height: 40)
            .modifier(PersonalityGlassIconChrome())
    }

    private var statusChip: some View {
        Text(status)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .modifier(PersonalityStatusChipChrome(emphasized: draft.hasUnsavedChanges || draft.isEmpty))
    }
}

private struct PersonalityPathRow: View {
    let title: String
    let path: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Aspect editor

struct AgentRulesAspectEditorView: View {
    // MARK: - Inputs

    let aspect: AgentRulesAspect
    @ObservedObject var viewModel: AgentRulesViewModel

    // MARK: - State

    @StateObject private var projectContext = ProjectContext.shared
    @FocusState private var editorFocused: Bool

    // MARK: - Derived

    private var draft: AgentRulesAspectDraft {
        viewModel.draft(for: aspect)
    }

    private var binding: Binding<String> {
        Binding(
            get: { viewModel.draft(for: aspect).content },
            set: { viewModel.updateContent($0, for: aspect) }
        )
    }

    private var characterCount: Int {
        draft.content.count
    }

    // MARK: - Body

    var body: some View {
        List {
            tipSection
            editorSection
            if aspect == .personality {
                ideasSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(aspect.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if draft.hasUnsavedChanges || viewModel.isSaving {
                saveBar
            }
        }
        .interactiveDismissDisabled(draft.hasUnsavedChanges)
        .animation(.easeInOut(duration: 0.2), value: draft.hasUnsavedChanges)
    }

    // MARK: - Sections

    private var tipSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lightbulb.max.fill")
                    .foregroundStyle(.yellow.gradient)
                    .font(.title3)
                Text(aspect.tipMarkdown)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .modifier(PersonalityTipChrome())
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var editorSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(aspect.editorPlaceholder)
                        .font(aspect.usesMonospacedEditor ? .system(.body, design: .monospaced) : .body)
                        .foregroundStyle(.secondary.opacity(0.85))
                        .padding(.top, 12)
                        .padding(.leading, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: binding)
                    .font(aspect.usesMonospacedEditor ? .system(.body, design: .monospaced) : .body)
                    .frame(minHeight: aspect == .personality ? 360 : 300)
                    .focused($editorFocused)
                    .textInputAutocapitalization(aspect == .personality ? .sentences : .never)
                    .autocorrectionDisabled(aspect != .personality)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .disabled(viewModel.isLoading || viewModel.isSaving)
                    .accessibilityIdentifier("rules-aspect-editor-\(aspect.rawValue)")
            }
            .padding(4)
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        } header: {
            Text(aspect.displayTitle)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Label(aspect.relativePath, systemImage: "doc")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)

                HStack {
                    if draft.hasUnsavedChanges {
                        Text("Unsaved changes")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(characterCount) characters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let saveError = viewModel.saveErrorMessage {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var ideasSection: some View {
        Section {
            PersonalityIdeaRow(title: "Voice", detail: "Warm and concise, or formal and thorough?")
            PersonalityIdeaRow(title: "Priorities", detail: "What should this agent optimize for first?")
            PersonalityIdeaRow(title: "Boundaries", detail: "Topics, actions, or tools it should refuse?")
        } header: {
            Text("Ideas")
        }
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button("Revert") {
                    viewModel.updateContent(draft.originalContent, for: aspect)
                }
                .disabled(viewModel.isSaving || !draft.hasUnsavedChanges)
                .modifier(PersonalitySecondaryButtonChrome())

                PrimaryGlassButton(action: save) {
                    if viewModel.isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Save aspect", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(viewModel.isLoading || viewModel.isSaving || !draft.hasUnsavedChanges)
                .accessibilityIdentifier("rules-aspect-save-\(aspect.rawValue)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") {
                editorFocused = false
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if draft.hasUnsavedChanges {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .disabled(viewModel.isLoading || viewModel.isSaving)
            }
        }
    }

    // MARK: - Actions

    private func save() {
        guard let project = projectContext.activeProject else { return }
        Task {
            await viewModel.saveAspect(aspect, for: project)
        }
    }
}

// MARK: - Small pieces

private struct PersonalityIdeaRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Glass chrome

private struct PersonalityGlassIconChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.16)),
                    in: .rect(cornerRadius: 12)
                )
        } else {
            content
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct PersonalityStatusChipChrome: ViewModifier {
    var emphasized: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    .regular.tint((emphasized ? Color.orange : Color.accentColor).opacity(0.14)),
                    in: .capsule
                )
        } else {
            content
                .background(
                    (emphasized ? Color.orange.opacity(0.12) : Color(.secondarySystemFill)),
                    in: Capsule(style: .continuous)
                )
        }
    }
}

private struct PersonalityTipChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .padding(14)
                .glassEffect(
                    .regular.tint(Color.yellow.opacity(0.12)),
                    in: .rect(cornerRadius: 16)
                )
        } else {
            content
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct PersonalitySecondaryButtonChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

#Preview {
    AgentRulesView()
}
