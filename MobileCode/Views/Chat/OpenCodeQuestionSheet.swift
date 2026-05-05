//
//  OpenCodeQuestionSheet.swift
//  CodeAgentsMobile
//
//  Purpose: UI for answering OpenCode question-tool prompts.
//

import SwiftUI

struct OpenCodeQuestionSheet: View {
    let pendingRequest: PendingOpenCodeQuestionRequest
    let onSubmit: ([[String]]) -> Void
    let onReject: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [OpenCodeQuestionAnswerDraft]

    init(
        pendingRequest: PendingOpenCodeQuestionRequest,
        onSubmit: @escaping ([[String]]) -> Void,
        onReject: @escaping () -> Void
    ) {
        self.pendingRequest = pendingRequest
        self.onSubmit = onSubmit
        self.onReject = onReject
        _drafts = State(initialValue: pendingRequest.request.questions.map { _ in OpenCodeQuestionAnswerDraft() })
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Array(pendingRequest.request.questions.enumerated()), id: \.offset) { index, question in
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(question.question)
                                .font(.body)
                                .foregroundStyle(.primary)

                            if !question.options.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(question.options) { option in
                                        Button {
                                            toggle(option: option, question: question, index: index)
                                        } label: {
                                            HStack(alignment: .top, spacing: 10) {
                                                Image(systemName: isSelected(option: option, index: index) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(isSelected(option: option, index: index) ? Color.accentColor : Color.secondary)

                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(option.label)
                                                        .foregroundStyle(.primary)
                                                    if !option.description.isEmpty {
                                                        Text(option.description)
                                                            .font(.footnote)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            if question.custom {
                                TextField("Custom answer", text: customTextBinding(for: index), axis: .vertical)
                                    .lineLimit(1...4)
                                    .textInputAutocapitalization(.sentences)
                                    .accessibilityIdentifier("opencode-question-custom-\(index)")
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text(question.header)
                    }
                }
            }
            .navigationTitle("Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        onReject()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onSubmit(resolvedAnswers)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var canSubmit: Bool {
        guard drafts.count == pendingRequest.request.questions.count else { return false }
        return pendingRequest.request.questions.indices.allSatisfy { index in
            !answer(for: index).isEmpty
        }
    }

    private var resolvedAnswers: [[String]] {
        pendingRequest.request.questions.indices.map { answer(for: $0) }
    }

    private func answer(for index: Int) -> [String] {
        guard drafts.indices.contains(index) else { return [] }
        let custom = drafts[index].customText.trimmingCharacters(in: .whitespacesAndNewlines)
        var values = Array(drafts[index].selectedLabels).sorted()
        if !custom.isEmpty {
            values.append(custom)
        }
        return values
    }

    private func isSelected(option: OpenCodeQuestionOption, index: Int) -> Bool {
        guard drafts.indices.contains(index) else { return false }
        return drafts[index].selectedLabels.contains(option.label)
    }

    private func toggle(option: OpenCodeQuestionOption, question: OpenCodeQuestion, index: Int) {
        guard drafts.indices.contains(index) else { return }
        if question.multiple {
            if drafts[index].selectedLabels.contains(option.label) {
                drafts[index].selectedLabels.remove(option.label)
            } else {
                drafts[index].selectedLabels.insert(option.label)
            }
        } else {
            drafts[index].selectedLabels = [option.label]
        }
    }

    private func customTextBinding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                guard drafts.indices.contains(index) else { return "" }
                return drafts[index].customText
            },
            set: { value in
                guard drafts.indices.contains(index) else { return }
                drafts[index].customText = value
            }
        )
    }
}

private struct OpenCodeQuestionAnswerDraft: Equatable {
    var selectedLabels: Set<String> = []
    var customText = ""
}
