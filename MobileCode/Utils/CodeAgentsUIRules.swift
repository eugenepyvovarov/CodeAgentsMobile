//
//  CodeAgentsUIRules.swift
//  CodeAgentsMobile
//
//  Purpose: Canonical CodeAgents UI rules shared by prompt injection and server rules file.
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

    static func ensureRulesFile(
        session: SSHSession,
        project: RemoteProject,
        onlyIfMissing: Bool
    ) async throws {
        let rulesDirectory = shellEscaped("\(project.path)/.claude/rules")
        let rulesPath = shellEscaped("\(project.path)/.claude/rules/codeagents-ui.md")

        if onlyIfMissing {
            let checkCommand = "[ -f \(rulesPath) ] && echo EXISTS || echo MISSING"
            let output = try await session.execute(checkCommand)
            if output.contains("EXISTS") {
                return
            }
        }

        let base64Content = Data(rulesMarkdown.utf8).base64EncodedString()
        let writeCommand = [
            "mkdir -p \(rulesDirectory)",
            "printf '%s' '\(base64Content)' | base64 -d > \(rulesPath)"
        ].joined(separator: " && ")
        _ = try await session.execute(writeCommand)
    }

    private static func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
