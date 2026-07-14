import XCTest
@testable import CodeAgentsMobile

final class RegularTaskReconciliationTests: XCTestCase {
    func testLocalIndexKeepsOneCanonicalRowPerRemoteId() {
        let projectId = UUID()
        let older = AgentScheduledTask(
            projectId: projectId,
            prompt: "check",
            remoteId: "remote-1",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let newer = AgentScheduledTask(
            projectId: projectId,
            prompt: "check",
            remoteId: "remote-1",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let localOnly = AgentScheduledTask(projectId: projectId, prompt: "local")

        let index = RegularTaskReconciliation.makeLocalIndex([newer, localOnly, older])

        XCTAssertTrue(index.byRemoteId["remote-1"] === older)
        XCTAssertEqual(index.duplicates.count, 1)
        XCTAssertTrue(index.duplicates[0] === newer)
        XCTAssertTrue(index.byClientTaskId[localOnly.id.uuidString.lowercased()] === localOnly)
    }
}
