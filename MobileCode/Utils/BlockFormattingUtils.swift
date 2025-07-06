//
//  BlockFormattingUtils.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-07-06.
//

import SwiftUI

struct BlockFormattingUtils {
    
    // MARK: - Tool Icons
    static func getToolIcon(for tool: String) -> String {
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