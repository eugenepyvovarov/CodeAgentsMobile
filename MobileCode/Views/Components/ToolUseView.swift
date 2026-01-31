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
    @State private var rotation: Double = 0
    
    init(toolUseBlock: ToolUseBlock, isStreaming: Bool = false) {
        self.toolUseBlock = toolUseBlock
        self.isStreaming = isStreaming
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tool header
            HStack(spacing: 8) {
                Image(systemName: BlockFormattingUtils.getToolIcon(for: toolUseBlock.name))
                    .font(.system(size: 16))
                    .foregroundColor(BlockFormattingUtils.getToolColor(for: toolUseBlock.name))
                    .rotationEffect(.degrees(isStreaming ? rotation : 0))
                    .onAppear {
                        if isStreaming {
                            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        }
                    }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(BlockFormattingUtils.getToolDisplayName(for: toolUseBlock.name))
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    // Show MCP function name if it's an MCP tool
                    if let functionName = BlockFormattingUtils.getMCPFunctionName(for: toolUseBlock.name) {
                        Text(functionName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if !toolUseBlock.input.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Tool parameters - show collapsed summary or expanded details
            if isExpanded && !toolUseBlock.input.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    // Special handling for Edit/MultiEdit - show diffs
                    if toolUseBlock.name.lowercased() == "edit" || toolUseBlock.name.lowercased() == "multiedit" {
                        if let edits = toolUseBlock.input["edits"] as? [[String: Any]] {
                            // MultiEdit - show each edit as a diff
                            ForEach(Array(edits.enumerated()), id: \.offset) { index, edit in
                                if let oldString = edit["old_string"] as? String,
                                   let newString = edit["new_string"] as? String {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Edit \(index + 1):")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.secondary)
                                        
                                        DiffView(oldString: oldString, newString: newString)
                                            .padding(8)
                                            .background(Color(.systemGray6))
                                            .cornerRadius(6)
                                    }
                                }
                            }
                        } else if let oldString = toolUseBlock.input["old_string"] as? String,
                                  let newString = toolUseBlock.input["new_string"] as? String {
                            // Single Edit - show diff
                            DiffView(oldString: oldString, newString: newString)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .cornerRadius(6)
                        }
                        
                        // Show file path if available
                        if let filePath = toolUseBlock.input["file_path"] as? String {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(filePath)
                                    .font(.caption)
                                    .fontDesign(.monospaced)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        // Regular parameter display for other tools
                        ForEach(Array(toolUseBlock.input.keys.sorted()), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(key):")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                
                                // For todos, allow text wrapping. For other values, use horizontal scrolling
                                if key == "todos" {
                                    Text(formatParameterValue(toolUseBlock.input[key]))
                                        .font(.caption)
                                        .fontDesign(.monospaced)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.leading, 8)
                                } else {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        Text(formatParameterValue(toolUseBlock.input[key]))
                                            .font(.caption)
                                            .fontDesign(.monospaced)
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: true, vertical: true)
                                    }
                                    .padding(.leading, 8)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 24)
            } else if !toolUseBlock.input.isEmpty {
                // Show collapsed parameter summary
                Text(BlockFormattingUtils.formatToolParameters(toolUseBlock.input))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 24)
            } else {
                // No parameters
                Text("No parameters")
                    .font(.caption)
                    .italic()
                    .foregroundColor(.secondary)
                    .padding(.leading, 24)
            }
        }
        .padding(12)
        .background(BlockFormattingUtils.getToolColor(for: toolUseBlock.name).opacity(0.08))
        .cornerRadius(12)
    }
    
    private func formatParameterValue(_ value: Any?) -> String {
        guard let value = value else { return "nil" }
        
        if let string = value as? String {
            // For simple strings, don't add quotes if they're file paths or similar
            if string.contains("/") || string.contains("\\") {
                return string
            }
            return string.count > 100 ? "\(string.prefix(100))..." : string
        } else if let bool = value as? Bool {
            return bool ? "true" : "false"
        } else if let number = value as? NSNumber {
            return number.stringValue
        } else if let array = value as? [[String: Any]] {
            // Special handling for arrays of dictionaries (like todos or edits)
            if array.isEmpty {
                return "[]"
            }
            
            // Format each item in the array
            var formattedItems: [String] = []
            for (index, item) in array.enumerated() {
                // Format based on content
                if let content = item["content"] as? String {
                    // Todo item
                    let status = item["status"] as? String ?? "pending"
                    let priority = item["priority"] as? String ?? "normal"
                    let badge = status == "completed" ? "✅" : "☑️"
                    // Don't truncate todo content - show full text
                    formattedItems.append("\(badge) \(content) [\(priority)]")
                } else if let oldString = item["old_string"] as? String,
                          let newString = item["new_string"] as? String {
                    // Edit item - create a diff view
                    let diff = createDiffPreview(old: oldString, new: newString)
                    formattedItems.append(diff)
                } else {
                    // Generic item
                    formattedItems.append("• Item \(index + 1)")
                }
            }
            
            return formattedItems.joined(separator: "\n")
        } else if let dict = value as? [String: Any] {
            // Try to format as pretty JSON
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                // Limit very long JSON
                return string.count > 500 ? "\(string.prefix(500))..." : string
            }
            return "{\(dict.count) items}"
        } else if let array = value as? [Any] {
            if array.isEmpty {
                return "[]"
            }
            // Show array count for large arrays
            if array.count > 3 {
                return "[\(array.count) items]"
            }
            // Try to format small arrays
            if let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted]),
               let string = String(data: data, encoding: .utf8) {
                return string.count > 300 ? "\(string.prefix(300))..." : string
            }
            return "[\(array.count) items]"
        } else {
            return String(describing: value)
        }
    }
    
    private func createDiffPreview(old: String, new: String) -> String {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        
        // Find the first and last lines that differ
        var firstDiff = -1
        var lastDiff = -1
        
        for i in 0..<max(oldLines.count, newLines.count) {
            let oldLine = i < oldLines.count ? oldLines[i] : ""
            let newLine = i < newLines.count ? newLines[i] : ""
            
            if oldLine != newLine {
                if firstDiff == -1 {
                    firstDiff = i
                }
                lastDiff = i
            }
        }
        
        // If no differences, show a simple message
        if firstDiff == -1 {
            return "• No changes"
        }
        
        // Create a compact diff view
        var diffLines: [String] = []
        
        // Show context (1 line before if available)
        let contextStart = max(0, firstDiff - 1)
        
        // If we're showing a function definition, try to include it
        if firstDiff > 0 {
            for i in stride(from: firstDiff - 1, through: 0, by: -1) {
                let line = i < oldLines.count ? oldLines[i] : ""
                if line.contains("def ") || line.contains("class ") || line.contains("@") {
                    if i < contextStart {
                        diffLines.append("  \(line.prefix(50))...")
                    }
                    break
                }
            }
        }
        
        // Show the actual changes
        if firstDiff < oldLines.count && firstDiff < newLines.count {
            // Line was modified
            let oldLine = oldLines[firstDiff]
            let newLine = newLines[firstDiff]
            
            // Find the common prefix and suffix
            let commonPrefix = String(zip(oldLine, newLine).prefix(while: { $0 == $1 }).map { $0.0 })
            let commonSuffix = String(zip(oldLine.reversed(), newLine.reversed()).prefix(while: { $0 == $1 }).map { $0.0 }.reversed())
            
            if !commonPrefix.isEmpty || !commonSuffix.isEmpty {
                // Show inline diff
                let oldDiff = String(oldLine.dropFirst(commonPrefix.count).dropLast(commonSuffix.count))
                let newDiff = String(newLine.dropFirst(commonPrefix.count).dropLast(commonSuffix.count))
                
                if commonPrefix.count > 20 {
                    diffLines.append("  ...\(commonPrefix.suffix(20))[\(oldDiff) → \(newDiff)]\(commonSuffix.prefix(20))...")
                } else {
                    diffLines.append("  \(commonPrefix)[\(oldDiff) → \(newDiff)]\(commonSuffix)")
                }
            } else {
                diffLines.append("- \(oldLine.prefix(40))...")
                diffLines.append("+ \(newLine.prefix(40))...")
            }
        } else if firstDiff >= oldLines.count {
            // Lines were added
            diffLines.append("+ \(newLines[firstDiff].prefix(50))...")
            if lastDiff > firstDiff {
                diffLines.append("  ... (+\(lastDiff - firstDiff) more lines)")
            }
        } else {
            // Lines were removed
            diffLines.append("- \(oldLines[firstDiff].prefix(50))...")
            if lastDiff > firstDiff {
                diffLines.append("  ... (-\(lastDiff - firstDiff) more lines)")
            }
        }
        
        return diffLines.joined(separator: "\n")
    }
}
