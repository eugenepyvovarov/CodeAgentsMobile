import XCTest
@testable import CodeAgentsMobile

final class CodeAgentsUIRulesTests: XCTestCase {
    func testEnsureRulesFileChecksAgentsMarkdownPrimaryPath() async throws {
        let session = RulesFakeSSHSession(outputs: ["EXISTS"])
        let project = RemoteProject(name: "app", serverId: UUID(), basePath: "/workspace")

        try await CodeAgentsUIRules.ensureRulesFile(session: session, project: project, onlyIfMissing: true)

        XCTAssertEqual(session.commands.count, 1)
        XCTAssertTrue(session.commands[0].contains("/workspace/app/AGENTS.md"))
        XCTAssertFalse(session.commands[0].contains(".claude/rules"))
    }
}

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
