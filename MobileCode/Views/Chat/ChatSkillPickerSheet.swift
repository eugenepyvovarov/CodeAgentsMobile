//
//  ChatSkillPickerSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Pick an agent-enabled skill to prepend as /<skill> to the next chat message.
//

import SwiftUI
import SwiftData

struct ChatSkillPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\AgentSkill.name, order: .forward)]) private var skills: [AgentSkill]
    @Query private var assignments: [AgentSkillAssignment]

    let projectId: UUID
    let selectedSkillSlug: String?
    let onSelect: (AgentSkill?) -> Void

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        HStack {
                            Label("No Skill", systemImage: "xmark.circle")
                            Spacer()
                            if selectedSkillSlug == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                } footer: {
                    Text("Selected skill is sent as a hint; Claude decides whether to invoke it.")
                }

                Section("Enabled Skills") {
                    if filteredEnabledSkills.isEmpty {
                        Text("No skills enabled for this agent.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredEnabledSkills) { skill in
                            Button {
                                onSelect(skill)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(SkillNameFormatter.displayName(from: skill.name))
                                            .font(.headline)
                                        Text(sourceLabel(for: skill))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedSkillSlug == skill.slug {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select Skill")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Private

    private var assignedSlugs: Set<String> {
        let slugs = assignments
            .filter { $0.projectId == projectId }
            .map { $0.skillSlug }
        return Set(slugs)
    }

    private var enabledSkills: [AgentSkill] {
        skills.filter { assignedSlugs.contains($0.slug) }
    }

    private var filteredEnabledSkills: [AgentSkill] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return enabledSkills }
        let query = trimmed.lowercased()

        return enabledSkills.filter { skill in
            if skill.slug.lowercased().contains(query) { return true }
            if skill.name.lowercased().contains(query) { return true }
            if let author = skill.author?.lowercased(), author.contains(query) { return true }
            if let summary = skill.summary?.lowercased(), summary.contains(query) { return true }
            return false
        }
    }

    private func sourceLabel(for skill: AgentSkill) -> String {
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
    ChatSkillPickerSheet(projectId: UUID(), selectedSkillSlug: nil, onSelect: { _ in })
}
