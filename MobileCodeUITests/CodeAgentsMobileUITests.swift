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

    func testAgentRuntimeSettingsShowsOpenCodeDefaultAndLegacyFallback() throws {
        try openSettingsFromAgentsScreen()

        let runtimeLink = app.buttons["settings-agent-runtime-link"].firstMatch
        XCTAssertTrue(runtimeLink.waitForExistence(timeout: 5))
        runtimeLink.tap()

        XCTAssertTrue(app.navigationBars["Agent Runtime"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OpenCode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["New agents use OpenCode by default. Existing legacy agents stay on Claude Proxy until you switch them here."].exists)
        let runtimePicker = app.descendants(matching: .any)["agent-runtime-picker"].firstMatch
        XCTAssertTrue(runtimePicker.waitForExistence(timeout: 5))
        XCTAssertTrue((runtimePicker.value as? String)?.contains("Claude Proxy (Legacy)") == true)
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
}
