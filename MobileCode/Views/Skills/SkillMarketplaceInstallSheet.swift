//
//  SkillMarketplaceInstallSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Browse marketplaces and install skills
//

import SwiftUI
import SwiftData

struct SkillMarketplaceInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var sources: [SkillMarketplaceSource]
    @Query private var skills: [AgentSkill]

    let onInstall: (AgentSkill) -> Void

    @State private var selectedSource: SkillMarketplaceSource?
    @State private var listing: SkillMarketplaceListing?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var installingPluginId: String?

    private let marketplaceService = SkillMarketplaceService()
    private let libraryService = SkillLibraryService.shared
    private let fileManager = FileManager.default

    private var installedPluginKeys: Set<String> {
        Set(skills.filter { $0.source == .marketplace }.map { $0.sourceReference.lowercased() })
    }

    var body: some View {
        NavigationStack {
            Group {
                if sources.isEmpty {
                    ContentUnavailableView {
                        Label("No Marketplaces", systemImage: "shippingbox")
                    } description: {
                        Text("Add a marketplace before installing skills.")
                    } actions: {
                        NavigationLink("Manage Marketplaces") {
                            SkillMarketplaceSourcesView()
                        }
                    }
                } else {
                    List {
                        Section("Marketplaces") {
                            ForEach(sources) { source in
                                Button {
                                    selectedSource = source
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(source.displayName)
                                                .font(.headline)
                                            Text("\(source.owner)/\(source.repo)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if selectedSource?.id == source.id {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Section("Skills") {
                            if isLoading {
                                HStack {
                                    ProgressView()
                                    Text("Loading marketplace...")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            } else if let listing {
                                ForEach(listing.document.plugins) { plugin in
                                    let pluginKey = marketplacePluginKey(for: plugin, listing: listing)
                                    SkillMarketplacePluginRow(plugin: plugin,
                                                              isInstalling: installingPluginId == plugin.id,
                                                              isInstalled: installedPluginKeys.contains(pluginKey)) {
                                        install(plugin, from: listing)
                                    }
                                }
                            } else {
                                Text("Select a marketplace to load skills.")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Skills Marketplace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if selectedSource == nil {
                    selectedSource = sources.first
                }
                if let selectedSource {
                    Task { await loadMarketplace(for: selectedSource) }
                }
            }
            .onChange(of: selectedSource) { _, newValue in
                if let source = newValue {
                    Task { await loadMarketplace(for: source) }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
        }
    }

    private func loadMarketplace(for source: SkillMarketplaceSource) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let listing = try await marketplaceService.fetchMarketplace(owner: source.owner, repo: source.repo)
            await MainActor.run {
                self.listing = listing
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
                listing = nil
            }
        }
    }

    private func install(_ plugin: SkillMarketplacePlugin, from listing: SkillMarketplaceListing) {
        guard installingPluginId == nil else { return }
        guard !installedPluginKeys.contains(marketplacePluginKey(for: plugin, listing: listing)) else { return }
        installingPluginId = plugin.id

        Task {
            defer { installingPluginId = nil }

            do {
                let existingSlugs = Set(skills.map { $0.slug })
                let download = try await marketplaceService.downloadSkillFolder(plugin: plugin, listing: listing)
                defer { try? fileManager.removeItem(at: download.cleanupRoot) }

                let installResult = try libraryService.installSkill(from: download.skillRoot,
                                                                    suggestedName: plugin.name,
                                                                    suggestedSummary: plugin.description,
                                                                    existingSlugs: existingSlugs)
                let skill = AgentSkill(slug: installResult.slug,
                                       name: installResult.name,
                                       summary: installResult.summary,
                                       author: plugin.author?.name, source: .marketplace,
                                       sourceReference: marketplacePluginKey(for: plugin, listing: listing))
                await MainActor.run {
                    modelContext.insert(skill)
                    onInstall(skill)
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func marketplacePluginKey(for plugin: SkillMarketplacePlugin, listing: SkillMarketplaceListing) -> String {
        "\(listing.owner)/\(listing.repo)#\(plugin.name)".lowercased()
    }
}

private struct SkillMarketplacePluginRow: View {
    let plugin: SkillMarketplacePlugin
    let isInstalling: Bool
    let isInstalled: Bool
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(SkillNameFormatter.displayName(from: plugin.name))
                    .font(.headline)
                Spacer()
                if isInstalling {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if isInstalled {
                    Text("Installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Button("Install") { onInstall() }
                        .buttonStyle(.bordered)
                }
            }

            if let description = plugin.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                if let category = plugin.category, !category.isEmpty {
                    Text(category)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let author = plugin.author?.name, !author.isEmpty {
                    Text("by \(author)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    SkillMarketplaceInstallSheet(onInstall: { _ in })
}
