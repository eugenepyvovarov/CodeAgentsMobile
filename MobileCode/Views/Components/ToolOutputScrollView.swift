//
//  ToolOutputScrollView.swift
//  CodeAgentsMobile
//
//  Caps expanded tool I/O to a fixed number of visible lines; longer content scrolls.
//

import SwiftUI
import UIKit

enum ToolOutputDisplay {
    /// Visible monospaced lines before the expanded body becomes scrollable.
    static let maxVisibleLines = 15

    static var maxHeight: CGFloat {
        let pointSize = UIFont.preferredFont(forTextStyle: .caption2).pointSize
        let font = UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        // Slight padding so 15 lines aren't clipped by descenders / anti-alias.
        return ceil(font.lineHeight) * CGFloat(maxVisibleLines) + 4
    }
}

/// Monospaced tool text, height-capped so chat layout stays compact.
struct ToolOutputScrollView: View {
    let text: String
    var isError: Bool = false

    private var lineCount: Int {
        max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private var needsScroll: Bool {
        lineCount > ToolOutputDisplay.maxVisibleLines
            || text.count > ToolOutputDisplay.maxVisibleLines * 80
    }

    var body: some View {
        Group {
            if needsScroll {
                ScrollView {
                    content
                }
                .frame(maxHeight: ToolOutputDisplay.maxHeight)
            } else {
                content
            }
        }
    }

    private var content: some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(isError ? Color.red.opacity(0.85) : Color.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
