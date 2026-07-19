import XCTest
@testable import CodeAgentsMobile

final class AppVersionMetadataTests: XCTestCase {
    func testDisplayStringIncludesMarketingVersionAndBuildNumber() {
        let metadata = AppVersionMetadata(
            infoDictionary: [
                "CFBundleShortVersionString": "1.7",
                "CFBundleVersion": "4636",
            ]
        )

        XCTAssertEqual(metadata.displayString, "1.7 (4636)")
    }

    func testDisplayStringFallsBackToAvailableValue() {
        XCTAssertEqual(
            AppVersionMetadata(infoDictionary: ["CFBundleShortVersionString": "1.7"]).displayString,
            "1.7"
        )
        XCTAssertEqual(
            AppVersionMetadata(infoDictionary: ["CFBundleVersion": "4636"]).displayString,
            "4636"
        )
    }

    func testDisplayStringUsesPlaceholderWhenMetadataIsMissing() {
        XCTAssertEqual(AppVersionMetadata(infoDictionary: [:]).displayString, "—")
    }
}
