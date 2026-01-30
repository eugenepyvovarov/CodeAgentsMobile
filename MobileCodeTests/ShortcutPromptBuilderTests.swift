import XCTest
@testable import CodeAgentsMobile

final class ShortcutPromptBuilderTests: XCTestCase {
    func testBuildTrimsWhitespace() {
        let result = ShortcutPromptBuilder.build(promptInput: "  Extra details  ")
        XCTAssertEqual(result, "Extra details")
    }
    
    func testBuildWithEmptyInputReturnsEmpty() {
        let result = ShortcutPromptBuilder.build(promptInput: "   ")
        XCTAssertTrue(result.isEmpty)
    }
}

final class SSHCommandResultEvaluatorTests: XCTestCase {
    func testSuccessOnZeroExitStatusReturnsCombinedOutput() {
        let result = SSHCommandResultEvaluator.evaluate(exitStatus: 0, stdout: "ok", stderr: "warn")
        switch result {
        case .success(let output):
            XCTAssertEqual(output, "ok\nwarn")
        case .failure(let error):
            XCTFail("Expected success, got error: \(error)")
        }
    }

    func testFailureOnNonZeroExitStatusEvenWithOutput() {
        let result = SSHCommandResultEvaluator.evaluate(exitStatus: 1, stdout: "oops", stderr: "")
        switch result {
        case .success(let output):
            XCTFail("Expected failure, got output: \(output)")
        case .failure(let error):
            guard case SSHError.commandFailed(let message) = error else {
                return XCTFail("Expected commandFailed, got: \(error)")
            }
            XCTAssertTrue(message.contains("status 1"))
            XCTAssertTrue(message.contains("oops"))
        }
    }

    func testFailureOnNonZeroExitStatusWithoutOutput() {
        let result = SSHCommandResultEvaluator.evaluate(exitStatus: 2, stdout: "", stderr: "")
        switch result {
        case .success(let output):
            XCTFail("Expected failure, got output: \(output)")
        case .failure(let error):
            guard case SSHError.commandFailed(let message) = error else {
                return XCTFail("Expected commandFailed, got: \(error)")
            }
            XCTAssertEqual(message, "Command exited with status 2")
        }
    }

    func testSuccessWithoutExitStatusWithOutput() {
        let result = SSHCommandResultEvaluator.evaluate(exitStatus: nil, stdout: "data", stderr: "")
        switch result {
        case .success(let output):
            XCTAssertEqual(output, "data")
        case .failure(let error):
            XCTFail("Expected success, got error: \(error)")
        }
    }

    func testFailureWithoutExitStatusAndOutput() {
        let result = SSHCommandResultEvaluator.evaluate(exitStatus: nil, stdout: "", stderr: "")
        switch result {
        case .success(let output):
            XCTFail("Expected failure, got output: \(output)")
        case .failure(let error):
            guard case SSHError.commandFailed(let message) = error else {
                return XCTFail("Expected commandFailed, got: \(error)")
            }
            XCTAssertEqual(message, "Channel closed without output")
        }
    }
}
