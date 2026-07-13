import XCTest
@testable import CodeAgentsMobile

final class CodeAgentsUIRulesTests: XCTestCase {
    func testEnsureRulesFileChecksAgentsMarkdownPrimaryPath() async throws {
        // EXISTS; fake reads return unparseable payloads so guidance patch is skipped.
        let session = RulesFakeSSHSession(outputs: ["EXISTS", "", ""])
        let project = RemoteProject(name: "app", serverId: UUID(), basePath: "/workspace")

        try await CodeAgentsUIRules.ensureRulesFile(session: session, project: project, onlyIfMissing: true)

        XCTAssertGreaterThanOrEqual(session.commands.count, 1)
        XCTAssertTrue(session.commands[0].contains("/workspace/app/AGENTS.md"))
        XCTAssertFalse(session.commands[0].contains(".claude/rules"))
        XCTAssertFalse(session.commands.contains(where: { $0.contains("base64 -d") }))
    }

    func testEnsureRulesFileWhenMissingWritesAspectsAndAssembledAgents() async throws {
        // onlyIfMissing: false skips the EXISTS check and starts with snapshot read.
        // Snapshot returns all MISSING, then three writes (personality, ui, AGENTS.md).
        let emptySnapshot = """
        __RULES_SNAP_START_PLACEHOLDER__
        P:MISSING
        U:MISSING
        A:MISSING
        L1:MISSING
        L2:MISSING
        __RULES_SNAP_END_PLACEHOLDER__
        """
        // The real markers are dynamic UUIDs — fake session returns payload that won't match.
        // Use a session that echoes marker-aware responses via custom logic.
        let session = RulesSnapshotSSHSession(mode: .allMissing)
        let project = RemoteProject(name: "XforY", serverId: UUID(), basePath: "/home/codeagent/projects")

        try await CodeAgentsUIRules.ensureRulesFile(session: session, project: project, onlyIfMissing: false)

        XCTAssertGreaterThanOrEqual(session.commands.count, 4) // snapshot + 3 writes
        let joined = session.commands.joined(separator: "\n")
        XCTAssertTrue(joined.contains("/home/codeagent/projects/XforY/AGENTS.md"))
        XCTAssertTrue(joined.contains(".codeagents/rules/personality.md"))
        XCTAssertTrue(joined.contains(".codeagents/rules/codeagents-ui.md"))
        XCTAssertTrue(joined.contains("mkdir -p"))
        XCTAssertTrue(joined.contains("base64 -d"))
        // Regression: no broken if/then fragments from the old single-file path.
        XCTAssertFalse(joined.contains("then;"))
        XCTAssertFalse(joined.contains("then :;;"))
        _ = emptySnapshot
    }

    func testEnsureRulesFileOnlyIfMissingShortCircuitsWhenAgentsExists() async throws {
        let session = RulesFakeSSHSession(outputs: ["EXISTS", "", ""])
        let project = RemoteProject(name: "app", serverId: UUID(), basePath: "/workspace")

        try await CodeAgentsUIRules.ensureRulesFile(session: session, project: project, onlyIfMissing: true)

        XCTAssertTrue(session.commands[0].contains("[ -f"))
        // Unreadable aspect payloads → no rewrite.
        XCTAssertFalse(session.commands.contains(where: { $0.contains("base64 -d") }))
    }

    func testEnsuringToolCallGuardIdempotent() {
        let once = CodeAgentsUIRules.ensuringToolCallGuard(in: "hello")
        let twice = CodeAgentsUIRules.ensuringToolCallGuard(in: once)
        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.contains("codeagents-ui is NOT a tool"))
        XCTAssertTrue(once.contains("register_project_skill"))
    }

    func testRulesMarkdownIncludesProjectSkillsMCPGuidance() {
        XCTAssertTrue(CodeAgentsUIRules.rulesMarkdown.contains("register_project_skill"))
        XCTAssertTrue(CodeAgentsUIRules.rulesMarkdown.contains("list_project_skills"))
        XCTAssertTrue(CodeAgentsUIRules.rulesMarkdown.contains("codeagents-scheduled-tasks"))
    }
}

// MARK: - Fakes

private final class RulesFakeSSHSession: SSHSession {
    private var outputs: [String]
    private(set) var commands: [String] = []

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func execute(_ command: String) async throws -> String {
        commands.append(command)
        return outputs.isEmpty ? "" : outputs.removeFirst()
    }

    func executeRaw(_ command: String) async throws -> String {
        try await execute(command)
    }

    func startProcess(_ command: String) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not implemented")
    }

    func startProcessRaw(_ command: String) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not implemented")
    }

    func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not implemented")
    }

    func uploadFile(localPath: URL, remotePath: String) async throws { }
    func downloadFile(remotePath: String, localPath: URL) async throws { }
    func readFile(_ remotePath: String) async throws -> String { "" }
    func listDirectory(_ path: String) async throws -> [RemoteFile] { [] }
    func disconnect() { }
}

/// Responds to dynamic snapshot markers by wrapping MISSING payloads.
private final class RulesSnapshotSSHSession: SSHSession {
    enum Mode {
        case allMissing
    }

    let mode: Mode
    private(set) var commands: [String] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func execute(_ command: String) async throws -> String {
        commands.append(command)

        if command.contains("__RULES_SNAP_START_") {
            guard let startKey = extractMarker(prefix: "__RULES_SNAP_START_", from: command),
                  let endKey = extractMarker(prefix: "__RULES_SNAP_END_", from: command) else {
                return ""
            }
            return """
            \(startKey)
            P:MISSING
            U:MISSING
            A:MISSING
            L1:MISSING
            L2:MISSING
            \(endKey)
            """
        }

        // write commands
        return ""
    }

    func executeRaw(_ command: String) async throws -> String {
        try await execute(command)
    }

    func startProcess(_ command: String) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not implemented")
    }

    func startProcessRaw(_ command: String) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not implemented")
    }

    func openDirectTCPIP(targetHost: String, targetPort: Int) async throws -> ProcessHandle {
        throw SSHError.commandFailed("Not implemented")
    }

    func uploadFile(localPath: URL, remotePath: String) async throws { }
    func downloadFile(remotePath: String, localPath: URL) async throws { }
    func readFile(_ remotePath: String) async throws -> String { "" }
    func listDirectory(_ path: String) async throws -> [RemoteFile] { [] }
    func disconnect() { }

    private func extractMarker(prefix: String, from command: String) -> String? {
        // Markers are single-quoted in printf 'MARKER'
        guard let range = command.range(of: prefix) else { return nil }
        let from = range.lowerBound
        var end = from
        while end < command.endIndex {
            let ch = command[end]
            if ch == "'" || ch == "\"" || ch.isWhitespace || ch == ";" {
                break
            }
            end = command.index(after: end)
        }
        return String(command[from..<end])
    }
}
