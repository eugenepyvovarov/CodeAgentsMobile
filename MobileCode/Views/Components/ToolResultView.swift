//
//  ToolResultView.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-05.
//

import SwiftUI

struct ToolResultView: View {
    let toolResultBlock: ToolResultBlock
    @Binding var isExpanded: Bool

    private var summary: String {
        BlockFormattingUtils.toolResultSummary(
            content: toolResultBlock.content,
            isError: toolResultBlock.isError
        )
    }

    /// Prefer a concrete detail (counts, paths); fall back to generic title alone.
    private var detail: String? {
        let s = summary
        switch s {
        case "Done", "Failed", "Result ready":
            return nil
        default:
            return s
        }
    }

    private var status: ToolActivityStatus {
        toolResultBlock.isError ? .error : .success
    }

    private var canExpand: Bool {
        !toolResultBlock.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ToolActivityChrome(
            icon: toolResultBlock.isError ? "exclamationmark.triangle" : "checkmark.circle",
            title: toolResultBlock.isError ? "Failed" : "Done",
            detail: detail,
            status: status,
            canExpand: canExpand,
            isExpanded: $isExpanded
        ) {
            Text(toolResultBlock.content)
                .font(.caption2.monospaced())
                .foregroundStyle(toolResultBlock.isError ? Color.red.opacity(0.85) : Color.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
