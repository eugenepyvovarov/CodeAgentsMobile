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
