//
//  SkillMarketplaceSourcesView.swift
//  CodeAgentsMobile
//
//  Purpose: Manage skill marketplace sources
//

import SwiftUI
import SwiftData

struct SkillMarketplaceSourcesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\SkillMarketplaceSource.displayName, order: .forward)]) private var sources: [SkillMarketplaceSource]

    @State private var showingAddSheet = false
    @State private var addURLDraft = ""
    @State private var addNameDraft = ""
    @State private var editingSource: SkillMarketplaceSource?
    @State private var editURLDraft = ""
    @State private var editNameDraft = ""
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        List {
            Section {
                if sources.isEmpty {
                    Text("No marketplaces added yet.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(sources) { source in
                        Button {
                            startEditing(source)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.displayName)
                                    .font(.headline)
                                Text("\(source.owner)/\(source.repo)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteSources)
                }
            } footer: {
                Text("Marketplace sources are shared across all agents.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Skill Marketplaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    errorMessage = nil
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            NavigationStack {
                Form {
                    Section("Marketplace URL") {
                        TextField("https://github.com/owner/repo", text: $addURLDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Display Name") {
                        TextField("Optional name", text: $addNameDraft)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundColor(.red)
                        }
                    }
                }
                .navigationTitle("Add Marketplace")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            addURLDraft = ""
                            addNameDraft = ""
                            errorMessage = nil
                            showingAddSheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { addMarketplace() }
                            .disabled(addURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(item: $editingSource) { source in
            NavigationStack {
                Form {
                    Section("Marketplace URL") {
                        TextField("https://github.com/owner/repo", text: $editURLDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("Display Name") {
                        TextField("Optional name", text: $editNameDraft)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundColor(.red)
                        }
                    }
                }
                .navigationTitle("Edit Marketplace")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            editURLDraft = ""
                            editNameDraft = ""
                            errorMessage = nil
                            editingSource = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { updateMarketplace(source) }
                            .disabled(editURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
    }

    private func addMarketplace() {
        do {
            let repository = try SkillMarketplaceService.parseGitHubRepository(from: addURLDraft)
            let normalizedKey = "\(repository.owner)/\(repository.repo)".lowercased()

            guard !sources.contains(where: { $0.normalizedKey == normalizedKey }) else {
                errorMessage = "Marketplace already added."
                showError = true
                return
            }

            let trimmedName = addNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmedName.isEmpty ? "\(repository.owner)/\(repository.repo)" : trimmedName
            let source = SkillMarketplaceSource(owner: repository.owner,
                                                repo: repository.repo,
                                                displayName: displayName)
            modelContext.insert(source)
            addURLDraft = ""
            addNameDraft = ""
            errorMessage = nil
            showingAddSheet = false
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func startEditing(_ source: SkillMarketplaceSource) {
        errorMessage = nil
        editURLDraft = "https://github.com/\(source.owner)/\(source.repo)"
        editNameDraft = source.displayName
        editingSource = source
    }

    private func updateMarketplace(_ source: SkillMarketplaceSource) {
        do {
            let repository = try SkillMarketplaceService.parseGitHubRepository(from: editURLDraft)
            let normalizedKey = "\(repository.owner)/\(repository.repo)".lowercased()

            let hasConflict = sources.contains {
                $0.normalizedKey == normalizedKey && $0.id != source.id
            }
            guard !hasConflict else {
                errorMessage = "Marketplace already added."
                showError = true
                return
            }

            let trimmedName = editNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = trimmedName.isEmpty ? "\(repository.owner)/\(repository.repo)" : trimmedName
            source.owner = repository.owner
            source.repo = repository.repo
            source.displayName = displayName
            source.markUpdated()

            editURLDraft = ""
            editNameDraft = ""
            errorMessage = nil
            editingSource = nil
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteSources(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sources[index])
        }
    }
}

#Preview {
    NavigationStack {
        SkillMarketplaceSourcesView()
    }
}
