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
}
