//
//  CodeAgentsUIRules.swift
//  CodeAgentsMobile
//
//  Purpose: Canonical CodeAgents UI rules shared by prompt injection and aspect files.
//

import Foundation

enum CodeAgentsUIRules {
    static let toolCallGuardMarkdown = """
### CodeAgents UI (Tool Call Guard)
- codeagents-ui is NOT a tool. Never call tools named `codeagents-ui` or `codeagents_ui`.
- Always emit UI as a fenced `codeagents-ui` JSON block, never a tool call.
"""

    static let rulesMarkdown: String = """
You are replying in CodeAgents Mobile. The app can render UI widgets embedded in assistant messages.

FORCE-WIDGETS:
Whenever you present any of the following, you MUST also emit one or more UI blocks:
- images (1+), galleries (2+ images), videos
- tables / structured rows+columns
- charts (bar/line/pie/heatmap) for numeric data

Do NOT duplicate full tables/chart datasets in markdown. In markdown, write a short explanation and refer to the widget(s).

UI BLOCK FORMAT (required):
- Emit UI blocks as fenced code blocks with info string exactly: codeagents-ui
- Inside the fence: strict JSON only (no comments, no trailing commas, no prose).
- You may emit multiple codeagents-ui blocks in one message.
- If you output a codeagents-ui block, do not also output another markdown code block containing the same JSON elsewhere.
- codeagents-ui is NOT a tool. Never call tools named codeagents-ui or codeagents_ui.
Never emit a tool_use block for codeagents-ui; only use fenced code blocks.

ENVELOPE (v1):
{ "type":"codeagents_ui", "version":1, "title":"optional", "elements":[ ... ] }

ELEMENTS (v1 whitelist):
card, markdown, image, gallery, video, table, chart
- Every element MUST have a unique "id" (unique within that UI block).
- "image" uses "source" (not "images"); "gallery" uses "images" (array of image elements).

MEDIA SOURCES (v1):
- HTTPS URL only:
  { "kind":"url", "url":"https://..." }   (never http)

- Remote project file on the connected server, STRICTLY relative to project root:
  { "kind":"project_file", "path":"relative/path.png" }
  Never use absolute paths, "~", or ".." segments.
  Only reference project_file paths that exist (or that you created earlier). No guessing.

- Base64 image only if you truly have real bytes (never fabricate):
  { "kind":"base64", "mediaType":"image/png", "data":"<base64>" }

AUTO-WIDGET HEURISTICS:
- 1 image -> image
- 2+ images -> gallery
- structured rows/columns -> table (cells are markdown strings)
- numeric series over x labels -> bar/line chart
- category shares -> pie chart
- activity tracking over dates -> heatmap chart (GitHub-style)

TABLE:
{ "type":"table","id":"t1","columns":[...],"rows":[[...],[...]],"caption":"optional" }

CHART:
- bar/line:
  { "type":"chart","id":"ch1","chartType":"line","x":[...],
    "series":[{ "name":"optional","values":[number|null,...],"color":"#RRGGBB" }] }
  Use null for gaps. x labels are strings.
- pie:
  { "type":"chart","id":"ch2","chartType":"pie",
    "slices":[{"label":"A","value":12.5,"color":"#RRGGBB"}],
    "valueDisplay":"none|value|percent|both" }  (default percent)
- heatmap:
  { "type":"chart","id":"ch3","chartType":"heatmap",
    "days":[{"date":"YYYY-MM-DD","value":3},{"date":"YYYY-MM-DD","level":2}],
    "maxValue":10,"levels":5,"palette":["#ebedf0","#9be9a8","#40c463","#30a14e","#216e39"],
    "weekStart":"mon" }

FAIL-SAFE:
If you are not confident the JSON is valid, omit the UI block and respond in normal markdown.
Never output invalid JSON inside a codeagents-ui fence.

AGENT AVATAR (managed MCP `codeagents-avatar`):
When the user asks to change this agent's avatar (emoji, image, or clear it), use the MCP tools:
- `set_agent_avatar_emoji` with `{ "emoji": "🌙" }`
- `set_agent_avatar_image` with a project-relative image path
- `clear_agent_avatar` / `get_agent_avatar`
Do NOT hand-edit `.codeagents/codeagents.json` avatar fields — the MCP merges identity safely.
If those tools are unavailable, say the Agent Avatar MCP is disconnected and suggest reconnecting it in Abilities → MCP Servers.
"""

    static func ensuringToolCallGuard(in content: String) -> String {
        if content.contains("codeagents-ui is NOT a tool") {
            return content
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return toolCallGuardMarkdown
        }
        return trimmed + "\n\n" + toolCallGuardMarkdown
    }

    /// Ensures aspect files exist and regenerates assembled `AGENTS.md`.
    ///
    /// - `onlyIfMissing: true` — no-op when `AGENTS.md` already exists (fast deferred path).
    /// - `onlyIfMissing: false` — migrate legacy monoliths, keep UI defaults current, reassemble.
    static func ensureRulesFile(
        session: SSHSession,
        project: RemoteProject,
        onlyIfMissing: Bool
    ) async throws {
        let agentsPathValue = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.rulesPrimaryRelativePath
        )
        let personalityPathValue = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.rulesPersonalityRelativePath
        )
        let uiPathValue = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.rulesUIRelativePath
        )
        let legacyClaudeDirectoryValue = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.legacyClaudeDirectoryRulesRelativePath
        )
        let legacyClaudeRootValue = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.legacyClaudeRootRulesRelativePath
        )

        let agentsPath = shellEscaped(agentsPathValue)
        let personalityPath = shellEscaped(personalityPathValue)
        let uiPath = shellEscaped(uiPathValue)
        let legacyDirPath = shellEscaped(legacyClaudeDirectoryValue)
        let legacyRootPath = shellEscaped(legacyClaudeRootValue)

        if onlyIfMissing {
            let checkCommand = "[ -f \(agentsPath) ] && echo EXISTS || echo MISSING"
            let output = try await session.execute(checkCommand)
            if output.contains("EXISTS") {
                return
            }
        }

        // Read existing sources in one shot for migration / reassembly.
        let snapshot = try await readRulesSnapshot(
            session: session,
            personalityPath: personalityPath,
            uiPath: uiPath,
            agentsPath: agentsPath,
            legacyDirPath: legacyDirPath,
            legacyRootPath: legacyRootPath
        )

        let personalityBody: String
        let uiBody: String

        if let existingPersonality = snapshot.personality {
            personalityBody = existingPersonality
        } else if let agents = snapshot.agents {
            let extracted = AgentRulesAssembly.extractAspects(from: agents)
            personalityBody = extracted.personality
        } else if let legacy = snapshot.legacyClaudeDirectory ?? snapshot.legacyClaudeRoot {
            let extracted = AgentRulesAssembly.extractAspects(from: legacy)
            personalityBody = extracted.personality
        } else {
            personalityBody = ""
        }

        if let existingUI = snapshot.ui, !existingUI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            uiBody = ensuringToolCallGuard(in: existingUI)
        } else if let agents = snapshot.agents {
            let extracted = AgentRulesAssembly.extractAspects(from: agents)
            if let ui = extracted.uiRules, !ui.isEmpty {
                uiBody = ensuringToolCallGuard(in: ui)
            } else if agents.contains("FORCE-WIDGETS:") || agents.contains("codeagents_ui") {
                // Monolith that was primarily UI rules — keep full defaults.
                uiBody = rulesMarkdown
            } else {
                uiBody = rulesMarkdown
            }
        } else {
            uiBody = rulesMarkdown
        }

        let assembled = AgentRulesAssembly.assemble(personality: personalityBody, uiRules: uiBody)

        try await writeRemoteFile(session: session, path: personalityPathValue, content: personalityBody)
        try await writeRemoteFile(session: session, path: uiPathValue, content: uiBody)
        try await writeRemoteFile(session: session, path: agentsPathValue, content: assembled)
    }

    /// Writes a single aspect file and regenerates assembled `AGENTS.md` using the other aspect on disk.
    static func saveAspect(
        _ aspect: AgentRulesAspect,
        content: String,
        session: SSHSession,
        project: RemoteProject
    ) async throws {
        let normalized: String
        switch aspect {
        case .personality:
            normalized = content
        case .codeAgentsUI:
            normalized = ensuringToolCallGuard(in: content)
        }

        let aspectPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: aspect.relativePath
        )
        try await writeRemoteFile(session: session, path: aspectPath, content: normalized)

        // Load sibling aspect (or defaults) and reassemble.
        let other: AgentRulesAspect = aspect == .personality ? .codeAgentsUI : .personality
        let otherPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: other.relativePath
        )
        let otherContent = try await readRemoteFileIfPresent(session: session, path: otherPath)
            ?? (other == .codeAgentsUI ? rulesMarkdown : "")

        let personality: String
        let ui: String
        switch aspect {
        case .personality:
            personality = normalized
            ui = ensuringToolCallGuard(in: otherContent)
        case .codeAgentsUI:
            personality = otherContent
            ui = normalized
        }

        // Keep UI aspect file in sync if we normalized the guard.
        if aspect == .codeAgentsUI, ui != content {
            try await writeRemoteFile(session: session, path: aspectPath, content: ui)
        }
        if aspect == .personality, other == .codeAgentsUI, otherContent.isEmpty {
            let uiPath = AgentProjectFileLayout.remotePath(
                projectPath: project.path,
                relativePath: AgentRulesAspect.codeAgentsUI.relativePath
            )
            try await writeRemoteFile(session: session, path: uiPath, content: ui)
        }

        let agentsPath = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.rulesPrimaryRelativePath
        )
        let assembled = AgentRulesAssembly.assemble(personality: personality, uiRules: ui)
        try await writeRemoteFile(session: session, path: agentsPath, content: assembled)
    }

    // MARK: - Remote helpers

    private struct RulesSnapshot {
        var personality: String?
        var ui: String?
        var agents: String?
        var legacyClaudeDirectory: String?
        var legacyClaudeRoot: String?
    }

    private static func readRulesSnapshot(
        session: SSHSession,
        personalityPath: String,
        uiPath: String,
        agentsPath: String,
        legacyDirPath: String,
        legacyRootPath: String
    ) async throws -> RulesSnapshot {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let start = "__RULES_SNAP_START_\(token)__"
        let end = "__RULES_SNAP_END_\(token)__"

        func segment(_ key: String, _ path: String) -> String {
            """
            printf \(shellEscaped("\(key):")); \
            if [ -f \(path) ]; then \
            (base64 -w 0 \(path) 2>/dev/null || base64 \(path)); \
            else printf MISSING; fi; \
            printf '\\n';
            """
        }

        let command = [
            "printf \(shellEscaped(start));",
            segment("P", personalityPath),
            segment("U", uiPath),
            segment("A", agentsPath),
            segment("L1", legacyDirPath),
            segment("L2", legacyRootPath),
            "printf \(shellEscaped(end))",
        ].joined(separator: " ")

        let output = try await session.execute(command)
        guard let startRange = output.range(of: start),
              let endRange = output.range(of: end),
              startRange.upperBound <= endRange.lowerBound else {
            throw SSHError.commandFailed("Unable to read rules snapshot")
        }

        let body = String(output[startRange.upperBound..<endRange.lowerBound])
        var snapshot = RulesSnapshot()
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineString = String(line)
            guard let colon = lineString.firstIndex(of: ":") else { continue }
            let key = String(lineString[..<colon])
            let value = String(lineString[lineString.index(after: colon)...])
            let decoded = decodeBase64OrMissing(value)
            switch key {
            case "P": snapshot.personality = decoded
            case "U": snapshot.ui = decoded
            case "A": snapshot.agents = decoded
            case "L1": snapshot.legacyClaudeDirectory = decoded
            case "L2": snapshot.legacyClaudeRoot = decoded
            default: break
            }
        }
        return snapshot
    }

    private static func decodeBase64OrMissing(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "MISSING" {
            return nil
        }
        let cleaned = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: cleaned),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func readRemoteFileIfPresent(session: SSHSession, path: String) async throws -> String? {
        let escaped = shellEscaped(path)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let start = "__R_\(token)__"
        let end = "__E_\(token)__"
        let command = [
            "printf \(shellEscaped(start));",
            "if [ -f \(escaped) ]; then (base64 -w 0 \(escaped) 2>/dev/null || base64 \(escaped)); else printf MISSING; fi;",
            "printf \(shellEscaped(end))",
        ].joined(separator: " ")
        let output = try await session.execute(command)
        guard let startRange = output.range(of: start),
              let endRange = output.range(of: end),
              startRange.upperBound <= endRange.lowerBound else {
            return nil
        }
        let payload = String(output[startRange.upperBound..<endRange.lowerBound])
        return decodeBase64OrMissing(payload)
    }

    private static func writeRemoteFile(session: SSHSession, path: String, content: String) async throws {
        let directory = (path as NSString).deletingLastPathComponent
        let base64 = Data(content.utf8).base64EncodedString()
        let command = [
            "mkdir -p \(shellEscaped(directory))",
            "printf '%s' \(shellEscaped(base64)) | base64 -d > \(shellEscaped(path))",
        ].joined(separator: " && ")
        _ = try await session.execute(command)
    }

    private static func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
