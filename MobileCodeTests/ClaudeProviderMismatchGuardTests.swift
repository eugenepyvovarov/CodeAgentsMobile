import XCTest
@testable import CodeAgentsMobile

final class ClaudeProviderMismatchGuardTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "ClaudeProviderMismatchGuardTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    func testMismatchIsNilWhenProjectHasNoRecordedProvider() throws {
        let defaults = makeIsolatedDefaults()
        var config = ClaudeProviderConfiguration.defaults()
        config.selectedProvider = .anthropic
        ClaudeProviderConfigurationStore.save(config, userDefaults: defaults)

        let project = RemoteProject(name: "Test", serverId: UUID())
        project.lastSuccessfulClaudeProviderRawValue = nil

        XCTAssertNil(ClaudeProviderMismatchGuard.mismatch(for: project, userDefaults: defaults))
    }

    func testMismatchIsNilWhenProvidersMatch() throws {
        let defaults = makeIsolatedDefaults()
        var config = ClaudeProviderConfiguration.defaults()
        config.selectedProvider = .zAI
        ClaudeProviderConfigurationStore.save(config, userDefaults: defaults)

        let project = RemoteProject(name: "Test", serverId: UUID())
        project.lastSuccessfulClaudeProviderRawValue = ClaudeModelProvider.zAI.rawValue

        XCTAssertNil(ClaudeProviderMismatchGuard.mismatch(for: project, userDefaults: defaults))
    }

    func testMismatchIsReturnedWhenProvidersDiffer() throws {
        let defaults = makeIsolatedDefaults()
        var config = ClaudeProviderConfiguration.defaults()
        config.selectedProvider = .anthropic
        ClaudeProviderConfigurationStore.save(config, userDefaults: defaults)

        let project = RemoteProject(name: "Test", serverId: UUID())
        project.lastSuccessfulClaudeProviderRawValue = ClaudeModelProvider.miniMax.rawValue

        let mismatch = ClaudeProviderMismatchGuard.mismatch(for: project, userDefaults: defaults)
        XCTAssertEqual(mismatch?.previous, .miniMax)
        XCTAssertEqual(mismatch?.current, .anthropic)
        XCTAssertEqual(mismatch?.title, "Provider changed: MiniMax → Anthropic")
    }
}

