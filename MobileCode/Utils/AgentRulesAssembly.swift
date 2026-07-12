//
//  AgentRulesAssembly.swift
//  CodeAgentsMobile
//
//  Purpose: Split agent rules into linked aspect files and assemble AGENTS.md for OpenCode.
//

import Foundation

/// Editable facets of agent rules. Each aspect has its own file under `.codeagents/rules/`.
/// `AGENTS.md` is assembled from these files so OpenCode still reads a single entrypoint.
enum AgentRulesAspect: String, CaseIterable, Identifiable, Hashable {
    case personality
    case codeAgentsUI = "codeagents-ui"

    var id: String { rawValue }

    var fileName: String { "\(rawValue).md" }

    var relativePath: String {
        PathUtils.join(AgentProjectFileLayout.rulesDirectoryRelativePath, fileName)
    }

    var displayTitle: String {
        switch self {
        case .personality:
            return "Personality"
        case .codeAgentsUI:
            return "UI Widgets"
        }
    }

    var subtitle: String {
        switch self {
        case .personality:
            return "Who the agent is, tone, priorities, and boundaries"
        case .codeAgentsUI:
            return "How the agent embeds cards, tables, charts, and media"
        }
    }

    var systemImage: String {
        switch self {
        case .personality:
            return "person.text.rectangle"
        case .codeAgentsUI:
            return "rectangle.3.group"
        }
    }

    var editorPlaceholder: String {
        switch self {
        case .personality:
            return """
            Describe this agent’s personality.

            Examples:
            • Who they are and what they care about
            • Tone and how long answers should be
            • Domain expertise and defaults
            • Hard boundaries or things to avoid
            """
        case .codeAgentsUI:
            return "Rules for CodeAgents UI widgets (cards, tables, charts, media)…"
        }
    }

    var tipMarkdown: String {
        switch self {
        case .personality:
            return "Keep this focused on identity and behavior. Widget/format rules belong under UI Widgets."
        case .codeAgentsUI:
            return "The app maintains default widget rules. Edit only if you need custom UI behavior for this agent."
        }
    }

    var usesMonospacedEditor: Bool {
        switch self {
        case .personality:
            return false
        case .codeAgentsUI:
            return true
        }
    }

    var startMarker: String {
        "<!-- codeagents:rules:\(rawValue) -->"
    }

    var endMarker: String {
        "<!-- /codeagents:rules:\(rawValue) -->"
    }
}

/// Builds and parses the managed `AGENTS.md` envelope that links aspect files.
enum AgentRulesAssembly {
    static let managedBanner = """
    # Agent Rules

    > Managed by CodeAgents Mobile. Edit aspects under `.codeagents/rules/` \
    (Abilities → Personality). This file is regenerated on save so OpenCode \
    always sees the full ruleset.
    """

    static func assemble(personality: String, uiRules: String) -> String {
        var sections: [String] = [managedBanner.trimmingCharacters(in: .whitespacesAndNewlines)]

        sections.append(wrapped(.personality, body: personality))
        sections.append(wrapped(.codeAgentsUI, body: uiRules))

        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Extract aspect bodies from a managed or legacy monolithic AGENTS.md / CLAUDE.md.
    static func extractAspects(from agentsMarkdown: String) -> (personality: String, uiRules: String?) {
        let personality = extractSection(aspect: .personality, from: agentsMarkdown)
        let ui = extractSection(aspect: .codeAgentsUI, from: agentsMarkdown)

        if personality != nil || ui != nil {
            let personalityBody = personality ?? stripKnownUIContent(from: agentsMarkdown)
            return (
                personality: personalityBody.trimmingCharacters(in: .whitespacesAndNewlines),
                uiRules: ui.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            )
        }

        // Legacy monolithic file: personality is everything that is not the stock UI rules blob.
        let stripped = stripKnownUIContent(from: agentsMarkdown)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (personality: stripped, uiRules: nil)
    }

    static func containsManagedMarkers(_ content: String) -> Bool {
        content.contains(AgentRulesAspect.personality.startMarker)
            || content.contains(AgentRulesAspect.codeAgentsUI.startMarker)
    }

    /// Remove stock CodeAgents UI blobs / tool-call guard so personality stays clean.
    static func stripKnownUIContent(from content: String) -> String {
        var result = content

        if let range = result.range(of: CodeAgentsUIRules.rulesMarkdown) {
            result.removeSubrange(range)
        }
        if let range = result.range(of: CodeAgentsUIRules.toolCallGuardMarkdown) {
            result.removeSubrange(range)
        }

        // Drop managed marker sections if present (defensive).
        for aspect in AgentRulesAspect.allCases {
            if let sectionRange = sectionRange(aspect: aspect, in: result) {
                result.removeSubrange(sectionRange)
            }
        }

        // Collapse excess blank lines left by removals.
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private static func wrapped(_ aspect: AgentRulesAspect, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let inner = trimmed.isEmpty ? "" : "\n\(trimmed)\n"
        return """
        \(aspect.startMarker)\(inner)\(aspect.endMarker)
        """
    }

    private static func extractSection(aspect: AgentRulesAspect, from content: String) -> String? {
        guard let range = sectionRange(aspect: aspect, in: content) else { return nil }
        let start = content.index(range.lowerBound, offsetBy: aspect.startMarker.count)
        let end = content.index(range.upperBound, offsetBy: -aspect.endMarker.count)
        guard start <= end else { return "" }
        return String(content[start..<end])
    }

    private static func sectionRange(aspect: AgentRulesAspect, in content: String) -> Range<String.Index>? {
        guard let start = content.range(of: aspect.startMarker),
              let end = content.range(of: aspect.endMarker, range: start.upperBound..<content.endIndex),
              start.upperBound <= end.lowerBound else {
            return nil
        }
        return start.lowerBound..<end.upperBound
    }
}
