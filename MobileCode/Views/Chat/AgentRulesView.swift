//
//  AgentRulesView.swift
//  CodeAgentsMobile
//
//  Purpose: Edit behavioral rules stored in .claude/CLAUDE.md
//

import SwiftUI

struct AgentRulesView: View {
    @StateObject private var projectContext = ProjectContext.shared
    @StateObject private var rulesViewModel = AgentRulesViewModel()
    @AppStorage("agentRulesShowsInfoCard") private var showsInfoCard = true

    var body: some View {
        NavigationStack {
            Group {
                if projectContext.activeProject == nil {
                    ContentUnavailableView {
                        Label("No Active Agent", systemImage: "person.crop.circle.badge.xmark")
                    } description: {
                        Text("Select an agent to view and edit rules.")
                    }
                } else {
                    List {
                        if showsInfoCard {
                            Section {
                                GlassInfoCard(
                                    title: "Behavioral Rules",
                                    subtitle: rulesSubtitle,
                                    systemImage: "doc.text"
                                )
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }

                        Section {
                            if rulesViewModel.isLoading {
                                ProgressView("Loading rules...")
                            }

                            TextEditor(text: $rulesViewModel.content)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 220)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(rulesViewModel.isLoading || rulesViewModel.isSaving)
                                .overlay(alignment: .topLeading) {
                                    if rulesViewModel.content.isEmpty && !rulesViewModel.isLoading {
                                        Text("Add rules for this agent...")
                                            .foregroundColor(.secondary)
                                            .padding(.top, 8)
                                            .padding(.leading, 4)
                                            .allowsHitTesting(false)
                                    }
                                }

                            if rulesViewModel.isMissingFile {
                                Label("No rules file yet. It will be created when you save.", systemImage: "doc.badge.plus")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if let loadError = rulesViewModel.loadErrorMessage {
                                Text(loadError)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }

                            if let saveError = rulesViewModel.saveErrorMessage {
                                Text(saveError)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }

                            HStack {
                                Button("Reload") {
                                    reloadRules()
                                }
                                .disabled(rulesViewModel.isLoading || rulesViewModel.isSaving)

                                Spacer()

                                Button(rulesViewModel.isSaving ? "Saving..." : "Save") {
                                    saveRules()
                                }
                                .disabled(rulesViewModel.isLoading || rulesViewModel.isSaving || !rulesViewModel.hasUnsavedChanges)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Rules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showsInfoCard.toggle()
                        }
                    } label: {
                        Image(systemName: showsInfoCard ? "info.circle.fill" : "info.circle")
                    }
                    .accessibilityLabel(showsInfoCard ? "Hide rules info" : "Show rules info")
                }
            }
        }
        .onAppear {
            loadRules()
        }
        .onChange(of: projectContext.activeProject?.id) { _, _ in
            loadRules()
        }
    }

    private var rulesSubtitle: String {
        if let agentLabel {
            return "Behavioral rules for \(agentLabel). These are things the agent should care about and not forget. Stored at .claude/CLAUDE.md."
        }
        return "Behavioral rules for the active agent. These are things the agent should care about and not forget. Stored at .claude/CLAUDE.md."
    }

    private var agentLabel: String? {
        guard let project = projectContext.activeProject else { return nil }
        if let server = projectContext.activeServer {
            return "\(project.displayTitle)@\(server.name)"
        }
        return project.displayTitle
    }

    private func loadRules() {
        guard let project = projectContext.activeProject else {
            rulesViewModel.reset()
            return
        }

        Task {
            await rulesViewModel.load(for: project)
        }
    }

    private func reloadRules() {
        guard let project = projectContext.activeProject else {
            rulesViewModel.reset()
            return
        }

        Task {
            await rulesViewModel.load(for: project)
        }
    }

    private func saveRules() {
        guard let project = projectContext.activeProject else { return }

        Task {
            await rulesViewModel.save(for: project)
        }
    }
}

#Preview {
    AgentRulesView()
}
