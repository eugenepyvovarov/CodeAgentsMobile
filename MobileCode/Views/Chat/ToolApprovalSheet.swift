//
//  ToolApprovalSheet.swift
//  CodeAgentsMobile
//
//  Purpose: UI for approving or denying tool permissions in chat.
//

import SwiftUI

struct ToolApprovalSheet: View {
    let request: ToolApprovalRequest
    let onDecision: (ToolApprovalDecision, ToolApprovalScope) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allow \(request.toolName)?")
                            .font(.title3.weight(.semibold))
                        Text("Claude wants to use this tool during the current task.")
                            .foregroundStyle(.secondary)
                    }

                    if let blockedPath = request.blockedPath, !blockedPath.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Blocked Path")
                                .font(.subheadline.weight(.semibold))
                            Text(blockedPath)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !request.suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Suggestions")
                                .font(.subheadline.weight(.semibold))
                            ForEach(request.suggestions, id: \.self) { suggestion in
                                Text("• \(suggestion)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let formattedInput {
                        DisclosureGroup("Input") {
                            Text(formattedInput)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                    }

                    VStack(spacing: 10) {
                        Button("Allow once") {
                            onDecision(.allow, .once)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Always allow for this agent") {
                            onDecision(.allow, .agent)
                        }
                        .buttonStyle(.bordered)

                        Button("Always allow for all agents") {
                            onDecision(.allow, .global)
                        }
                        .buttonStyle(.bordered)

                        Divider()

                        Button("Deny once") {
                            onDecision(.deny, .once)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Button("Always deny for this agent") {
                            onDecision(.deny, .agent)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Button("Always deny for all agents") {
                            onDecision(.deny, .global)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .navigationTitle("Tool Permission")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private var formattedInput: String? {
        guard !request.input.isEmpty else { return nil }
        guard JSONSerialization.isValidJSONObject(request.input),
              let data = try? JSONSerialization.data(withJSONObject: request.input, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: request.input)
        }
        return string
    }
}
