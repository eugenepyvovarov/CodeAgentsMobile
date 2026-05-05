import Foundation
import UIKit
import XCTest

final class OpenCodeCloudMutationE2ETests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCloudProviderCredentialCanBeAddedThroughUI() throws {
        let config = try CloudE2EConfiguration.load(requireMutation: false)
        launchApp(config: config, autofillCloudServer: false)

        try openSettingsFromAgentsScreen()
        try addCloudProvider(config)

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20))
    }

    func testCloudServerCanBeCreatedThroughUIWhenMutationIsAllowed() throws {
        let config = try CloudE2EConfiguration.load(requireMutation: true)
        try registerCloudServerCleanup(config)
        launchApp(config: config, autofillCloudServer: true)

        try openSettingsFromAgentsScreen()
        try addCloudProvider(config)
        try openCreateCloudServerFlow(config)
        try generateAndSelectSSHKey(config)

        let createButton = app.buttons["cloud-server-create-button"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 20))
        XCTAssertTrue(createButton.isEnabled, "Create button stayed disabled after E2E autofill and SSH key selection.")
        createButton.tap()

        if config.shouldConfigureAIProvider {
            try waitForProvisioningToReachSuccess(timeout: config.provisioningTimeout)
            try createAgentAfterProvisioning(config)
            try saveOpenCodeAIProviderKey(config)
            try startChat(config)
            try verifyOpenCodeMCPAndSkillsSettings()
            try verifyRegularTaskEditorUX()
        } else {
            try waitForProvisioningToReachActionableState(timeout: config.provisioningTimeout)

            let skipButton = app.buttons["cloud-server-skip-button"].firstMatch
            XCTAssertTrue(skipButton.waitForExistence(timeout: 10))
            skipButton.tap()
        }
    }

    private func registerCloudServerCleanup(_ config: CloudE2EConfiguration) throws {
        try CloudE2ECloudCleanup(config: config).validateSafety()
        addTeardownBlock {
            try CloudE2ECloudCleanup(config: config).deleteCreatedServerIfNeeded()
        }
    }

    private func launchApp(config: CloudE2EConfiguration, autofillCloudServer: Bool) {
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-test-defaults"]

        var launchEnvironment: [String: String] = [:]
        launchEnvironment["MOBILECODE_E2E_AUTOFILL_CLOUD_SERVER"] = autofillCloudServer ? "1" : "0"
        launchEnvironment["MOBILECODE_E2E_AUTODISMISS_SSH_KEY_GENERATION"] = autofillCloudServer ? "1" : "0"
        launchEnvironment["MOBILECODE_E2E_PROVISIONING_DEBUG_LOG"] = "1"
        launchEnvironment["MOBILECODE_E2E_SERVER_NAME"] = config.serverName
        launchEnvironment["MOBILECODE_E2E_SSH_KEY_NAME"] = config.sshKeyName
        if let sshPublicKey = config.sshPublicKey,
           let sshPrivateKeyBase64 = config.sshPrivateKeyBase64 {
            launchEnvironment["MOBILECODE_E2E_AUTOUSE_HOST_SSH_KEY"] = "1"
            launchEnvironment["MOBILECODE_E2E_SSH_PUBLIC_KEY"] = sshPublicKey
            launchEnvironment["MOBILECODE_E2E_SSH_PRIVATE_KEY_B64"] = sshPrivateKeyBase64
        }
        if let region = config.region {
            launchEnvironment["MOBILECODE_E2E_REGION"] = region
        }
        if let size = config.size {
            launchEnvironment["MOBILECODE_E2E_SIZE"] = size
        }
        if config.shouldConfigureAIProvider {
            launchEnvironment["MOBILECODE_E2E_AUTOFILL_AI_API_KEY"] = "1"
            launchEnvironment["MOBILECODE_E2E_AI_PROVIDER_ID"] = config.aiProviderID
            if let modelID = config.aiModelID {
                launchEnvironment["MOBILECODE_E2E_AI_MODEL_ID"] = modelID
            }
            if let smallModelID = config.aiSmallModelID {
                launchEnvironment["MOBILECODE_E2E_AI_SMALL_MODEL_ID"] = smallModelID
            }
        }
        app.launchEnvironment = launchEnvironment
        app.launch()
    }

    private func addCloudProvider(_ config: CloudE2EConfiguration) throws {
        let addProviderButton = app.buttons["settings-add-cloud-provider-button"].firstMatch
        XCTAssertTrue(addProviderButton.waitForExistence(timeout: 10))
        addProviderButton.tap()

        XCTAssertTrue(app.navigationBars["Add Cloud Provider"].waitForExistence(timeout: 10))

        let providerSelector = app.descendants(matching: .any)["cloud-provider-select-\(config.provider.rawValue)"].firstMatch
        if providerSelector.waitForExistence(timeout: 10) {
            providerSelector.tap()
        } else if config.provider != .digitalocean {
            XCTFail("Provider selector for \(config.provider.rawValue) did not appear.")
        }

        let continueButton = app.buttons["cloud-provider-selection-continue-button"].firstMatch
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()

        let nameField = app.textFields["cloud-provider-display-name-field"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        replaceText(in: nameField, with: config.providerName)

        let tokenField = app.secureTextFields["cloud-provider-api-token-field"].firstMatch
        XCTAssertTrue(tokenField.waitForExistence(timeout: 10))
        replaceText(in: tokenField, with: config.apiToken, preferPasteboard: true)

        let connectButton = app.buttons["cloud-provider-connect-button"].firstMatch
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10))
        XCTAssertTrue(connectButton.isEnabled)
        connectButton.tap()

        let addProviderNavigationBar = app.navigationBars["Add Cloud Provider"].firstMatch
        if !addProviderNavigationBar.waitForNonExistence(timeout: 45) {
            failIfErrorAlertVisible()
            XCTFail("Timed out waiting for Add Cloud Provider to dismiss.")
        }
        if !connectButton.waitForNonExistence(timeout: 5) {
            failIfErrorAlertVisible()
        }

        if !app.navigationBars["Settings"].waitForExistence(timeout: 10) {
            failIfErrorAlertVisible()
            XCTFail("Timed out waiting for cloud provider validation to return to Settings.")
        }
    }

    private func openCreateCloudServerFlow(_ config: CloudE2EConfiguration) throws {
        let addServerButton = app.buttons["settings-add-server-button"].firstMatch
        XCTAssertTrue(addServerButton.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        tapElement(addServerButton)

        let addServerNavigationBar = app.navigationBars["Add Server"].firstMatch
        if !addServerNavigationBar.waitForExistence(timeout: 5) {
            tapElement(addServerButton)
        }
        XCTAssertTrue(addServerNavigationBar.waitForExistence(timeout: 10))

        let providerCard = app.descendants(matching: .any)["managed-provider-\(config.providerName.accessibilityIdentifierFragment)"].firstMatch
        XCTAssertTrue(providerCard.waitForExistence(timeout: 20))
        tapElement(providerCard)

        let nextButton = app.buttons["managed-provider-next-button"].firstMatch
        XCTAssertTrue(nextButton.waitForExistence(timeout: 10))
        XCTAssertTrue(nextButton.isEnabled)
        nextButton.tap()

        let createButton = app.buttons["managed-create-cloud-server-button"].firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !createButton.exists && Date() < deadline {
            failIfErrorAlertVisible()
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(createButton.exists, "Create New Server button did not appear for the selected provider.")
        createButton.tap()

        XCTAssertTrue(app.navigationBars["Create Server"].waitForExistence(timeout: 20))

        let nameField = app.textFields["cloud-server-name-field"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 90), "Create Server form did not finish loading options.")
        XCTAssertEqual(nameField.value as? String, config.serverName)
    }

    private func generateAndSelectSSHKey(_ config: CloudE2EConfiguration) throws {
        if config.usesPreseededSSHKey {
            let keyRow = app.descendants(matching: .any)["cloud-server-ssh-key-\(config.sshKeyName.accessibilityIdentifierFragment)"].firstMatch
            XCTAssertTrue(keyRow.waitForExistence(timeout: 20), "Preseeded SSH key did not appear in the create-server form.")
            return
        }

        let generateButton = app.buttons["cloud-server-generate-key-button"].firstMatch
        XCTAssertTrue(generateButton.waitForExistence(timeout: 10))
        generateButton.tap()

        let keyNameField = app.textFields["ssh-key-name-field"].firstMatch
        XCTAssertTrue(keyNameField.waitForExistence(timeout: 10))
        replaceText(in: keyNameField, with: config.sshKeyName)

        let keyGenerateButton = app.buttons["ssh-key-generate-button"].firstMatch
        XCTAssertTrue(keyGenerateButton.waitForExistence(timeout: 10))
        XCTAssertTrue(keyGenerateButton.isEnabled)
        keyGenerateButton.tap()

        let keyRow = app.descendants(matching: .any)["cloud-server-ssh-key-\(config.sshKeyName.accessibilityIdentifierFragment)"].firstMatch
        let stableDoneAction = app.descendants(matching: .any)["ssh-key-generation-done-button"].firstMatch
        let fallbackDoneAction = app.descendants(matching: .any)["Done"].firstMatch
        let generationDeadline = Date().addingTimeInterval(60)
        while !keyRow.exists && !stableDoneAction.exists && !fallbackDoneAction.exists && Date() < generationDeadline {
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        if stableDoneAction.exists || fallbackDoneAction.exists {
            tapElement(stableDoneAction.exists ? stableDoneAction : fallbackDoneAction)
        }

        let keySelectionDeadline = Date().addingTimeInterval(20)
        while !keyRow.exists && Date() < keySelectionDeadline {
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(keyRow.exists, "Generated SSH key did not appear in the create-server form.")
        keyRow.tap()
    }

    private func waitForProvisioningToReachActionableState(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let skipButton = app.buttons["cloud-server-skip-button"].firstMatch
        let retryButton = app.buttons["cloud-server-retry-runtime-button"].firstMatch

        while Date() < deadline {
            if skipButton.exists || retryButton.exists {
                return
            }
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(5))
        }

        XCTFail("Cloud provisioning did not reach success or runtime-retry state within \(Int(timeout)) seconds.")
    }

    private func waitForProvisioningToReachSuccess(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let addAgentButton = app.buttons["cloud-server-add-agent-button"].firstMatch
        let retryButton = app.buttons["cloud-server-retry-runtime-button"].firstMatch

        while Date() < deadline {
            if addAgentButton.exists {
                return
            }
            if retryButton.exists {
                XCTFail("OpenCode runtime setup reached retry state before AI provider setup could run.")
                return
            }
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(5))
        }

        XCTFail("Cloud provisioning did not reach the Add Agent success state within \(Int(timeout)) seconds.")
    }

    private func createAgentAfterProvisioning(_ config: CloudE2EConfiguration) throws {
        let addAgentButton = app.buttons["cloud-server-add-agent-button"].firstMatch
        XCTAssertTrue(addAgentButton.waitForExistence(timeout: 10))
        addAgentButton.tap()

        XCTAssertTrue(app.navigationBars["New Agent"].waitForExistence(timeout: 20))

        let nameField = app.textFields["add-agent-display-name-field"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        replaceText(in: nameField, with: config.agentName)

        let createButton = app.buttons["add-agent-create-button"].firstMatch
        let deadline = Date().addingTimeInterval(120)
        while !createButton.isEnabled && Date() < deadline {
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        XCTAssertTrue(createButton.isEnabled, "Add Agent create button stayed disabled.")
        createButton.tap()

        XCTAssertTrue(
            waitForSettingsOrActiveProjectTabs(timeout: 120),
            "App did not return to Settings or switch to the active-project tabs after creating the agent."
        )
    }

    private func saveOpenCodeAIProviderKey(_ config: CloudE2EConfiguration) throws {
        guard let aiAPIKey = config.aiAPIKey else { return }

        try openAgentRuntimeSettings()

        if config.aiModelID != nil || config.aiSmallModelID != nil {
            let modelSaveButton = app.buttons["opencode-save-model-selection-button"].firstMatch
            XCTAssertTrue(scrollToElement(modelSaveButton, timeout: 60))
            if modelSaveButton.isEnabled {
                modelSaveButton.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                failIfErrorAlertVisible()
            }
        }

        let apiKeyField = app.secureTextFields["opencode-api-key-field"].firstMatch
        XCTAssertTrue(
            scrollToElement(apiKeyField, timeout: 120),
            "OpenCode API key field did not appear."
        )

        let providerField = app.textFields["opencode-api-provider-field"].firstMatch
        if providerField.exists {
            replaceText(in: providerField, with: config.aiProviderID)
        }

        let saveButton = app.buttons["opencode-save-provider-connection-button"].firstMatch
        XCTAssertTrue(scrollToElement(saveButton, timeout: 20))
        if !saveButton.isEnabled {
            XCTAssertTrue(scrollToElement(apiKeyField, timeout: 20, direction: .down))
            replaceText(in: apiKeyField, with: aiAPIKey, preferPasteboard: true)
            dismissKeyboardIfNeeded()
            if !saveButton.isHittable {
                _ = scrollToElement(saveButton, timeout: 10)
            }
        }

        XCTAssertTrue(saveButton.isEnabled, "OpenCode AI API key save button stayed disabled.")
        tapPossiblyCoveredElement(saveButton)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        failIfErrorAlertVisible()
        closeAgentRuntimeSettingsIfNeeded()
    }

    private func openAgentRuntimeSettings() throws {
        let chatTab = app.tabBars.buttons["Chat"].firstMatch
        XCTAssertTrue(chatTab.waitForExistence(timeout: 30), "Could not find Settings runtime link or Chat tab.")
        chatTab.tap()

        let menuButton = app.buttons["chat-more-menu-button"].firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 20), "Chat menu button did not appear.")
        menuButton.tap()

        let runtimeButton = app.descendants(matching: .any)["chat-agent-runtime-settings-button"].firstMatch
        XCTAssertTrue(runtimeButton.waitForExistence(timeout: 10), "Agent Runtime menu item did not appear.")
        tapElement(runtimeButton)

        XCTAssertTrue(app.navigationBars["Agent Runtime"].waitForExistence(timeout: 20))
    }

    private func startChat(_ config: CloudE2EConfiguration) throws {
        closeAgentRuntimeSettingsIfNeeded()

        let chatTab = app.tabBars.buttons["Chat"].firstMatch
        if !chatTab.waitForExistence(timeout: 20) {
            dismissPresentedSheetIfNeeded()
        }

        XCTAssertTrue(chatTab.waitForExistence(timeout: 60), "Chat tab did not appear after creating \(config.agentName).")
        chatTab.tap()

        let authRequired = app.staticTexts["OpenCode Auth Required"].firstMatch
        if authRequired.waitForExistence(timeout: 5) {
            XCTFail("OpenCode requested server auth after managed provisioning. The generated OpenCode password was not available to chat.")
        }

        let input = app.descendants(matching: .any)["chat-composer-input"].firstMatch
        let inputDeadline = Date().addingTimeInterval(120)
        while !input.exists && Date() < inputDeadline {
            if authRequired.exists {
                XCTFail("OpenCode requested server auth before chat input became available.")
                return
            }
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        if !input.exists {
            XCTFail("Chat composer did not become available. UI hierarchy:\n\(app.debugDescription)")
            return
        }

        let prompt = "Reply with one short sentence confirming this MobileCode E2E chat works."
        replaceText(in: input, with: prompt, preferPasteboard: true)

        let sendButton = app.buttons["chat-composer-send-button"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        XCTAssertTrue(sendButton.isEnabled, "Chat send button stayed disabled after entering text.")
        sendButton.tap()

        let userMessage = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-message-user-"))
            .firstMatch
        XCTAssertTrue(userMessage.waitForExistence(timeout: 30), "Sent chat message did not render.")

        let assistantMessage = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-message-assistant-"))
            .firstMatch
        let responseDeadline = Date().addingTimeInterval(240)
        while !assistantMessage.exists && Date() < responseDeadline {
            if authRequired.exists {
                XCTFail("OpenCode requested server auth while waiting for the chat response.")
                return
            }
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
        }
        XCTAssertTrue(assistantMessage.exists, "OpenCode chat did not render an assistant response.")
    }

    private func verifyOpenCodeMCPAndSkillsSettings() throws {
        let chatTab = app.tabBars.buttons["Chat"].firstMatch
        XCTAssertTrue(chatTab.waitForExistence(timeout: 20))
        chatTab.tap()

        let menuButton = app.buttons["chat-more-menu-button"].firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 20))
        menuButton.tap()

        let mcpButton = app.descendants(matching: .any)["chat-mcp-servers-button"].firstMatch
        XCTAssertTrue(mcpButton.waitForExistence(timeout: 10), "MCP menu item did not appear for OpenCode chat.")
        tapElement(mcpButton)

        XCTAssertTrue(app.navigationBars["MCP Servers"].waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.buttons["mcp-add-server-button"].waitForExistence(timeout: 20)
                || app.buttons["mcp-add-server-empty-button"].waitForExistence(timeout: 20)
                || app.descendants(matching: .any)["mcp-server-row-codeagents-scheduled-tasks"].waitForExistence(timeout: 20),
            "OpenCode MCP settings did not load an actionable state."
        )
        dismissPresentedSheetIfNeeded()

        XCTAssertTrue(chatTab.waitForExistence(timeout: 20))
        chatTab.tap()
        XCTAssertTrue(menuButton.waitForExistence(timeout: 20))
        menuButton.tap()

        let skillsButton = app.descendants(matching: .any)["chat-agent-skills-button"].firstMatch
        XCTAssertTrue(skillsButton.waitForExistence(timeout: 10), "Agent Skills menu item did not appear for OpenCode chat.")
        tapElement(skillsButton)

        XCTAssertTrue(app.navigationBars["Agent Skills"].waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.buttons["agent-skills-picker-add-menu-button"].waitForExistence(timeout: 10)
                || app.buttons["agent-skills-browse-marketplaces-button"].waitForExistence(timeout: 10),
            "OpenCode agent skills settings did not show install/add controls."
        )
        dismissPresentedSheetIfNeeded()
    }

    private func verifyRegularTaskEditorUX() throws {
        let tasksTab = app.tabBars.buttons["Regular Tasks"].firstMatch
        XCTAssertTrue(tasksTab.waitForExistence(timeout: 30))
        tasksTab.tap()

        XCTAssertTrue(app.navigationBars["Regular Tasks"].waitForExistence(timeout: 20))
        let addButton = app.buttons["regular-tasks-add-button"].firstMatch
        let emptyAddButton = app.buttons["regular-tasks-add-empty-button"].firstMatch
        XCTAssertTrue(
            addButton.waitForExistence(timeout: 20) || emptyAddButton.waitForExistence(timeout: 20),
            "Regular Tasks add control did not appear for OpenCode agent."
        )
        tapElement(addButton.exists ? addButton : emptyAddButton)

        XCTAssertTrue(app.navigationBars["New Task"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.textFields["regular-task-title-field"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["regular-task-prompt-field"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["regular-task-frequency-picker"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["regular-task-save-button"].waitForExistence(timeout: 10))
        dismissPresentedSheetIfNeeded()
    }

    private func closeAgentRuntimeSettingsIfNeeded() {
        let runtimeNavigationBar = app.navigationBars["Agent Runtime"].firstMatch
        guard runtimeNavigationBar.exists else { return }

        let doneButton = app.buttons["agent-runtime-done-button"].firstMatch
        if doneButton.exists {
            doneButton.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            return
        }

        for _ in 0..<3 where runtimeNavigationBar.exists {
            app.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    private func dismissPresentedSheetIfNeeded() {
        for _ in 0..<3 where !app.tabBars.buttons["Chat"].firstMatch.exists {
            app.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    private func waitForSettingsOrActiveProjectTabs(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let settingsNavigationBar = app.navigationBars["Settings"].firstMatch
        let chatTab = app.tabBars.buttons["Chat"].firstMatch

        while Date() < deadline {
            if settingsNavigationBar.exists || chatTab.exists {
                return true
            }
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        return settingsNavigationBar.exists || chatTab.exists
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

    private func replaceText(in element: XCUIElement, with text: String, preferPasteboard: Bool = false) {
        element.tap()
        if let current = element.value as? String,
           !current.isEmpty,
           current != element.placeholderValue {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }

        if preferPasteboard {
            UIPasteboard.general.string = text
            element.press(forDuration: 1.0)
            let pasteMenuItem = app.menuItems["Paste"].firstMatch
            if pasteMenuItem.waitForExistence(timeout: 2) {
                pasteMenuItem.tap()
                return
            }
        }

        element.typeText(text)
    }

    private func tapElement(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func dismissKeyboardIfNeeded() {
        guard app.keyboards.firstMatch.exists else { return }

        let doneButton = app.keyboards.buttons["Done"].firstMatch
        if doneButton.exists {
            doneButton.tap()
        } else if app.keyboards.keys["return"].firstMatch.exists {
            app.keyboards.keys["return"].firstMatch.tap()
        } else if app.keyboards.buttons["Return"].firstMatch.exists {
            app.keyboards.buttons["Return"].firstMatch.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        }

        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    private func tapPossiblyCoveredElement(_ element: XCUIElement) {
        if !element.isHittable {
            dismissKeyboardIfNeeded()
            _ = scrollToElement(element, timeout: 10)
        }

        if element.isHittable {
            element.tap()
        } else {
            tapElement(element)
        }
    }

    private func scrollToElement(
        _ element: XCUIElement,
        timeout: TimeInterval,
        direction: ScrollDirection = .up
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable {
                return true
            }
            failIfErrorAlertVisible()
            switch direction {
            case .up:
                app.swipeUp()
            case .down:
                app.swipeDown()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return element.exists && element.isHittable
    }

    private func failIfErrorAlertVisible() {
        let alert = app.alerts.firstMatch
        guard alert.exists else { return }
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTFail("Unexpected alert during cloud E2E run: \(message)")
    }

    private enum RootUI {
        case tabs
        case agents
    }

    private enum ScrollDirection {
        case up
        case down
    }
}

private struct CloudE2EConfiguration {
    enum Provider: String {
        case digitalocean
        case hetzner
    }

    let provider: Provider
    let apiToken: String
    let providerName: String
    let serverNamePrefix: String
    let serverName: String
    let sshKeyName: String
    let agentName: String
    let region: String?
    let size: String?
    let provisioningTimeout: TimeInterval
    let aiProviderID: String
    let aiAPIKey: String?
    let aiModelID: String?
    let aiSmallModelID: String?
    let sshPublicKey: String?
    let sshPrivateKeyBase64: String?
    let deleteCreatedServers: Bool

    var shouldConfigureAIProvider: Bool {
        aiAPIKey?.isEmpty == false
    }

    var usesPreseededSSHKey: Bool {
        sshPublicKey?.isEmpty == false && sshPrivateKeyBase64?.isEmpty == false
    }

    static func load(requireMutation: Bool) throws -> CloudE2EConfiguration {
        let environment = mergedEnvironment()
        guard let provider = Provider(rawValue: environment["MOBILECODE_E2E_PROVIDER"] ?? "") else {
            throw XCTSkip("Set MOBILECODE_E2E_PROVIDER to digitalocean or hetzner to run cloud E2E tests.")
        }
        guard let token = environment["MOBILECODE_E2E_CLOUD_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Set MOBILECODE_E2E_CLOUD_TOKEN to run cloud E2E tests.")
        }
        if requireMutation && environment["MOBILECODE_E2E_ALLOW_CLOUD_MUTATION"] != "1" {
            throw XCTSkip("Set MOBILECODE_E2E_ALLOW_CLOUD_MUTATION=1 to run create/delete cloud E2E tests.")
        }

        let runID = environment["MOBILECODE_E2E_RUN_ID"] ?? UUID().uuidString.prefix(8).lowercased()
        let providerName = environment["MOBILECODE_E2E_PROVIDER_NAME"] ?? "MobileCode E2E \(provider.displayName) \(runID)"
        let prefix = environment["MOBILECODE_E2E_SERVER_NAME_PREFIX"] ?? "mobilecode-e2e"
        let serverName = environment["MOBILECODE_E2E_SERVER_NAME"] ?? "\(prefix)-\(runID)"
        let sshKeyName = environment["MOBILECODE_E2E_SSH_KEY_NAME"] ?? "\(serverName)-key"
        let agentName = environment["MOBILECODE_E2E_AGENT_NAME"] ?? "\(serverName)-agent"
        let timeout = TimeInterval(environment["MOBILECODE_E2E_PROVISIONING_TIMEOUT_SECONDS"] ?? "") ?? 1_800

        let aiProviderID = environment["MOBILECODE_E2E_AI_PROVIDER_ID"] ?? "minimax"
        let aiAPIKey = nonEmpty(environment["MOBILECODE_E2E_AI_API_KEY"])
        let shouldDefaultMiniMaxModel = aiAPIKey != nil && aiProviderID.caseInsensitiveCompare("minimax") == .orderedSame
        let defaultMiniMaxModelID = "minimax/MiniMax-M2.7"

        return CloudE2EConfiguration(
            provider: provider,
            apiToken: token,
            providerName: providerName,
            serverNamePrefix: prefix,
            serverName: serverName,
            sshKeyName: sshKeyName,
            agentName: agentName,
            region: environment["MOBILECODE_E2E_REGION"],
            size: environment["MOBILECODE_E2E_SIZE"],
            provisioningTimeout: timeout,
            aiProviderID: aiProviderID,
            aiAPIKey: aiAPIKey,
            aiModelID: nonEmpty(environment["MOBILECODE_E2E_AI_MODEL_ID"]) ?? (shouldDefaultMiniMaxModel ? defaultMiniMaxModelID : nil),
            aiSmallModelID: nonEmpty(environment["MOBILECODE_E2E_AI_SMALL_MODEL_ID"]) ?? (shouldDefaultMiniMaxModel ? defaultMiniMaxModelID : nil),
            sshPublicKey: nonEmpty(environment["MOBILECODE_E2E_SSH_PUBLIC_KEY"]),
            sshPrivateKeyBase64: nonEmpty(environment["MOBILECODE_E2E_SSH_PRIVATE_KEY_B64"]),
            deleteCreatedServers: environment["MOBILECODE_E2E_DELETE_CREATED_SERVERS"] != "0"
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        for path in candidateEnvFilePaths(environment: environment) {
            guard let fileEnvironment = parseEnvFile(at: path) else { continue }
            for (key, value) in fileEnvironment where environment[key] == nil {
                environment[key] = value
            }
        }

        return environment
    }

    private static func candidateEnvFilePaths(environment: [String: String]) -> [String] {
        var paths: [String] = []
        if let explicitPath = nonEmpty(environment["MOBILECODE_E2E_ENV_FILE"]) {
            paths.append(explicitPath)
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        paths.append("\(repoRoot)/scripts/e2e/.mobilecode-e2e.generated.env")
        paths.append("\(repoRoot)/scripts/e2e/mobilecode-e2e.env")
        paths.append("\(repoRoot)/.mobilecode-e2e.env")
        paths.append("\(NSHomeDirectory())/.mobilecode-e2e.env")

        return paths
    }

    private static func parseEnvFile(at path: String) -> [String: String]? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        return contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(into: [String: String]()) { result, rawLine in
                var line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { return }

                if line.hasPrefix("export ") {
                    line.removeFirst("export ".count)
                    line = line.trimmingCharacters(in: .whitespaces)
                }

                guard let separator = line.firstIndex(of: "=") else { return }
                let key = line[..<separator].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return }

                let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                result[key] = unquoteEnvValue(rawValue)
            }
    }

    private static func unquoteEnvValue(_ value: String) -> String {
        guard value.count >= 2 else { return value }

        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }

        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }

        let commentPattern = #"\s+#"#
        if let range = value.range(of: commentPattern, options: .regularExpression) {
            return value[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        }

        return value
    }
}

private struct CloudE2ECloudCleanup {
    let config: CloudE2EConfiguration

    func validateSafety() throws {
        guard config.deleteCreatedServers else { return }
        guard config.serverNamePrefix.count >= 8,
              config.serverNamePrefix.localizedCaseInsensitiveContains("e2e"),
              config.serverName.hasPrefix(config.serverNamePrefix) else {
            throw CleanupError.unsafeServerName(prefix: config.serverNamePrefix, serverName: config.serverName)
        }
    }

    func deleteCreatedServerIfNeeded() throws {
        guard config.deleteCreatedServers else {
            print("Skipping exact cloud server cleanup because MOBILECODE_E2E_DELETE_CREATED_SERVERS is 0.")
            return
        }

        try validateSafety()
        let servers = try listServers()
        let matches = servers.filter { $0.name == config.serverName }

        guard !matches.isEmpty else {
            print("No cloud server matched exact cleanup name '\(config.serverName)'.")
            return
        }

        for server in matches {
            try deleteServer(id: server.id)
            print("Deleted \(config.provider.rawValue) server \(server.name) (\(server.id)) during UI-test teardown.")
        }
    }

    private func listServers() throws -> [RemoteServer] {
        switch config.provider {
        case .digitalocean:
            return try listDigitalOceanServers()
        case .hetzner:
            return try listHetznerServers()
        }
    }

    private func deleteServer(id: String) throws {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url: URL
        switch config.provider {
        case .digitalocean:
            url = URL(string: "https://api.digitalocean.com/v2/droplets/\(encodedID)")!
        case .hetzner:
            url = URL(string: "https://api.hetzner.cloud/v1/servers/\(encodedID)")!
        }

        let response = try request(method: "DELETE", url: url)
        guard response.statusCode == 404 || (200..<300).contains(response.statusCode) else {
            throw CleanupError.httpError(statusCode: response.statusCode, body: response.body)
        }
    }

    private func listDigitalOceanServers() throws -> [RemoteServer] {
        var servers: [RemoteServer] = []
        var nextURL = URL(string: "https://api.digitalocean.com/v2/droplets?per_page=200")!

        while true {
            let response = try request(method: "GET", url: nextURL)
            guard (200..<300).contains(response.statusCode) else {
                throw CleanupError.httpError(statusCode: response.statusCode, body: response.body)
            }
            guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw CleanupError.invalidResponse
            }

            if let droplets = payload["droplets"] as? [[String: Any]] {
                servers.append(contentsOf: droplets.compactMap { droplet in
                    guard let id = droplet["id"], let name = droplet["name"] as? String else { return nil }
                    return RemoteServer(id: String(describing: id), name: name)
                })
            }

            guard let links = payload["links"] as? [String: Any],
                  let pages = links["pages"] as? [String: Any],
                  let next = pages["next"] as? String,
                  let url = URL(string: next) else {
                break
            }
            nextURL = url
        }

        return servers
    }

    private func listHetznerServers() throws -> [RemoteServer] {
        var servers: [RemoteServer] = []
        var page = 1

        while true {
            let url = URL(string: "https://api.hetzner.cloud/v1/servers?per_page=50&page=\(page)")!
            let response = try request(method: "GET", url: url)
            guard (200..<300).contains(response.statusCode) else {
                throw CleanupError.httpError(statusCode: response.statusCode, body: response.body)
            }
            guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw CleanupError.invalidResponse
            }

            if let remoteServers = payload["servers"] as? [[String: Any]] {
                servers.append(contentsOf: remoteServers.compactMap { server in
                    guard let id = server["id"], let name = server["name"] as? String else { return nil }
                    return RemoteServer(id: String(describing: id), name: name)
                })
            }

            guard let meta = payload["meta"] as? [String: Any],
                  let pagination = meta["pagination"] as? [String: Any],
                  let nextPage = pagination["next_page"],
                  !(nextPage is NSNull) else {
                break
            }

            if let nextPageNumber = nextPage as? Int {
                page = nextPageNumber
            } else if let nextPageNumber = nextPage as? String, let parsed = Int(nextPageNumber) {
                page = parsed
            } else {
                break
            }
        }

        return servers
    }

    private func request(method: String, url: URL) throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(config.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<HTTPResult, Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                result = .failure(error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(CleanupError.invalidResponse)
                return
            }

            let bodyData = data ?? Data()
            let body = String(data: bodyData, encoding: .utf8) ?? ""
            result = .success(HTTPResult(statusCode: httpResponse.statusCode, data: bodyData, body: body))
        }.resume()

        guard semaphore.wait(timeout: .now() + 60) == .success else {
            throw CleanupError.timeout(url.absoluteString)
        }

        guard let result else {
            throw CleanupError.invalidResponse
        }
        return try result.get()
    }

    private struct HTTPResult {
        let statusCode: Int
        let data: Data
        let body: String
    }

    private struct RemoteServer {
        let id: String
        let name: String
    }

    private enum CleanupError: LocalizedError {
        case unsafeServerName(prefix: String, serverName: String)
        case httpError(statusCode: Int, body: String)
        case invalidResponse
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .unsafeServerName(let prefix, let serverName):
                return "Refusing cloud cleanup for unsafe prefix '\(prefix)' and server name '\(serverName)'."
            case .httpError(let statusCode, let body):
                return "Cloud cleanup request failed with HTTP \(statusCode): \(body)"
            case .invalidResponse:
                return "Cloud cleanup received an invalid response."
            case .timeout(let url):
                return "Cloud cleanup timed out calling \(url)."
            }
        }
    }
}

private extension CloudE2EConfiguration.Provider {
    var displayName: String {
        switch self {
        case .digitalocean:
            return "DigitalOcean"
        case .hetzner:
            return "Hetzner"
        }
    }
}

private extension String {
    var accessibilityIdentifierFragment: String {
        let allowed = CharacterSet.alphanumerics
        let scalars = unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar).lowercased()) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "unnamed" : collapsed
    }
}
