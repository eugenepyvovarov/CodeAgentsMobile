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

                        if choice.supportsReasoning {
                            Text("Thinking")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                .foregroundStyle(.tint)
                        }

                        if choice.isDeprecated {
                            Text("Deprecated")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                                .foregroundStyle(.orange)
                        }

                        if choice.id.caseInsensitiveCompare(selectedModelID) == .orderedSame {
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
        var parts: [String] = []
        if choice.modelName.caseInsensitiveCompare(choice.modelID) != .orderedSame {
            parts.append(choice.modelName)
        }
        parts.append(choice.providerName)
        if choice.supportsReasoning, !choice.effortLevels.isEmpty {
            parts.append("\(choice.effortLevels.count) thinking levels")
        } else if choice.supportsReasoning {
            parts.append("reasoning")
        }
        return parts.joined(separator: " · ")
    }
}
