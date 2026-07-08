import XCTest
@testable import CodeAgentsMobile

@MainActor
final class AgentDaemonAuthServiceTests: XCTestCase {
    func testAuthMethodDefaultsToAPIKey() throws {
        let defaults = try makeDefaults()
        let service = AgentDaemonAuthService(userDefaults: defaults)

        XCTAssertEqual(service.getCurrentAuthMethod(), .apiKey)
    }

    func testAuthMethodPersistsAcrossInstances() throws {
        let defaults = try makeDefaults()
        let service = AgentDaemonAuthService(userDefaults: defaults)

        service.setAuthMethod(.token)

        XCTAssertEqual(service.getCurrentAuthMethod(), .token)
        XCTAssertEqual(
            defaults.string(forKey: AgentDaemonAuthService.authMethodKey),
            ClaudeAuthMethod.token.rawValue
        )

        let reloaded = AgentDaemonAuthService(userDefaults: defaults)
        XCTAssertEqual(reloaded.getCurrentAuthMethod(), .token)
    }

    func testUnknownStoredValueFallsBackToAPIKey() throws {
        let defaults = try makeDefaults()
        defaults.set("futureMethod", forKey: AgentDaemonAuthService.authMethodKey)
        let service = AgentDaemonAuthService(userDefaults: defaults)

        XCTAssertEqual(service.getCurrentAuthMethod(), .apiKey)
    }

    func testHistoricalAuthMethodKeyNameUnchanged() throws {
        let defaults = try makeDefaults()
        // Ensure the legacy UserDefaults key name is unchanged for existing installs.
        XCTAssertEqual(AgentDaemonAuthService.authMethodKey, "claudeAuthMethod")

        let service = AgentDaemonAuthService(userDefaults: defaults)
        service.setAuthMethod(.token)

        XCTAssertEqual(defaults.string(forKey: "claudeAuthMethod"), "token")
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AgentDaemonAuthServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
