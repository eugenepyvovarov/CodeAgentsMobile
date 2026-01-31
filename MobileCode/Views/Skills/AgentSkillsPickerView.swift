//
//  AgentSkillsPickerView.swift
//  CodeAgentsMobile
//
//  Purpose: Add global skills to the active agent
//

import SwiftUI
import SwiftData

struct AgentSkillsPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var projectContext = ProjectContext.shared

    @Query(sort: [SortDescriptor(\AgentSkill.name, order: .forward)]) private var skills: [AgentSkill]
    @Query private var assignments: [AgentSkillAssignment]

    @State private var showingMarketplaceInstall = false
    @State private var showingGitHubInstall = false
    @State private var syncingSlug: String?
    @State private var showError = false
    @State private var errorMessage = ""

    private let syncService = AgentSkillSyncService.shared

    private var project: RemoteProject? {
        projectContext.activeProject
    }

    private var assignedSlugs: Set<String> {
        guard let project else { return [] }
        let slugs = assignments.filter { $0.projectId == project.id }.map { $0.skillSlug }
        return Set(slugs)
    }

    private var installedSkills: [AgentSkill] {
        skills.filter { assignedSlugs.contains($0.slug) }
    }

    private var availableSkills: [AgentSkill] {
        skills.filter { !assignedSlugs.contains($0.slug) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if project == nil {
                    ContentUnavailableView {
                        Label("No Active Agent", systemImage: "person.crop.circle.badge.xmark")
                    } description: {
                        Text("Select an agent before adding skills.")
                    }
                } else if skills.isEmpty {
                    ContentUnavailableView {
                        Label("No Skills Installed", systemImage: "sparkles")
                    } description: {
                        Text("Add a skill from a marketplace or GitHub to get started.")
                    } actions: {
                        addButtons
                    }
                } else {
                    List {
                        Section {
                            GlassInfoCard(title: "Agent Skills",
                                          subtitle: "Toggle global skills on or off for this agent.",
                                          systemImage: "wand.and.stars")
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                                .listRowBackground(Color.clear)
                        }

                        Section("Installed Skills") {
                            if installedSkills.isEmpty {
                                Text("No skills enabled for this agent yet.")
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(installedSkills) { skill in
                                    AgentSkillToggleRow(skill: skill,
                                                        isSyncing: syncingSlug == skill.slug,
                                                        isEnabled: binding(for: skill))
                                }
                            }
                        }

                        Section("Global Skills") {
                            if availableSkills.isEmpty {
                                Text("All global skills are already enabled.")
                                    .foregroundColor(.secondary)
                            } else {
                                ForEach(availableSkills) { skill in
                                    AgentSkillAddRow(skill: skill,
                                                     isSyncing: syncingSlug == skill.slug) {
                                        addSkillToAgent(skill)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Agent Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingMarketplaceInstall = true
                        } label: {
                            Label("Add from Marketplace", systemImage: "cart")
                        }
                        Button {
                            showingGitHubInstall = true
                        } label: {
                            Label("Add from GitHub URL", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(project == nil)
                }
            }
            .sheet(isPresented: $showingMarketplaceInstall) {
                SkillMarketplaceInstallSheet { skill in
                    addSkillToAgent(skill)
                }
            }
            .sheet(isPresented: $showingGitHubInstall) {
                SkillAddFromGitHubSheet { skill in
                    addSkillToAgent(skill)
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var addButtons: some View {
        VStack(spacing: 12) {
            PrimaryGlassButton(action: { showingMarketplaceInstall = true }) {
                Label("Browse Marketplaces", systemImage: "cart")
            }

            PrimaryGlassButton(action: { showingGitHubInstall = true }) {
                Label("Add from GitHub", systemImage: "link")
            }
        }
    }

    private func addSkillToAgent(_ skill: AgentSkill) {
        toggleSkill(skill, enabled: true)
    }

    private func toggleSkill(_ skill: AgentSkill, enabled: Bool) {
        guard let project else { return }
        guard syncingSlug == nil else { return }
        if enabled, assignedSlugs.contains(skill.slug) { return }
        if !enabled, !assignedSlugs.contains(skill.slug) { return }

        syncingSlug = skill.slug

        Task {
            do {
                if enabled {
                    try await syncService.installSkill(skill, to: project)
                    await MainActor.run {
                        let assignment = AgentSkillAssignment(projectId: project.id, skillSlug: skill.slug)
                        modelContext.insert(assignment)
                    }
                } else {
                    try await syncService.removeSkill(skill, from: project)
                    await MainActor.run {
                        assignments.filter { $0.projectId == project.id && $0.skillSlug == skill.slug }
                            .forEach { modelContext.delete($0) }
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
            await MainActor.run {
                syncingSlug = nil
            }
        }
    }

    private func binding(for skill: AgentSkill) -> Binding<Bool> {
        Binding(get: {
            assignedSlugs.contains(skill.slug)
        }, set: { newValue in
            toggleSkill(skill, enabled: newValue)
        })
    }
}

private struct AgentSkillToggleRow: View {
    let skill: AgentSkill
    let isSyncing: Bool
    let isEnabled: Binding<Bool>

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(SkillNameFormatter.displayName(from: skill.name))
                    .font(.headline)
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isSyncing {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Toggle("", isOn: isEnabled)
                    .labelsHidden()
                    .disabled(isSyncing)
            }
        }
        .padding(.vertical, 2)
    }

    private var sourceLabel: String {
        switch skill.source {
        case .marketplace:
            return "Marketplace"
        case .github:
            return "GitHub"
        case .unknown:
            return "Unknown"
        }
    }
}

private struct AgentSkillAddRow: View {
    let skill: AgentSkill
    let isSyncing: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(SkillNameFormatter.displayName(from: skill.name))
                    .font(.headline)
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isSyncing {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Button("Add") { onAdd() }
                    .buttonStyle(.bordered)
                    .disabled(isSyncing)
            }
        }
        .padding(.vertical, 2)
    }

    private var sourceLabel: String {
        switch skill.source {
        case .marketplace:
            return "Marketplace"
        case .github:
            return "GitHub"
        case .unknown:
            return "Unknown"
        }
    }
}

#Preview {
    AgentSkillsPickerView()
}
