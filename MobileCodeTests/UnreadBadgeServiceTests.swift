import XCTest
@testable import CodeAgentsMobile

final class UnreadBadgeServiceTests: XCTestCase {
    func testTotalUnreadSumsAgents() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let total = UnreadBadgeMath.totalUnread(
            projectUnreads: [
                (a, 2),
                (b, 5),
                (c, 0)
            ]
        )
        XCTAssertEqual(total, 7)
    }

    func testTotalUnreadExcludesActiveAgent() {
        let a = UUID()
        let b = UUID()
        let total = UnreadBadgeMath.totalUnread(
            projectUnreads: [
                (a, 3),
                (b, 4)
            ],
            excludingProjectID: a
        )
        XCTAssertEqual(total, 4)
    }

    func testTotalUnreadIgnoresNegative() {
        let a = UUID()
        let total = UnreadBadgeMath.totalUnread(
            projectUnreads: [(a, -3), (UUID(), 2)]
        )
        XCTAssertEqual(total, 2)
    }

    func testBadgeTextFormatting() {
        XCTAssertNil(UnreadBadgeMath.badgeText(for: 0))
        XCTAssertEqual(UnreadBadgeMath.badgeText(for: 1), "1")
        XCTAssertEqual(UnreadBadgeMath.badgeText(for: 12), "12")
        XCTAssertEqual(UnreadBadgeMath.badgeText(for: 100), "99+")
        XCTAssertEqual(UnreadBadgeMath.badgeText(for: 999), "99+")
    }
}
