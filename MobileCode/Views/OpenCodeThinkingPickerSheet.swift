//
//  OpenCodeThinkingPickerSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Sheet for selecting OpenCode thinking / reasoning effort
//

import SwiftUI

struct OpenCodeThinkingPickerSheet: View {
    let choices: [OpenCodeThinkingChoice]
    let selectedThinkingID: String
    let onSelect: (OpenCodeThinkingChoice) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(choices) { choice in
                Button {
                    onSelect(choice)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.title)
                                .foregroundColor(.primary)
                            if let subtitle = choice.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        if choice.id.caseInsensitiveCompare(selectedThinkingID) == .orderedSame {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityIdentifier("opencode-ai-thinking-choice-\(choice.id.isEmpty ? "default" : choice.id)")
            }
            .navigationTitle("Thinking Level")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
