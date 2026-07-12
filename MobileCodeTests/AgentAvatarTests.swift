//
//  AgentAvatarTests.swift
//  CodeAgentsMobileTests
//

import XCTest
@testable import CodeAgentsMobile

final class AgentAvatarTests: XCTestCase {
    func testIdentityDocumentRoundTripPreservesAvatar() throws {
        let avatar = AgentAvatarDescriptor(
            kind: .emoji,
            emoji: "🚀",
            image: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedBy: .user
        )
        let doc = CodeAgentsIdentityDocument(agentId: "agent-1", avatar: avatar)
        let data = try doc.encodeJSON()
        let decoded = try CodeAgentsIdentityDocument.decode(from: data)
        XCTAssertEqual(decoded.agentId, "agent-1")
        XCTAssertEqual(decoded.avatar?.kind, .emoji)
        XCTAssertEqual(decoded.avatar?.emoji, "🚀")
        XCTAssertEqual(decoded.avatar?.updatedBy, .user)
        XCTAssertEqual(decoded.schemaVersion, CodeAgentsIdentityDocument.currentSchemaVersion)
    }

    func testIdentityDecodeWithoutAvatar() throws {
        let json = """
        {"schema_version":1,"agent_id":"abc"}
        """
        let decoded = try CodeAgentsIdentityDocument.decode(from: Data(json.utf8))
        XCTAssertEqual(decoded.agentId, "abc")
        XCTAssertNil(decoded.avatar)
    }

    func testPathValidationRejectsEscape() {
        XCTAssertNil(AgentAvatarPathValidation.validatedProjectRelativePath("/etc/passwd"))
        XCTAssertNil(AgentAvatarPathValidation.validatedProjectRelativePath("../secret.png"))
        XCTAssertNil(AgentAvatarPathValidation.validatedProjectRelativePath("foo/../bar.png"))
        XCTAssertNil(AgentAvatarPathValidation.validatedProjectRelativePath("~/.ssh/id_rsa"))
        XCTAssertEqual(
            AgentAvatarPathValidation.validatedProjectRelativePath(".codeagents/avatar.png"),
            ".codeagents/avatar.png"
        )
        XCTAssertEqual(
            AgentAvatarPathValidation.validatedProjectRelativePath("assets/logo.png"),
            "assets/logo.png"
        )
    }

    func testNormalizeEmojiKeepsFirstGrapheme() {
        XCTAssertEqual(AgentAvatarService.normalizeEmoji("  🚀🎉 "), "🚀")
        XCTAssertEqual(AgentAvatarService.normalizeEmoji(""), "")
    }

    func testDuplicateRequestDefaultsCopyAvatarOn() {
        let request = DuplicateAgentRequest(
            sourceProjectId: UUID(),
            displayName: "Copy",
            folderName: "copy"
        )
        XCTAssertTrue(request.copyAvatar)
    }

    func testManagedAvatarServerName() {
        XCTAssertTrue(MCPServer.isManagedServer(MCPServer.managedAvatarServerName))
        XCTAssertTrue(MCPServer.isManagedAvatarServer(MCPServer.managedAvatarServerName))
        XCTAssertFalse(MCPServer.isManagedSchedulerServer(MCPServer.managedAvatarServerName))
    }

    func testAvatarViewMonogramUnchanged() {
        XCTAssertEqual(AgentAvatarView.monogram(from: "Ops Bot"), "OB")
    }
}
