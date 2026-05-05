import XCTest
@testable import CodeAgentsMobile

final class CloudServerSheetRoutingTests: XCTestCase {
    func testServerListRouteSurvivesSelectionClearing() {
        let providerID = UUID()
        var state = CloudProviderSelectionState()

        state.selectProvider(id: providerID)
        state.presentSelectedProvider()
        state.selectedProviderID = nil

        XCTAssertEqual(state.serverListRoute?.providerID, providerID)
    }

    func testServerListRouteDoesNotPresentWithoutSelection() {
        var state = CloudProviderSelectionState()

        state.presentSelectedProvider()

        XCTAssertNil(state.serverListRoute)
        XCTAssertFalse(state.canPresentServerList)
    }

    func testDismissingServerListClearsRoutePayload() {
        var state = CloudProviderSelectionState()

        state.selectProvider(id: UUID())
        state.presentSelectedProvider()
        state.dismissServerList()

        XCTAssertNil(state.serverListRoute)
    }

    func testProjectCreationRouteRequiresCreatedServerID() {
        XCTAssertNil(CloudServerProjectCreationRoute.route(for: nil))

        let serverID = UUID()
        let route = CloudServerProjectCreationRoute.route(for: serverID)

        XCTAssertEqual(route?.serverID, serverID)
        XCTAssertEqual(route?.id, serverID)
    }
}
