//
//  OpenCodeProviderPickerSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Searchable sheet for selecting an OpenCode AI provider
//

import SwiftUI

struct OpenCodeProviderPickerSheet: View {
    let choices: [OpenCodeProviderChoice]
    let selectedProviderID: String
    let searchTitle: String
    /// When true (default), only providers with auth / connected status (+ custom "Other").
    var preferAuthenticatedOnly: Bool = true
    let onSelect: (OpenCodeProviderChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showOnlyWithAuth: Bool

    init(
        choices: [OpenCodeProviderChoice],
        selectedProviderID: String,
        searchTitle: String,
        preferAuthenticatedOnly: Bool = true,
        onSelect: @escaping (OpenCodeProviderChoice) -> Void
    ) {
        self.choices = choices
        self.selectedProviderID = selectedProviderID
        self.searchTitle = searchTitle
        self.preferAuthenticatedOnly = preferAuthenticatedOnly
        self.onSelect = onSelect
        let hasAnyAuth = choices.contains { $0.isConnected && !$0.isCustom }
        _showOnlyWithAuth = State(initialValue: preferAuthenticatedOnly && hasAnyAuth)
    }

    var body: some View {
        NavigationStack {
            List {
                if hasAuthenticatedProviders {
                    Section {
                        Toggle("Only with auth", isOn: $showOnlyWithAuth)
                            .accessibilityIdentifier("opencode-ai-provider-auth-filter-toggle")
                    }
                }

                if filteredChoices.isEmpty {
                    ContentUnavailableView(
                        "No providers",
                        systemImage: "magnifyingglass",
                        description: Text(emptyStateDescription)
                    )
                } else {
                    Section {
                        ForEach(filteredChoices) { choice in
                            Button {
                                onSelect(choice)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: choice.systemImage)
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(choice.name)
                                            .foregroundColor(.primary)
                                        Text(choice.subtitle)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    if choice.isConnected {
                                        Image(systemName: "checkmark.seal.fill")
                                            .foregroundStyle(.green)
                                    } else if !choice.isCustom,
                                              choice.id.caseInsensitiveCompare(selectedProviderID) == .orderedSame {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text(listFooter)
                    }
                }
            }
            .navigationTitle(searchTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by name or id")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var hasAuthenticatedProviders: Bool {
        choices.contains { $0.isConnected && !$0.isCustom }
    }

    private var scopedChoices: [OpenCodeProviderChoice] {
        let base: [OpenCodeProviderChoice]
        if showOnlyWithAuth, hasAuthenticatedProviders {
            // Keep custom "Other" so users can still add a new endpoint.
            base = choices.filter { $0.isConnected || $0.isCustom }
        } else {
            base = choices
        }
        return base.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected {
                return lhs.isConnected && !rhs.isConnected
            }
            if lhs.isCustom != rhs.isCustom {
                return !lhs.isCustom && rhs.isCustom
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var filteredChoices: [OpenCodeProviderChoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scopedChoices }
        return scopedChoices.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private var emptyStateDescription: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No providers match “\(searchText)”."
        }
        if showOnlyWithAuth {
            return "No authenticated providers yet. Turn off “Only with auth” to browse all."
        }
        return "OpenCode did not report any providers."
    }

    private var listFooter: String {
        if showOnlyWithAuth, hasAuthenticatedProviders {
            return "Showing providers with credentials on this server. Search or turn off the filter to see more."
        }
        return "Search by provider name or id. Green seal = already authorized on the server."
    }
}
