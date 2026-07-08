//
//  OpenCodeModelPickerSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Searchable sheet for selecting an OpenCode model
//

import SwiftUI

struct OpenCodeModelPickerSheet: View {
    let choices: [OpenCodeModelChoice]
    let selectedModelID: String
    let onSelect: (OpenCodeModelChoice) -> Void

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
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.id)
                                .foregroundColor(.primary)
                            Text(modelSubtitle(for: choice))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if choice.id == selectedModelID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var filteredChoices: [OpenCodeModelChoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return choices }
        return choices.filter {
            $0.modelName.localizedCaseInsensitiveContains(query)
                || $0.modelID.localizedCaseInsensitiveContains(query)
                || $0.providerName.localizedCaseInsensitiveContains(query)
        }
    }

    private func modelSubtitle(for choice: OpenCodeModelChoice) -> String {
        if choice.modelName.caseInsensitiveCompare(choice.modelID) == .orderedSame {
            return choice.providerName
        }
        return "\(choice.modelName) · \(choice.providerName)"
    }
}
