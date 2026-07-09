//
//  BlockFormattingUtils.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-06.
//

import SwiftUI

struct BlockFormattingUtils {
    
    // MARK: - MCP Tool Parsing
    static func parseMCPToolName(_ tool: String) -> (isMCP: Bool, serverName: String?, toolName: String) {
        if tool.starts(with: "mcp__") {
            // Remove "mcp__" prefix
            let withoutPrefix = String(tool.dropFirst(5))
            // Split by "__" to separate server name and tool name
            if let separatorRange = withoutPrefix.range(of: "__") {
                let serverName = String(withoutPrefix[..<separatorRange.lowerBound])
                let toolName = String(withoutPrefix[separatorRange.upperBound...])
                return (true, serverName, toolName)
            }
        }
        return (false, nil, tool)
    }
    
    // MARK: - Tool Display Name
    static func getToolDisplayName(for tool: String) -> String {
        let (isMCP, serverName, _) = parseMCPToolName(tool)
        if isMCP, let serverName = serverName {
            // For MCP tools, return the server name with first letter capitalized
            return serverName.prefix(1).uppercased() + serverName.dropFirst()
        }
        return tool
    }

    /// Short, human-facing activity title for chat (past tense when complete).
    static func friendlyToolTitle(for tool: String, isStreaming: Bool = false) -> String {
        let (isMCP, _, rawName) = parseMCPToolName(tool)
        let key = normalizeToolKey(isMCP ? rawName : tool)

        let pair: (running: String, done: String)
        switch key {
        case "read", "notebookread":
            pair = ("Reading file", "Read file")
        case "write", "notebookedit":
            pair = ("Writing file", "Wrote file")
        case "edit", "multiedit":
            pair = ("Editing file", "Edited file")
        case "bash", "shell":
            pair = ("Running command", "Ran command")
        case "grep":
            pair = ("Searching", "Searched")
        case "glob":
            pair = ("Finding files", "Found files")
        case "ls", "list":
            pair = ("Listing folder", "Listed folder")
        case "webfetch":
            pair = ("Fetching page", "Fetched page")
        case "websearch":
            pair = ("Searching web", "Searched web")
        case "todowrite", "todoread":
            pair = ("Updating todos", "Updated todos")
        case "task":
            pair = ("Starting task", "Started task")
        case "listtools", "toolslist", "listmcp":
            pair = ("Listing tools", "Listed tools")
        case "exitplanmode":
            pair = ("Leaving plan mode", "Left plan mode")
        default:
            let human = humanizeToolName(isMCP ? rawName : tool)
            pair = (human + "…", human)
        }

        return isStreaming ? pair.running : pair.done
    }

    /// One-line secondary detail for a collapsed tool-use chip.
    static func toolActivityDetail(name: String, input: [String: Any]) -> String? {
        let summary = formatToolParameters(input)
        if summary == "No parameters" || summary.isEmpty {
            return nil
        }
        return summary
    }

    /// One-line secondary detail for a collapsed tool-result chip (never raw JSON dumps).
    static func toolResultSummary(content: String, isError: Bool) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return isError ? "Failed" : "Done"
        }
        if isError {
            let first = firstMeaningfulLine(trimmed)
            if looksLikeJSON(first) {
                return "Failed"
            }
            return truncateContent(first, maxLength: 48)
        }

        if let count = jsonArrayCount(trimmed) {
            return count == 1 ? "1 item" : "\(count) items"
        }
        if let count = jsonToolsCount(trimmed) {
            return count == 1 ? "1 tool" : "\(count) tools"
        }
        if looksLikeJSON(trimmed) {
            if let keys = jsonObjectKeyCount(trimmed) {
                return keys == 1 ? "1 field" : "\(keys) fields"
            }
            return "Result ready"
        }

        let first = firstMeaningfulLine(trimmed)
        return truncateContent(first, maxLength: 56)
    }
    
    // MARK: - MCP Function Name
    static func getMCPFunctionName(for tool: String) -> String? {
        let (isMCP, _, toolName) = parseMCPToolName(tool)
        if isMCP {
            // Replace underscores with spaces for better readability
            return toolName.replacingOccurrences(of: "_", with: " ")
        }
        return nil
    }

    // MARK: - Private presentation helpers

    private static func normalizeToolKey(_ name: String) -> String {
        name
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func humanizeToolName(_ name: String) -> String {
        let spaced = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return name }
        return String(first).uppercased() + spaced.dropFirst()
    }

    private static func firstMeaningfulLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return s }
        }
        return text
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }

    private static func jsonArrayCount(_ text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        return array.count
    }

    private static func jsonObjectKeyCount(_ text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj.count
    }

    /// Detects tool-list style payloads (`[{name, description, ...}, ...]` or `{tools: [...]}`).
    private static func jsonToolsCount(_ text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let dict = json as? [String: Any] {
            for key in ["tools", "data", "items", "result"] {
                if let arr = dict[key] as? [Any] {
                    return arr.count
                }
            }
        }
        if let array = json as? [[String: Any]], !array.isEmpty {
            let looksLikeTools = array.allSatisfy { item in
                item["name"] != nil || item["tool"] != nil || item["function"] != nil
            }
            if looksLikeTools {
                return array.count
            }
        }
        return nil
    }
    
    // MARK: - Tool Icons
    static func getToolIcon(for tool: String) -> String {
        // Check if it's an MCP tool
        let (isMCP, _, _) = parseMCPToolName(tool)
        if isMCP {
            return "server.rack"
        }
        
        switch tool.lowercased() {
        case "todowrite", "todoread":
            return "checklist"
        case "read":
            return "doc.text"
        case "write":
            return "square.and.pencil"
        case "edit", "multiedit":
            return "pencil"
        case "bash":
            return "terminal"
        case "grep":
            return "magnifyingglass"
        case "glob":
            return "folder.badge.gearshape"
        case "ls":
            return "folder"
        case "webfetch", "websearch":
            return "globe"
        case "task":
            return "person.2"
        case "exit_plan_mode":
            return "arrow.right.square"
        case "notebookread", "notebookedit":
            return "book"
        default:
            return "wrench.and.screwdriver"
        }
    }
    
    // MARK: - Tool Colors
    static func getToolColor(for tool: String) -> Color {
        // Check if it's an MCP tool
        let (isMCP, _, _) = parseMCPToolName(tool)
        if isMCP {
            return .teal
        }
        
        switch tool.lowercased() {
        case "todowrite", "todoread":
            return .blue
        case "read", "write", "edit", "multiedit":
            return .orange
        case "bash":
            return .green
        case "grep", "glob", "ls":
            return .purple
        case "webfetch", "websearch":
            return .indigo
        default:
            return .gray
        }
    }

    // MARK: - Tool Filtering
    static func isBlockedToolName(_ tool: String) -> Bool {
        let lower = tool.lowercased()
        return lower == "codeagents-ui" || lower == "codeagents_ui"
    }

    static func isBlockedToolResultContent(_ content: String) -> Bool {
        let lower = content.lowercased()
        return lower.contains("codeagents-ui") || lower.contains("codeagents_ui")
    }
    
    // MARK: - Content Truncation
    static func truncateContent(_ content: String, maxLength: Int = 100) -> String {
        if content.count <= maxLength {
            return content
        }
        let endIndex = content.index(content.startIndex, offsetBy: maxLength)
        return String(content[..<endIndex]) + "..."
    }
    
    // MARK: - Parameter Formatting
    static func formatToolParameters(_ parameters: [String: Any]) -> String {
        // Special handling for TodoWrite
        if let todos = parameters["todos"] as? [[String: Any]] {
            let activeCount = todos.filter { ($0["status"] as? String) != "completed" }.count
            let completedCount = todos.filter { ($0["status"] as? String) == "completed" }.count
            
            if activeCount > 0 && completedCount > 0 {
                return "\(activeCount) active, \(completedCount) completed"
            } else if activeCount > 0 {
                return "\(activeCount) todo\(activeCount == 1 ? "" : "s")"
            } else if completedCount > 0 {
                return "\(completedCount) completed"
            } else {
                return "\(todos.count) todo\(todos.count == 1 ? "" : "s")"
            }
        }
        
        // Special handling for MultiEdit
        if let edits = parameters["edits"] as? [[String: Any]] {
            let editCount = edits.count
            if let filePath = parameters["file_path"] as? String {
                let fileName = filePath.split(separator: "/").last.map(String.init) ?? filePath
                return "\(editCount) edit\(editCount == 1 ? "" : "s") to \(fileName)"
            }
            return "\(editCount) edit\(editCount == 1 ? "" : "s")"
        }
        
        // Prioritize command for bash and similar tools
        if let command = parameters["command"] as? String {
            // Show command in monospace if it's short enough
            if command.count <= 60 {
                return command
            }
            return truncateContent(command, maxLength: 60)
        }
        
        if let filePath = parameters["file_path"] as? String {
            return formatFilePath(filePath)
        }
        
        if let path = parameters["path"] as? String {
            return formatFilePath(path)
        }
        
        if let pattern = parameters["pattern"] as? String {
            return "\"\(truncateContent(pattern, maxLength: 30))\""
        }
        
        // For tools with multiple parameters, show the most important one
        if parameters.count == 1, let firstValue = parameters.values.first {
            if let stringValue = firstValue as? String {
                return truncateContent(stringValue, maxLength: 60)
            }
        }
        
        // Generic parameter count
        if parameters.isEmpty {
            return "No parameters"
        }
        
        return "\(parameters.count) parameters"
    }
    
    // MARK: - Result Status
    static func getResultIcon(isError: Bool) -> String {
        return isError ? "xmark.circle.fill" : "checkmark.circle.fill"
    }
    
    static func getResultColor(isError: Bool) -> Color {
        return isError ? .red : .green
    }
    
    // MARK: - File Path Formatting
    static func formatFilePath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count > 3 {
            let last = components.suffix(2).joined(separator: "/")
            return ".../\(last)"
        }
        return path
    }
    
    // MARK: - Time Formatting
    static func formatDuration(_ milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000.0
        if seconds < 1 {
            return String(format: "%.0fms", Double(milliseconds))
        } else if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds / 60)
            let remainingSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(remainingSeconds)s"
        }
    }
    
    // MARK: - Cost Formatting
    static func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        } else {
            return String(format: "$%.2f", cost)
        }
    }
}
