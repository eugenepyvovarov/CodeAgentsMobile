//
//  AgentSkillDetailView.swift
//  CodeAgentsMobile
//
//  Purpose: Detail view for a global agent skill
//

import SwiftUI

struct AgentSkillDetailView: View {
    let skill: AgentSkill

    @State private var markdown = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let libraryService = SkillLibraryService.shared

    var body: some View {
        List {
            Section("Details") {
                detailRow(title: "Name", value: SkillNameFormatter.displayName(from: skill.name))
                detailRow(title: "Source", value: sourceLabel)
                if !skill.sourceReference.isEmpty {
                    detailRow(title: "Reference", value: skill.sourceReference)
                }
                if let author = skill.author, !author.isEmpty {
                    detailRow(title: "Author", value: author)
                }
                detailRow(title: "Slug", value: skill.slug)
            }

            Section("Preview") {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading preview...")
                            .foregroundColor(.secondary)
                    }
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.secondary)
                } else {
                    FullMarkdownTextView(text: markdown)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(SkillNameFormatter.displayName(from: skill.name))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadMarkdown()
        }
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

    @ViewBuilder
    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func loadMarkdown() async {
        do {
            let content = try libraryService.loadSkillMarkdown(for: skill.slug)
            await MainActor.run {
                markdown = content
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}

#Preview {
    NavigationStack {
        AgentSkillDetailView(skill: AgentSkill(slug: "demo-skill", name: "Demo Skill"))
    }
}
