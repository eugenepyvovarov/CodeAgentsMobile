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
    let onSelect: (OpenCodeProviderChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(filteredChoices) { choice in
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
                        } else if !choice.isCustom && choice.id.caseInsensitiveCompare(selectedProviderID) == .orderedSame {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle(searchTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search providers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var filteredChoices: [OpenCodeProviderChoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return choices }
        return choices.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }
}
