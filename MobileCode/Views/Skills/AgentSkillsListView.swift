//
//  AgentSkillsListView.swift
//  CodeAgentsMobile
//
//  Purpose: Manage global agent skills stored on this device
//

import SwiftUI
import SwiftData

struct AgentSkillsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\AgentSkill.name, order: .forward)]) private var skills: [AgentSkill]
    @Query private var assignments: [AgentSkillAssignment]

    @State private var showingMarketplaceInstall = false
    @State private var showingGitHubInstall = false
    @State private var showError = false
    @State private var errorMessage = ""

    private var usageBySkill: [String: Int] {
        Dictionary(grouping: assignments, by: { $0.skillSlug }).mapValues { $0.count }
    }

    var body: some View {
        Group {
            if skills.isEmpty {
                ContentUnavailableView {
                    Label("No Skills Yet", systemImage: "sparkles")
                } description: {
                    Text("Install a skill from a marketplace or a GitHub folder.")
                } actions: {
                    addButtons
                }
            } else {
                List {
                    Section {
                        GlassInfoCard(title: "Global Skills",
                                      subtitle: "Install once, then add to any agent.",
                                      systemImage: "sparkles")
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            .listRowBackground(Color.clear)
                    }

                    Section("Skills") {
                        ForEach(skills) { skill in
                            NavigationLink {
                                AgentSkillDetailView(skill: skill)
                            } label: {
                                AgentSkillRow(skill: skill,
                                              usageCount: usageBySkill[skill.slug] ?? 0)
                            }
                        }
                        .onDelete(perform: deleteSkills)
                    }

                    Section("Marketplaces") {
                        NavigationLink {
                            SkillMarketplaceSourcesView()
                        } label: {
                            Label("Manage Skill Marketplaces", systemImage: "shippingbox")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Agent Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            }
        }
        .sheet(isPresented: $showingMarketplaceInstall) {
            SkillMarketplaceInstallSheet(onInstall: { _ in })
        }
        .sheet(isPresented: $showingGitHubInstall) {
            SkillAddFromGitHubSheet(onInstall: { _ in })
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
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

    private func deleteSkills(at offsets: IndexSet) {
        let service = SkillLibraryService.shared
        let skillsToDelete = offsets.map { skills[$0] }

        for skill in skillsToDelete {
            do {
                try service.deleteSkillDirectory(for: skill.slug)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }

            let relatedAssignments = assignments.filter { $0.skillSlug == skill.slug }
            for assignment in relatedAssignments {
                modelContext.delete(assignment)
            }
            modelContext.delete(skill)
        }
    }
}

private struct AgentSkillRow: View {
    let skill: AgentSkill
    let usageCount: Int

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
            if usageCount > 0 {
                Text("Used by \(usageCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var sourceLabel: String {
        var base: String
        switch skill.source {
        case .marketplace:
            base = "Marketplace"
        case .github:
            base = "GitHub"
        case .unknown:
            base = "Unknown"
        }
        if let author = skill.author, !author.isEmpty {
            return "\(base) · \(author)"
        }
        return base
    }
}

#Preview {
    NavigationStack {
        AgentSkillsListView()
    }
}
