//
//  OpenCodePendingPermissionTests.swift
//  CodeAgentsMobileTests
//

import XCTest
@testable import CodeAgentsMobile

final class OpenCodePendingPermissionTests: XCTestCase {
    func testMakeToolApprovalRequestMapsStableTypeAndPaths() throws {
        let json = """
        {
          "id":"per_fixture",
          "sessionID":"ses_fixture",
          "permission":"external_directory",
          "patterns":["/home/codeagent/.config/opencode/*","/tmp/*"],
          "metadata":{
            "command":"ls",
            "directories":["/home/codeagent/.config/opencode"],
            "patterns":["/home/codeagent/.config/opencode/*"]
          },
          "always":["/home/codeagent/.config/opencode/*"],
          "tool":{"messageID":"msg_fixture","callID":"call_fixture"}
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(OpenCodePendingPermission.self, from: json)
        let agentId = UUID()
        let request = try XCTUnwrap(item.makeToolApprovalRequest(agentId: agentId))

        XCTAssertEqual(request.id, "per_fixture")
        XCTAssertEqual(request.toolName, "external_directory")
        XCTAssertEqual(request.agentId, agentId)
        XCTAssertEqual(request.blockedPath, "/home/codeagent/.config/opencode")
        XCTAssertEqual(request.suggestions, ["/home/codeagent/.config/opencode/*", "/tmp/*"])
        XCTAssertEqual(request.input["command"] as? String, "ls")
        XCTAssertEqual(request.input["callID"] as? String, "call_fixture")
    }

    func testMakeToolApprovalRequestFallsBackToAlwaysPatterns() throws {
        let json = """
        {
          "id":"per_bash",
          "sessionID":"ses_fixture",
          "permission":"bash",
          "always":["*.swift"],
          "metadata":{"path":"Sources/App.swift"}
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(OpenCodePendingPermission.self, from: json)
        let request = try XCTUnwrap(item.makeToolApprovalRequest(agentId: UUID()))

        XCTAssertEqual(request.toolName, "bash")
        XCTAssertEqual(request.suggestions, ["*.swift"])
        XCTAssertEqual(request.blockedPath, "Sources/App.swift")
    }

    func testMatchingSessionFiltersOtherSessionsAndEmpty() {
        let matching = OpenCodePendingPermission(
            id: "a",
            sessionID: "ses_target",
            permission: "bash",
            patterns: nil,
            always: nil,
            metadata: nil,
            tool: nil
        )
        let other = OpenCodePendingPermission(
            id: "b",
            sessionID: "ses_other",
            permission: "bash",
            patterns: nil,
            always: nil,
            metadata: nil,
            tool: nil
        )
        let missing = OpenCodePendingPermission(
            id: "c",
            sessionID: nil,
            permission: "bash",
            patterns: nil,
            always: nil,
            metadata: nil,
            tool: nil
        )

        let filtered = OpenCodePendingPermission.matchingSession(
            [matching, other, missing],
            sessionID: "ses_target"
        )
        XCTAssertEqual(filtered.map(\.id), ["a"])
        XCTAssertTrue(OpenCodePendingPermission.matchingSession([matching], sessionID: "  ").isEmpty)
    }

    func testEmptyPermissionIdDoesNotMap() throws {
        let json = """
        {"id":"   ","sessionID":"ses","permission":"bash"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(OpenCodePendingPermission.self, from: json)
        XCTAssertNil(item.makeToolApprovalRequest(agentId: UUID()))
    }

    func testExternalDirectoryDisplayName() {
        XCTAssertEqual(
            ToolPermissionInfo.displayName(for: "external_directory"),
            "Access Outside Project"
        )
        XCTAssertFalse(ToolPermissionInfo.summary(for: "external_directory").isEmpty)
    }
}
