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
    
    private var resultIcon: String {
        toolResultBlock.isError ? "exclamationmark.triangle" : "checkmark.circle"
    }
    
    private var resultColor: Color {
        toolResultBlock.isError ? .red : .green
    }
    
    private var firstLine: String {
        let lines = toolResultBlock.content.split(separator: "\n", maxSplits: 1)
        if let first = lines.first {
            return String(first)
        }
        return toolResultBlock.content
    }
    
    private var hasMultipleLines: Bool {
        toolResultBlock.content.contains("\n")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: resultIcon)
                        .font(.system(size: 16))
                        .foregroundColor(resultColor)
                    
                    Text("Tool Result")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if hasMultipleLines {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            
            // Content
            if isExpanded || !hasMultipleLines {
                Text(toolResultBlock.content)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundColor(toolResultBlock.isError ? .red : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text(firstLine)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Text("...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(toolResultBlock.isError ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}