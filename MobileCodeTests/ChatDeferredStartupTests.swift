import XCTest
@testable import CodeAgentsMobile

final class ChatDeferredStartupTests: XCTestCase {
    func testSendTimeMCPPolicyFetchesWhenCacheIsEmpty() {
        let now = Date()

        XCTAssertTrue(ChatMCPServerCachePolicy.needsFetch(
            cachedServerCount: 0,
            isInvalidated: false,
            lastFetchedAt: now,
            now: now,
            staleInterval: 300
        ))
    }

    func testSendTimeMCPPolicyFetchesWhenCacheWasInvalidated() {
        let now = Date()

        XCTAssertTrue(ChatMCPServerCachePolicy.needsFetch(
            cachedServerCount: 2,
            isInvalidated: true,
            lastFetchedAt: now,
            now: now,
            staleInterval: 300
        ))
    }

    func testSendTimeMCPPolicyFetchesWhenCacheIsStale() {
        let now = Date()

        XCTAssertTrue(ChatMCPServerCachePolicy.needsFetch(
            cachedServerCount: 2,
            isInvalidated: false,
            lastFetchedAt: now.addingTimeInterval(-301),
            now: now,
            staleInterval: 300
        ))
    }

    func testSendTimeMCPPolicyUsesFreshPopulatedCache() {
        let now = Date()

        XCTAssertFalse(ChatMCPServerCachePolicy.needsFetch(
            cachedServerCount: 2,
            isInvalidated: false,
            lastFetchedAt: now.addingTimeInterval(-60),
            now: now,
            staleInterval: 300
        ))
    }
}
