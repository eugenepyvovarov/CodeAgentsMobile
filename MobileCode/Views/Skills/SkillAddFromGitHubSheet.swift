//
//  SkillAddFromGitHubSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Install a skill from a GitHub folder URL
//

import SwiftUI
import SwiftData

struct SkillAddFromGitHubSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var skills: [AgentSkill]

    let onInstall: (AgentSkill) -> Void

    @State private var urlInput = ""
    @State private var preview: SkillFrontMatterSummary?
    @State private var resolvedReference: SkillGitHubFolderReference?
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""

    private let marketplaceService = SkillMarketplaceService()
    private let libraryService = SkillLibraryService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub Folder URL") {
                    TextField("https://github.com/owner/repo/tree/main/path", text: $urlInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let preview {
                    Section("Preview") {
                        if let name = preview.name {
                            Text(SkillNameFormatter.displayName(from: name))
                                .font(.headline)
                        }
                        if let description = preview.description {
                            Text(description)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add from GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install") { installSkill() }
                        .disabled(resolvedReference == nil || isLoading)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Preview") { loadPreview() }
                        .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.1))
                }
            }
            .onChange(of: urlInput) { _, _ in
                preview = nil
                resolvedReference = nil
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func loadPreview() {
        isLoading = true
        preview = nil
        resolvedReference = nil

        Task {
            do {
                let reference = try SkillMarketplaceService.parseGitHubFolderURL(from: urlInput)
                let content = try await marketplaceService.fetchSkillContent(reference: reference)
                let summary = libraryService.parseFrontMatter(content)
                await MainActor.run {
                    preview = summary
                    resolvedReference = reference
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }

    private func installSkill() {
        guard let reference = resolvedReference else { return }
        isLoading = true

        Task {
            do {
                let existingSlugs = Set(skills.map { $0.slug })
                let download = try await marketplaceService.downloadSkillFolder(reference: reference)
                defer { try? FileManager.default.removeItem(at: download.cleanupRoot) }

                let installResult = try libraryService.installSkill(from: download.skillRoot,
                                                                    suggestedName: preview?.name,
                                                                    suggestedSummary: preview?.description,
                                                                    existingSlugs: existingSlugs)
                let skill = AgentSkill(slug: installResult.slug,
                                       name: installResult.name,
                                       summary: installResult.summary,
                                       source: .github,
                                       sourceReference: urlInput.trimmingCharacters(in: .whitespacesAndNewlines))
                await MainActor.run {
                    modelContext.insert(skill)
                    onInstall(skill)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }
}

#Preview {
    SkillAddFromGitHubSheet(onInstall: { _ in })
}
