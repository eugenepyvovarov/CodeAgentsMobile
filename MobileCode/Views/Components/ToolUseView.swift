//
//  ToolUseView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//

import SwiftUI

struct ToolUseView: View {
    let toolUseBlock: ToolUseBlock
    let isStreaming: Bool

    @State private var isExpanded: Bool = false

    init(toolUseBlock: ToolUseBlock, isStreaming: Bool = false) {
        self.toolUseBlock = toolUseBlock
        self.isStreaming = isStreaming
    }

    private var title: String {
        BlockFormattingUtils.friendlyToolTitle(for: toolUseBlock.name, isStreaming: isStreaming)
    }

    private var detail: String? {
        BlockFormattingUtils.toolActivityDetail(name: toolUseBlock.name, input: toolUseBlock.input)
    }

    private var canExpand: Bool {
        !toolUseBlock.input.isEmpty
    }

    private var status: ToolActivityStatus {
        isStreaming ? .running : .idle
    }

    var body: some View {
        ToolActivityChrome(
            icon: BlockFormattingUtils.getToolIcon(for: toolUseBlock.name),
            title: title,
            detail: detail,
            status: status,
            canExpand: canExpand,
            isExpanded: $isExpanded
        ) {
            expandedParameters
        }
    }

    // MARK: - Expanded parameters (technical, on demand)

    @ViewBuilder
    private var expandedParameters: some View {
        let name = toolUseBlock.name.lowercased()
        if name == "edit" || name == "multiedit" {
            editParameters
        } else {
            genericParameters
        }
    }

    @ViewBuilder
    private var editParameters: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let edits = toolUseBlock.input["edits"] as? [[String: Any]] {
                ForEach(Array(edits.enumerated()), id: \.offset) { index, edit in
                    if let oldString = edit["old_string"] as? String,
                       let newString = edit["new_string"] as? String {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Edit \(index + 1)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)

                            DiffView(oldString: oldString, newString: newString)
                                .padding(8)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            } else if let oldString = toolUseBlock.input["old_string"] as? String,
                      let newString = toolUseBlock.input["new_string"] as? String {
                DiffView(oldString: oldString, newString: newString)
                    .padding(8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if let filePath = toolUseBlock.input["file_path"] as? String {
                Text(filePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var genericParameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(toolUseBlock.input.keys.sorted()), id: \.self) { key in
                VStack(alignment: .leading, spacing: 2) {
                    Text(key)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)

                    if key == "todos" {
                        Text(formatParameterValue(toolUseBlock.input[key]))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else {
                        Text(formatParameterValue(toolUseBlock.input[key]))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(12)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func formatParameterValue(_ value: Any?) -> String {
        guard let value else { return "—" }

        if let string = value as? String {
            if string.contains("/") || string.contains("\\") {
                return string
            }
            return string.count > 200 ? "\(string.prefix(200))…" : string
        } else if let bool = value as? Bool {
            return bool ? "true" : "false"
        } else if let number = value as? NSNumber {
            return number.stringValue
        } else if let array = value as? [[String: Any]] {
            if array.isEmpty { return "[]" }
            var formattedItems: [String] = []
            for (index, item) in array.enumerated() {
                if let content = item["content"] as? String {
                    let status = item["status"] as? String ?? "pending"
                    let badge = status == "completed" ? "✓" : "○"
                    formattedItems.append("\(badge) \(content)")
                } else if let oldString = item["old_string"] as? String,
                          let newString = item["new_string"] as? String {
                    formattedItems.append(createDiffPreview(old: oldString, new: newString))
                } else {
                    formattedItems.append("• Item \(index + 1)")
                }
            }
            return formattedItems.joined(separator: "\n")
        } else if let dict = value as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string.count > 500 ? "\(string.prefix(500))…" : string
            }
            return "{\(dict.count) items}"
        } else if let array = value as? [Any] {
            if array.isEmpty { return "[]" }
            if array.count > 3 { return "[\(array.count) items]" }
            if let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted]),
               let string = String(data: data, encoding: .utf8) {
                return string.count > 300 ? "\(string.prefix(300))…" : string
            }
            return "[\(array.count) items]"
        } else {
            return String(describing: value)
        }
    }

    private func createDiffPreview(old: String, new: String) -> String {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var firstDiff = -1
        for i in 0..<max(oldLines.count, newLines.count) {
            let oldLine = i < oldLines.count ? oldLines[i] : ""
            let newLine = i < newLines.count ? newLines[i] : ""
            if oldLine != newLine {
                firstDiff = i
                break
            }
        }

        guard firstDiff >= 0 else { return "• No changes" }

        if firstDiff < oldLines.count && firstDiff < newLines.count {
            return "- \(oldLines[firstDiff].prefix(40))…\n+ \(newLines[firstDiff].prefix(40))…"
        } else if firstDiff >= oldLines.count {
            return "+ \(newLines[firstDiff].prefix(50))…"
        } else {
            return "- \(oldLines[firstDiff].prefix(50))…"
        }
    }
}
