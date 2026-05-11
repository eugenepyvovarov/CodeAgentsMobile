import XCTest
@testable import CodeAgentsMobile

final class ChatRecoveryTimingTests: XCTestCase {
    func testFormattedLineUsesConsistentPrefixAndSafeScalarFields() {
        let line = ChatRecoveryTiming.formattedLine(
            runtime: "openCode",
            projectID: "project-123",
            operation: "opencode.hydrateMessages",
            elapsedNanoseconds: 123_456_789,
            metadata: [
                "insertedMessages": .count(3),
                "activeSession": .flag(true),
                "status": .status(.complete)
            ]
        )

        XCTAssertEqual(
            line,
            "[ChatRecoveryTiming] runtime=openCode project=project-123 operation=opencode.hydrateMessages elapsedMs=123 activeSession=true insertedMessages=3 status=complete"
        )
    }

    func testFormattedLineRedactsUnsafeStringBoundaries() {
        let line = ChatRecoveryTiming.formattedLine(
            runtime: "openCode http://token.example",
            projectID: "/Users/example/secret-project",
            operation: "hydrate with prompt text",
            elapsedNanoseconds: 1_000_000,
            metadata: [
                "status": .status(.failed),
                "remoteMessages": .count(42)
            ]
        )

        XCTAssertTrue(line.contains("runtime=redacted"))
        XCTAssertTrue(line.contains("project=redacted"))
        XCTAssertTrue(line.contains("operation=redacted"))
        XCTAssertTrue(line.contains("status=failed"))
        XCTAssertTrue(line.contains("remoteMessages=42"))
        XCTAssertFalse(line.contains("/Users/example"))
        XCTAssertFalse(line.contains("secret-project"))
        XCTAssertFalse(line.contains("http://token.example"))
        XCTAssertFalse(line.contains("prompt text"))
    }

    func testFormattedLineSanitizesUnsafeMetadataKeysAndClampsNegativeCounts() {
        let line = ChatRecoveryTiming.formattedLine(
            runtime: "claudeProxy",
            projectID: nil,
            operation: "proxy.sync",
            elapsedNanoseconds: 2_999_999,
            metadata: [
                "events fetched": .count(-5)
            ]
        )

        XCTAssertEqual(
            line,
            "[ChatRecoveryTiming] runtime=claudeProxy project=unknown operation=proxy.sync elapsedMs=2 events_fetched=0"
        )
    }

    func testMeasureReturnsSyncResult() {
        let result = ChatRecoveryTiming.measure(
            runtime: "openCode",
            projectID: "project-123",
            operation: "loadMessages"
        ) {
            7
        }

        XCTAssertEqual(result, 7)
    }

    func testMeasureReturnsAsyncResult() async throws {
        let body: () async throws -> Int = {
            await Task.yield()
            return 11
        }

        let result = try await ChatRecoveryTiming.measure(
            runtime: "openCode",
            projectID: "project-123",
            operation: "hydrateMessages"
        ) { try await body() }

        XCTAssertEqual(result, 11)
    }
}
