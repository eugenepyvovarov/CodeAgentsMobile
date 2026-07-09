import XCTest

final class CodeAgentsMobileUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-test-defaults"]
        app.launch()
    }

    func testAppLaunches() throws {
        XCTAssertTrue(app.state == .runningForeground)
    }

    func testLaunchShowsPrimaryEntryPoint() throws {
        switch detectRootUI() {
        case .tabs:
            XCTAssertTrue(app.tabBars.buttons["Chat"].exists)
            XCTAssertTrue(app.tabBars.buttons["Files"].exists)
            XCTAssertTrue(app.tabBars.buttons["Regular Tasks"].exists)
        case .agents:
            XCTAssertTrue(app.navigationBars["Agents"].exists || app.buttons["Create Agent"].exists)
        }
    }

    func testTabNavigationWhenProjectIsActive() throws {
        guard detectRootUI() == .tabs else {
            throw XCTSkip("Skipping tab navigation: no active project at launch.")
        }

        let chatTab = app.tabBars.buttons["Chat"]
        let filesTab = app.tabBars.buttons["Files"]
        let tasksTab = app.tabBars.buttons["Regular Tasks"]

        XCTAssertTrue(chatTab.exists)
        XCTAssertTrue(filesTab.exists)
        XCTAssertTrue(tasksTab.exists)

        filesTab.tap()
        XCTAssertTrue(filesTab.isSelected)

        tasksTab.tap()
        XCTAssertTrue(tasksTab.isSelected)

        chatTab.tap()
        XCTAssertTrue(chatTab.isSelected)
    }

    func testOpenSettingsFromAgentsScreen() throws {
        try openSettingsFromAgentsScreen()
    }

    func testOpenCodeSettingsExposesAIProvidersWithoutRuntimeScreen() throws {
        try openSettingsFromAgentsScreen()

        XCTAssertTrue(app.staticTexts["OpenCode"].waitForExistence(timeout: 5), "Settings should group OpenCode controls.")

        // Runtime & health was a multi-runtime leftover — AI Providers is the only entry.
        XCTAssertFalse(app.buttons["settings-agent-runtime-link"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Runtime & health"].exists)
        XCTAssertFalse(app.staticTexts["Claude Proxy (Legacy)"].exists)

        let providersLink = app.buttons["settings-ai-providers-link"].firstMatch
        XCTAssertTrue(providersLink.waitForExistence(timeout: 5))
        providersLink.tap()

        // Global AI Providers home (status card; save lives in Change → model step).
        XCTAssertTrue(
            app.navigationBars["AI Providers"].waitForExistence(timeout: 5)
                || app.navigationBars["OpenCode AI"].waitForExistence(timeout: 2),
            "AI Providers screen should open from Settings."
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["opencode-ai-change-setup-button"].firstMatch.waitForExistence(timeout: 8),
            "AI Providers home should show the current setup card."
        )
        XCTAssertFalse(
            app.buttons["opencode-ai-apply-all-servers-button"].firstMatch.exists,
            "Home sticky Apply was removed; save belongs to model selection."
        )
    }

    func testSettingsAIProvidersIsOpenCodeOnlyWithoutModePicker() throws {
        try openSettingsFromAgentsScreen()

        XCTAssertFalse(app.staticTexts["OpenCode AI Providers"].exists)
        XCTAssertFalse(app.staticTexts["Legacy Claude Provider"].exists)
        XCTAssertFalse(app.staticTexts["Claude Code Proxy"].exists)

        let providersLink = app.buttons["settings-ai-providers-link"].firstMatch
        XCTAssertTrue(providersLink.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["AI Providers"].exists)
        providersLink.tap()

        XCTAssertTrue(app.navigationBars["AI Providers"].waitForExistence(timeout: 5))
        // Dual-runtime segmented control is gone — OpenCode is the only chat path.
        XCTAssertFalse(app.descendants(matching: .any)["ai-provider-settings-mode-picker"].exists)
        XCTAssertFalse(app.segmentedControls.buttons["Claude Code Proxy"].exists)
        XCTAssertFalse(app.segmentedControls.buttons["Legacy Claude (Tasks)"].exists)

        let modeMarker = app.descendants(matching: .any)["ai-provider-settings-mode"].firstMatch
        XCTAssertTrue(modeMarker.waitForExistence(timeout: 5))
        XCTAssertEqual(modeMarker.value as? String, "openCode")
    }

    func testSettingsExposeMCPAndSkillsManagement() throws {
        try openSettingsFromAgentsScreen()

        let mcpLink = app.staticTexts["MCP Servers"].firstMatch
        XCTAssertTrue(scrollToElement(mcpLink, timeout: 10), "Settings did not expose the MCP Servers entry.")

        let skillsLink = app.staticTexts["Agent Skills"].firstMatch
        XCTAssertTrue(scrollToElement(skillsLink, timeout: 10), "Settings did not expose the Agent Skills entry.")
        skillsLink.tap()
        XCTAssertTrue(app.navigationBars["Agent Skills"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["agent-skills-add-menu-button"].waitForExistence(timeout: 5)
                || app.buttons["agent-skills-browse-marketplaces-button"].waitForExistence(timeout: 5)
        )
    }

    func testSettingsExposeAffectedListSectionsAndAddEntries() throws {
        try openSettingsFromAgentsScreen()

        let cloudProvidersSection = app.staticTexts["Cloud Providers"].firstMatch
        XCTAssertTrue(
            cloudProvidersSection.waitForExistence(timeout: 5),
            "Settings did not expose the Cloud Providers section."
        )

        let addCloudProviderButton = app.buttons["settings-add-cloud-provider-button"].firstMatch
        XCTAssertTrue(
            addCloudProviderButton.waitForExistence(timeout: 5),
            "Settings did not expose the Add Cloud Provider entry."
        )

        let sshKeysSection = app.staticTexts["SSH Keys"].firstMatch
        XCTAssertTrue(scrollToElement(sshKeysSection, timeout: 10), "Settings did not expose the SSH Keys section.")

        let addSSHKeyButton = app.buttons["settings-add-ssh-key-button"].firstMatch
        XCTAssertTrue(scrollToElement(addSSHKeyButton, timeout: 10), "Settings did not expose the Add SSH Key entry.")
    }

    func testManualServerFlowIncludesOpenCodeServerAuthSetup() throws {
        try openSettingsFromAgentsScreen()

        let addServerButton = app.buttons["settings-add-server-button"].firstMatch
        XCTAssertTrue(addServerButton.waitForExistence(timeout: 5))
        addServerButton.tap()

        XCTAssertTrue(app.navigationBars["Add Server"].waitForExistence(timeout: 5))
        let manualSegment = app.segmentedControls.buttons["Manual"].firstMatch
        XCTAssertTrue(manualSegment.waitForExistence(timeout: 5))
        manualSegment.tap()

        XCTAssertTrue(app.staticTexts["OPENCODE SERVER"].waitForExistence(timeout: 5))
        let authToggle = app.switches["manual-server-opencode-auth-toggle"].firstMatch
        XCTAssertTrue(authToggle.waitForExistence(timeout: 5))
        authToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(authToggle.value as? String, "1")
        app.swipeUp()

        let usernameField = app.textFields["manual-server-opencode-username-field"].firstMatch
        let usernameFieldByLabel = app.textFields["OpenCode Username"].firstMatch
        XCTAssertTrue(
            usernameField.waitForExistence(timeout: 5) || usernameFieldByLabel.waitForExistence(timeout: 5)
        )
        let passwordField = app.secureTextFields["manual-server-opencode-password-field"].firstMatch
        let passwordFieldByLabel = app.secureTextFields["OpenCode Server Password"].firstMatch
        XCTAssertTrue(
            passwordField.waitForExistence(timeout: 5) || passwordFieldByLabel.waitForExistence(timeout: 5)
        )
    }

    /// PR12: chat and settings must not surface retired Claude CLI install / token UX.
    func testNoClaudeCLIInstallOrLegacyAuthSheetsOnLaunchSurfaces() throws {
        // Agents / tabs root — never show Claude CLI not-installed copy.
        XCTAssertFalse(app.staticTexts["Claude CLI Not Installed"].exists)
        XCTAssertFalse(app.staticTexts["Claude Code is not installed"].exists)
        XCTAssertFalse(app.staticTexts["Install Claude Code"].exists)

        // Settings dead sheets (API Configuration / Token Configuration) have no entry points.
        if detectRootUI() == .agents {
            try openSettingsFromAgentsScreen()
            XCTAssertFalse(app.staticTexts["Claude Code Authentication Token"].exists)
            XCTAssertFalse(app.navigationBars["Token Configuration"].exists)
            XCTAssertFalse(app.navigationBars["API Configuration"].exists)
            XCTAssertFalse(app.staticTexts["claude setup-token"].exists)
        }
    }

    func testRegularTasksTabDoesNotExposeClaudeCodeServiceChrome() throws {
        guard detectRootUI() == .tabs else {
            throw XCTSkip("Skipping tasks Claude-absence check: no active project tabs.")
        }

        let tasksTab = app.tabBars.buttons["Regular Tasks"]
        XCTAssertTrue(tasksTab.waitForExistence(timeout: 5))
        tasksTab.tap()

        XCTAssertFalse(app.staticTexts["Claude Proxy (Legacy)"].exists)
        XCTAssertFalse(app.staticTexts["Legacy Claude Provider"].exists)
        XCTAssertFalse(app.staticTexts["Claude CLI Not Installed"].exists)
        // Task Provider sheet is only via mismatch banner; default list should be clean.
        XCTAssertFalse(app.navigationBars["Legacy Claude Provider"].exists)
    }

    private func openSettingsFromAgentsScreen() throws {
        guard detectRootUI() == .agents else {
            throw XCTSkip("Skipping settings flow: app launched directly into active-project tabs.")
        }

        let agentsNavBar = app.navigationBars["Agents"]
        XCTAssertTrue(agentsNavBar.waitForExistence(timeout: 5))

        let settingsButton = app.buttons["agents-settings-button"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        let settingsNavigationBar = app.navigationBars["Settings"]
        if !settingsNavigationBar.waitForExistence(timeout: 2) {
            settingsButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(settingsNavigationBar.waitForExistence(timeout: 5))
    }

    private enum RootUI {
        case tabs
        case agents
    }

    private func detectRootUI() -> RootUI {
        if app.tabBars.buttons["Chat"].waitForExistence(timeout: 6) {
            return .tabs
        }

        if app.navigationBars["Agents"].waitForExistence(timeout: 4)
            || app.buttons["Create Agent"].waitForExistence(timeout: 4) {
            return .agents
        }

        XCTFail("Could not detect root UI. Expected Chat tabs or Agents screen.")
        return .agents
    }

    private func scrollToElement(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                return true
            }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return element.exists && element.isHittable
    }
}
