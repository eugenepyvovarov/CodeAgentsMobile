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
        project.selectedAgentRuntime = .claudeProxy
        project.lastSuccessfulClaudeProviderRawValue = nil

        XCTAssertNil(ClaudeProviderMismatchGuard.mismatch(for: project, userDefaults: defaults))
    }

    func testMismatchIsNilWhenProvidersMatch() throws {
        let defaults = makeIsolatedDefaults()
        var config = ClaudeProviderConfiguration.defaults()
        config.selectedProvider = .zAI
        ClaudeProviderConfigurationStore.save(config, userDefaults: defaults)

        let project = RemoteProject(name: "Test", serverId: UUID())
        project.selectedAgentRuntime = .claudeProxy
        project.lastSuccessfulClaudeProviderRawValue = ClaudeModelProvider.zAI.rawValue

        XCTAssertNil(ClaudeProviderMismatchGuard.mismatch(for: project, userDefaults: defaults))
    }

    func testMismatchIsReturnedWhenProvidersDiffer() throws {
        let defaults = makeIsolatedDefaults()
        var config = ClaudeProviderConfiguration.defaults()
        config.selectedProvider = .anthropic
        ClaudeProviderConfigurationStore.save(config, userDefaults: defaults)

        let project = RemoteProject(name: "Test", serverId: UUID())
        project.selectedAgentRuntime = .claudeProxy
        project.lastSuccessfulClaudeProviderRawValue = ClaudeModelProvider.miniMax.rawValue

        let mismatch = ClaudeProviderMismatchGuard.mismatch(for: project, userDefaults: defaults)
        XCTAssertEqual(mismatch?.previous, .miniMax)
        XCTAssertEqual(mismatch?.current, .anthropic)
        XCTAssertEqual(mismatch?.title, "Provider changed: MiniMax → Anthropic")
    }

    func testMismatchIsIgnoredForOpenCodeProjects() throws {
        let defaults = makeIsolatedDefaults()
        var config = ClaudeProviderConfiguration.defaults()
        config.selectedProvider = .anthropic
        ClaudeProviderConfigurationStore.save(config, userDefaults: defaults)

        let project = RemoteProject(name: "Test", serverId: UUID())
        project.selectedAgentRuntime = .openCode
        project.lastSuccessfulClaudeProviderRawValue = ClaudeModelProvider.miniMax.rawValue

        XCTAssertNil(ClaudeProviderMismatchGuard.mismatch(for: project, userDefaults: defaults))
    }

    func testMismatchIsIgnoredForOpenCodeProjectEvenWhenLegacyProviderChanged() throws {
        let defaults = makeIsolatedDefaults()
        var config = ClaudeProviderConfiguration.defaults()
        config.selectedProvider = .moonshot
        ClaudeProviderConfigurationStore.save(config, userDefaults: defaults)

        let project = RemoteProject(name: "OpenCode Project", serverId: UUID())
        project.selectedAgentRuntime = .openCode
        project.lastSuccessfulClaudeProviderRawValue = ClaudeModelProvider.anthropic.rawValue

        XCTAssertNil(ClaudeProviderMismatchGuard.mismatch(for: project, userDefaults: defaults))
    }

    func testMismatchRemainsAvailableForClaudeProxyProjectContext() throws {
        let defaults = makeIsolatedDefaults()
        var config = ClaudeProviderConfiguration.defaults()
        config.selectedProvider = .moonshot
        ClaudeProviderConfigurationStore.save(config, userDefaults: defaults)

        let project = RemoteProject(name: "Legacy Project", serverId: UUID())
        project.selectedAgentRuntime = .claudeProxy
        project.lastSuccessfulClaudeProviderRawValue = ClaudeModelProvider.anthropic.rawValue

        let mismatch = ClaudeProviderMismatchGuard.mismatch(for: project, userDefaults: defaults)

        XCTAssertEqual(mismatch?.previous, .anthropic)
        XCTAssertEqual(mismatch?.current, .moonshot)
        XCTAssertEqual(mismatch?.message, "Clear chat to continue, or switch back to Anthropic.")
    }
}
