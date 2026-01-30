//
//  ToolPermissionInfo.swift
//  CodeAgentsMobile
//
//  Purpose: Friendly display names + explanations for Claude Code tools.
//

import Foundation

enum ToolPermissionInfo {
    static func displayName(for toolName: String) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return toolName }

        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("mcp__") {
            let server = String(trimmed.dropFirst("mcp__".count))
            if server.isEmpty {
                return "MCP Server"
            }
            return "MCP: \(server)"
        }

        if let known = knownTools[normalized]?.displayName {
            return known
        }

        return humanizeIdentifier(trimmed)
    }

    static func summary(for toolName: String) -> String {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Allow the agent to use this tool." }

        let normalized = trimmed.lowercased()
        if normalized.hasPrefix("mcp__") {
            let server = String(trimmed.dropFirst("mcp__".count))
            if server.isEmpty {
                return "Use tools provided by a connected MCP server."
            }
            return "Use tools provided by the MCP server “\(server)”."
        }

        if let known = knownTools[normalized]?.summary {
            return known
        }

        return "Allow the agent to use this tool."
    }

    private static func humanizeIdentifier(_ identifier: String) -> String {
        var result = ""
        var previous: Character?

        for current in identifier {
            if current == "_" || current == "-" {
                if result.last != " " {
                    result.append(" ")
                }
                previous = current
                continue
            }

            if let previous, shouldInsertSpace(between: previous, and: current), result.last != " " {
                result.append(" ")
            }

            result.append(current)
            previous = current
        }

        return result
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldInsertSpace(between left: Character, and right: Character) -> Bool {
        if left.isLowercase && right.isUppercase {
            return true
        }

        if left.isLetter && right.isNumber {
            return true
        }

        if left.isNumber && right.isLetter {
            return true
        }

        return false
    }

    private struct ToolDetails {
        let displayName: String
        let summary: String
    }

    private static let knownTools: [String: ToolDetails] = [
        "task": ToolDetails(displayName: "Task",
                            summary: "Run an internal task step."),
        "taskoutput": ToolDetails(displayName: "Task Output",
                                  summary: "Return output for an internal task step."),
        "bash": ToolDetails(displayName: "Run Commands",
                            summary: "Run shell commands in the agent environment."),
        "write": ToolDetails(displayName: "Write Files",
                             summary: "Create new files in the agent’s project."),
        "edit": ToolDetails(displayName: "Edit Files",
                            summary: "Modify existing files in the agent’s project."),
        "multiedit": ToolDetails(displayName: "Multi-Edit Files",
                                 summary: "Apply multiple edits across files."),
        "notebookedit": ToolDetails(displayName: "Notebook Edit",
                                    summary: "Edit notebook-style files."),
        "read": ToolDetails(displayName: "Read Files",
                            summary: "Read files from the agent’s project."),
        "ls": ToolDetails(displayName: "List Files",
                          summary: "List directories and files."),
        "grep": ToolDetails(displayName: "Search in Files",
                            summary: "Search file contents."),
        "glob": ToolDetails(displayName: "Find Files",
                            summary: "Find files by pattern."),
        "webfetch": ToolDetails(displayName: "Web Fetch",
                                summary: "Download content from a URL."),
        "websearch": ToolDetails(displayName: "Web Search",
                                 summary: "Search the web."),
        "todowrite": ToolDetails(displayName: "Update TODOs",
                                 summary: "Create or update TODO items the agent is tracking."),
        "askuserquestion": ToolDetails(displayName: "Ask a Question",
                                       summary: "Prompt you for clarification or confirmation."),
        "killshell": ToolDetails(displayName: "Stop Commands",
                                 summary: "Stop a running shell command."),
        "enterplanmode": ToolDetails(displayName: "Enter Plan Mode",
                                     summary: "Switch the agent into explicit planning mode."),
        "exitplanmode": ToolDetails(displayName: "Exit Plan Mode",
                                    summary: "Return the agent to normal mode."),
        "skill": ToolDetails(displayName: "Use Skills",
                             summary: "Use installed skills (instructions, templates, workflows).")
    ]
}

