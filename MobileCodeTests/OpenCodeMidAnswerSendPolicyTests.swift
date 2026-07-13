import XCTest
@testable import CodeAgentsMobile

final class OpenCodeMidAnswerSendPolicyTests: XCTestCase {
    func testUsesSoftSteerWhenEventStreamIsActive() {
        XCTAssertEqual(
            OpenCodeMidAnswerSendPolicy.mode(isEventStreamActive: true),
            .softSteerPromptOnly
        )
    }

    func testStartsStreamWhenNoEventConsumer() {
        XCTAssertEqual(
            OpenCodeMidAnswerSendPolicy.mode(isEventStreamActive: false),
            .startStream
        )
    }

    func testStreamCompletionStillIgnoresToolOnlyCompleteChunks() {
        let toolChunk = MessageChunk(
            content: "Read done",
            isComplete: true,
            isError: false,
            metadata: ["type": "opencode_tool"]
        )
        let answerChunk = MessageChunk(
            content: "done",
            isComplete: true,
            isError: false,
            metadata: ["type": "assistant"]
        )
        XCTAssertFalse(OpenCodeStreamCompletionPolicy.shouldFinish(after: toolChunk))
        XCTAssertTrue(OpenCodeStreamCompletionPolicy.shouldFinish(after: answerChunk))
    }

    func testIdleGraceKeepsStreamOpenLongEnoughForSoftSteer() {
        // Soft-steer races: session can go idle between the first answer and the
        // follow-up loop. Grace must be non-trivial so prompt_async can resume.
        XCTAssertGreaterThanOrEqual(OpenCodeStreamCompletionPolicy.idleGraceNanoseconds, 1_000_000_000)
        XCTAssertLessThanOrEqual(OpenCodeStreamCompletionPolicy.idleGraceNanoseconds, 10_000_000_000)
    }
}
