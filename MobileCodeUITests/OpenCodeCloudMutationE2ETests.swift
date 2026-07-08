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
            try createAndVerifyMinutelyScheduledTaskOnRealInstance(config)
        } else {
            try waitForProvisioningToReachActionableState(timeout: config.provisioningTimeout)

            let skipButton = app.buttons["cloud-server-skip-button"].firstMatch
            XCTAssertTrue(skipButton.waitForExistence(timeout: 10))
            skipButton.tap()
        }
    }

    private func registerCloudServerCleanup(_ config: CloudE2EConfiguration) throws {
        try CloudE2ECloudCleanup(config: config).validateSafety()
        // Always attempt cloud deletion on teardown, including when the test assertion fails.
        // Errors are logged, not rethrown, so a teardown failure cannot skip cleanup entirely
        // and the shell runner still post-cleans by prefix as a second line of defense.
        addTeardownBlock {
            do {
                try CloudE2ECloudCleanup(config: config).deleteCreatedResourcesBestEffort()
            } catch {
                print("UI-test cloud teardown cleanup error (ignored): \(error.localizedDescription)")
            }
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
        launchEnvironment["MOBILECODE_E2E_PROVIDER"] = config.provider.rawValue
        launchEnvironment["MOBILECODE_E2E_PROVIDER_NAME"] = config.providerName
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
        if config.shouldConfigureAIProvider, let aiAPIKey = config.aiAPIKey {
            launchEnvironment["MOBILECODE_E2E_AUTOFILL_AI_API_KEY"] = "1"
            launchEnvironment["MOBILECODE_E2E_AI_PROVIDER_ID"] = config.aiProviderID
            // Must be passed into the app process — AUTOFILL alone is not enough.
            launchEnvironment["MOBILECODE_E2E_AI_API_KEY"] = aiAPIKey
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
        // Drive the real form only (no app-side MOBILECODE_E2E_* injection).
        replaceText(in: nameField, with: config.providerName, preferPasteboard: false)

        // Type the token into SecureField via XCTest. Do not use Paste Token / UIPasteboard —
        // app-side pasteboard access triggers iOS paste privacy and hangs accessibility queries.
        let tokenField = app.secureTextFields["cloud-provider-api-token-field"].firstMatch
        XCTAssertTrue(
            tokenField.waitForExistence(timeout: 10)
                || app.descendants(matching: .any)["cloud-provider-api-token-field"].firstMatch.waitForExistence(timeout: 5),
            "Cloud provider API token field missing."
        )
        let secureField = tokenField.exists
            ? tokenField
            : app.descendants(matching: .any)["cloud-provider-api-token-field"].firstMatch
        typeSecureToken(into: secureField, token: config.apiToken)

        let connectButton = app.buttons["cloud-provider-connect-button"].firstMatch
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10))
        let connectDeadline = Date().addingTimeInterval(8)
        while !connectButton.isEnabled && Date() < connectDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(connectButton.isEnabled, "Connect stayed disabled after entering cloud token.")
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
        // Settle Settings after Connect — residual keyboard/focus can swallow the next tap.
        // If Add Server still will not present, dismiss Settings and re-open from Agents.
        let addServerNavigationBar = app.navigationBars["Add Server"].firstMatch
        var opened = false
        for reopen in 0..<2 {
            let settingsBar = app.navigationBars["Settings"].firstMatch
            if !settingsBar.waitForExistence(timeout: 5) {
                try openSettingsFromAgentsScreen()
            }
            XCTAssertTrue(settingsBar.waitForExistence(timeout: 10))
            dismissKeyboardIfNeeded()
            // Tap nav bar title area to resign first responder without relying on hit testing.
            let navCenter = settingsBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            navCenter.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            dismissKeyboardIfNeeded()
            app.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))

            let addServerButton = app.buttons["settings-add-server-button"].firstMatch
            XCTAssertTrue(
                addServerButton.waitForExistence(timeout: 20),
                "Settings Add Server control did not appear after connecting cloud provider."
            )

            for _ in 0..<3 {
                // Prefer a normal tap only when hittable; otherwise force coordinate tap.
                if addServerButton.isHittable {
                    addServerButton.tap()
                } else {
                    tapElement(addServerButton)
                }
                // Sheet may use "Add Server" title or expose the type picker first.
                if addServerNavigationBar.waitForExistence(timeout: 4)
                    || app.descendants(matching: .any)["add-server-type-picker"].waitForExistence(timeout: 2)
                    || (app.buttons["Cancel"].waitForExistence(timeout: 2)
                        && app.staticTexts["Auto"].waitForExistence(timeout: 1)) {
                    opened = true
                    break
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            if opened { break }

            // Re-open Settings from Agents and try again (clears stuck focus / half-dismissed sheets).
            if reopen == 0 {
                let dismissSettings = app.navigationBars["Settings"].buttons.firstMatch
                if dismissSettings.exists { dismissSettings.tap() }
                else if app.buttons["Done"].exists { app.buttons["Done"].tap() }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                try openSettingsFromAgentsScreen()
            }
        }
        XCTAssertTrue(opened, "Add Server sheet did not present after tapping settings-add-server-button.")

        let expectedProviderId = "managed-provider-\(config.providerName.accessibilityIdentifierFragment)"
        let providerCard = app.descendants(matching: .any)[expectedProviderId].firstMatch
        if !providerCard.waitForExistence(timeout: 10) {
            // Fall back to any DigitalOcean managed provider card if name seeding raced.
            let anyDOCard = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "managed-provider-"))
                .firstMatch
            XCTAssertTrue(
                anyDOCard.waitForExistence(timeout: 15),
                "No managed provider card found (expected \(expectedProviderId))."
            )
            tapElement(anyDOCard)
        } else {
            tapElement(providerCard)
        }

        let nextButton = app.buttons["managed-provider-next-button"].firstMatch
        XCTAssertTrue(nextButton.waitForExistence(timeout: 10))
        XCTAssertTrue(nextButton.isEnabled)
        nextButton.tap()

        // Prefer the always-visible toolbar Create control (real product affordance).
        let toolbarCreate = app.navigationBars.buttons["managed-create-cloud-server-button"].firstMatch
        let deadline = Date().addingTimeInterval(60)
        while !toolbarCreate.exists && Date() < deadline {
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(toolbarCreate.waitForExistence(timeout: 5), "Create Server toolbar button missing for '\(config.providerName)'.")
        toolbarCreate.tap()

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
        var lastRetryTap = Date.distantPast

        while Date() < deadline {
            if addAgentButton.exists {
                return
            }
            // Cloud-init / OpenCode install can stall on first pass; retry rather than failing fast.
            if retryButton.exists, Date().timeIntervalSince(lastRetryTap) >= 30 {
                if retryButton.isHittable {
                    retryButton.tap()
                } else {
                    tapElement(retryButton)
                }
                lastRetryTap = Date()
            }
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(5))
        }

        XCTFail("Cloud provisioning did not reach the Add Agent success state within \(Int(timeout)) seconds.")
    }

    private func createAgentAfterProvisioning(_ config: CloudE2EConfiguration) throws {
        let addAgentButton = app.buttons["cloud-server-add-agent-button"].firstMatch
        XCTAssertTrue(addAgentButton.waitForExistence(timeout: 10))
        // Button can sit under a non-hittable overlay right after provisioning succeeds.
        if addAgentButton.isHittable {
            addAgentButton.tap()
        } else {
            tapElement(addAgentButton)
        }

        let nameField = app.textFields["add-agent-display-name-field"].firstMatch
        let newAgentBar = app.navigationBars["New Agent"].firstMatch
        let addAgentBar = app.navigationBars["Add Agent"].firstMatch
        let editorDeadline = Date().addingTimeInterval(25)
        while Date() < editorDeadline {
            if nameField.exists || newAgentBar.exists { break }
            // Retry open if the first tap was swallowed (nav push from Create Server).
            if addAgentButton.exists {
                tapElement(addAgentButton)
            }
            failIfErrorAlertVisible()
            // MissingCreatedServerSheet uses title "Add Agent" — fail clearly if server record vanished.
            if addAgentBar.exists && !nameField.exists {
                XCTFail("Add Agent opened without a server record (MissingCreatedServerSheet).")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(
            nameField.waitForExistence(timeout: 5) || newAgentBar.waitForExistence(timeout: 2),
            "New Agent editor did not present after Add Agent."
        )
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

        // Prefer the OpenCode Connection section on the OpenCode runtime sheet (autofill may already fill key).
        // Fall back to Global provider & models when the connection section is hidden
        // (no active project in the sheet).
        var apiKeyField = app.descendants(matching: .any)["opencode-api-key-field"].firstMatch
        var saveButton = app.buttons["opencode-save-provider-connection-button"].firstMatch

        if !scrollToElement(apiKeyField, timeout: 20) {
            let globalLink = app.descendants(matching: .any)["agent-runtime-ai-providers-global-link"].firstMatch
            let serverLink = app.descendants(matching: .any)["agent-runtime-ai-providers-server-link"].firstMatch
            if serverLink.waitForExistence(timeout: 5) {
                tapElement(serverLink)
            } else {
                XCTAssertTrue(globalLink.waitForExistence(timeout: 10), "No AI provider settings link on OpenCode runtime sheet.")
                tapElement(globalLink)
            }
            apiKeyField = app.descendants(matching: .any)["opencode-ai-api-key-field"].firstMatch
            saveButton = app.buttons["opencode-ai-apply-server-button"].firstMatch
            if !saveButton.waitForExistence(timeout: 5) {
                saveButton = app.buttons["opencode-ai-apply-all-servers-button"].firstMatch
            }
        }

        XCTAssertTrue(
            scrollToElement(apiKeyField, timeout: 60),
            "OpenCode API key field did not appear on OpenCode runtime or AI provider settings."
        )

        // Select provider if the connection picker is present.
        let providerPicker = app.descendants(matching: .any)["opencode-api-provider-picker"].firstMatch
        if providerPicker.exists {
            providerPicker.tap()
            let providerOption = app.buttons[config.aiProviderID].firstMatch
            if providerOption.waitForExistence(timeout: 3) {
                providerOption.tap()
            } else {
                let menuItem = app.menuItems[config.aiProviderID].firstMatch
                if menuItem.waitForExistence(timeout: 2) {
                    menuItem.tap()
                } else {
                    // Picker may already show the selection; dismiss by tapping outside.
                    openCodeRuntimeNavigationBar().tap()
                }
            }
        }

        let providerField = app.textFields["opencode-api-provider-field"].firstMatch
        if providerField.exists {
            replaceText(in: providerField, with: config.aiProviderID)
        }

        // Autofill may have enabled Save already; otherwise enter the key.
        if !saveButton.waitForExistence(timeout: 5) || !saveButton.isEnabled {
            _ = scrollToElement(apiKeyField, timeout: 20, direction: .down)
            replaceText(in: apiKeyField, with: aiAPIKey, preferPasteboard: true)
            dismissKeyboardIfNeeded()
        }

        // Fill model fields when present (connection section).
        if let modelID = config.aiModelID {
            let modelField = app.descendants(matching: .any)["opencode-connection-model-field"].firstMatch
            if modelField.waitForExistence(timeout: 3) {
                replaceText(in: modelField, with: modelID, preferPasteboard: false)
            }
        }
        if let smallModelID = config.aiSmallModelID {
            let smallField = app.descendants(matching: .any)["opencode-connection-small-model-field"].firstMatch
            if smallField.waitForExistence(timeout: 3) {
                replaceText(in: smallField, with: smallModelID, preferPasteboard: false)
            }
        }

        XCTAssertTrue(scrollToElement(saveButton, timeout: 20), "OpenCode AI save/apply control missing.")
        let enableDeadline = Date().addingTimeInterval(10)
        while !saveButton.isEnabled && Date() < enableDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(saveButton.isEnabled, "OpenCode AI API key save button stayed disabled.")

        // Provider save tunnels OpenCode HTTP over SSH; truncated responses show as alerts.
        // Product retries once with a fresh session — UI test dismisses alerts and re-taps Save.
        var failureCount = 0
        let maxFailures = 3
        var awaitingSaveResult = false
        var lastTap = Date.distantPast
        let overallDeadline = Date().addingTimeInterval(90)
        while Date() < overallDeadline {
            if dismissErrorAlertIfPresent() {
                failureCount += 1
                XCTAssertLessThanOrEqual(failureCount, maxFailures, "OpenCode provider save failed repeatedly.")
                awaitingSaveResult = false
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                let waitEnabled = Date().addingTimeInterval(15)
                while !saveButton.isEnabled && Date() < waitEnabled {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                }
                continue
            }
            if saveButton.isEnabled, !awaitingSaveResult {
                tapPossiblyCoveredElement(saveButton)
                lastTap = Date()
                awaitingSaveResult = true
            }
            // Quiet period with no alert after a save attempt ⇒ success.
            if awaitingSaveResult, Date().timeIntervalSince(lastTap) >= 12 {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        failIfErrorAlertVisible()

        // Pop nested AI provider settings if we navigated there.
        if openCodeRuntimeNavigationBar().waitForExistence(timeout: 2) == false {
            let back = app.navigationBars.buttons.firstMatch
            if back.exists { back.tap() }
        }
        closeAgentRuntimeSettingsIfNeeded()
    }

    /// Navigation title for the OpenCode runtime sheet (formerly "Agent Runtime").
    private func openCodeRuntimeNavigationBar() -> XCUIElement {
        app.navigationBars["OpenCode"].firstMatch
    }

    private func openAgentRuntimeSettings() throws {
        let chatTab = app.tabBars.buttons["Chat"].firstMatch
        XCTAssertTrue(chatTab.waitForExistence(timeout: 30), "Could not find Settings runtime link or Chat tab.")
        chatTab.tap()

        let menuButton = app.buttons["chat-more-menu-button"].firstMatch
        XCTAssertTrue(menuButton.waitForExistence(timeout: 20), "Chat menu button did not appear.")
        menuButton.tap()

        let runtimeButton = app.descendants(matching: .any)["chat-agent-runtime-settings-button"].firstMatch
        XCTAssertTrue(runtimeButton.waitForExistence(timeout: 10), "OpenCode menu item did not appear in chat.")
        tapElement(runtimeButton)

        XCTAssertTrue(openCodeRuntimeNavigationBar().waitForExistence(timeout: 20), "OpenCode runtime sheet did not open.")
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

        let promptMarker = "MobileCode E2E chat works"
        let prompt = "Reply with one short sentence confirming this \(promptMarker)."
        // Prefer typing over pasteboard — cross-process paste is flaky on recent simulators.
        replaceText(in: input, with: prompt, preferPasteboard: false)

        let sendButton = app.buttons["chat-composer-send-button"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        XCTAssertTrue(sendButton.isEnabled, "Chat send button stayed disabled after entering text.")
        let sendStarted = Date()
        sendButton.tap()

        // Exyte Chat may not always surface accessibility identifiers on bubbles; accept either
        // chat-message-user-* or visible prompt text.
        let userMessageById = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-message-user-"))
            .firstMatch
        let userMessageByText = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", promptMarker))
            .firstMatch
        let userDeadline = Date().addingTimeInterval(45)
        while Date() < userDeadline {
            if userMessageById.exists || userMessageByText.exists { break }
            if authRequired.exists {
                XCTFail("OpenCode requested server auth after send.")
                return
            }
            failIfErrorAlertVisible()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(
            userMessageById.exists || userMessageByText.exists,
            "Sent chat message did not render (no chat-message-user-* id or prompt text)."
        )

        let assistantMessageById = app
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-message-assistant-"))
            .firstMatch
        // Streamed labels can appear before Exyte exposes chat-message-assistant-* ids.
        // Prefer the stable id when it arrives; otherwise accept visible assistant text.
        let responseDeadline = Date().addingTimeInterval(240)
        var sawAssistantText = false
        while Date() < responseDeadline {
            if assistantMessageById.exists { break }
            if authRequired.exists {
                XCTFail("OpenCode requested server auth while waiting for the chat response.")
                return
            }
            failIfErrorAlertVisible()
            let streamedAssistantText = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "confirm"))
                .firstMatch
            if streamedAssistantText.exists {
                sawAssistantText = true
                // Keep waiting for the stable id while time remains; text alone is enough to pass.
            }
            if sawAssistantText && assistantMessageById.exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(3))
        }
        if !assistantMessageById.exists && !sawAssistantText {
            let waited = Date().timeIntervalSince(sendStarted)
            print(String(format: "E2E_TIMING first_assistant_response_missing_after_s=%.2f", waited))
            XCTFail("OpenCode chat did not render an assistant response within 240s.")
            return
        }
        let firstResponseSeconds = Date().timeIntervalSince(sendStarted)
        let via = assistantMessageById.exists ? "id" : "stream_text"
        print(String(format: "E2E_TIMING first_assistant_response_s=%.2f via=%@", firstResponseSeconds, via))

        // Re-open chat (leave Chat tab via Files and return) to measure recent-open feel.
        let filesTab = app.tabBars.buttons["Files"].firstMatch
        if filesTab.waitForExistence(timeout: 5) {
            filesTab.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let chatTabAgain = app.tabBars.buttons["Chat"].firstMatch
            XCTAssertTrue(chatTabAgain.waitForExistence(timeout: 10))
            let reopenStarted = Date()
            chatTabAgain.tap()
            let reopenUserById = app
                .descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-message-user-"))
                .firstMatch
            let reopenUserByText = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@", promptMarker))
                .firstMatch
            XCTAssertTrue(
                reopenUserById.waitForExistence(timeout: 15) || reopenUserByText.waitForExistence(timeout: 15),
                "Messages did not reappear after recent chat reopen."
            )
            let reopenSeconds = Date().timeIntervalSince(reopenStarted)
            print(String(format: "E2E_TIMING recent_chat_reopen_to_messages_s=%.2f", reopenSeconds))
        }
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
        XCTAssertTrue(
            app.navigationBars["MCP Servers"].waitForNonExistence(timeout: 10),
            "MCP Servers sheet did not dismiss."
        )

        XCTAssertTrue(chatTab.waitForExistence(timeout: 20))
        chatTab.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let menuButtonAgain = app.buttons["chat-more-menu-button"].firstMatch
        XCTAssertTrue(menuButtonAgain.waitForExistence(timeout: 20))

        let skillsButton = app.descendants(matching: .any)["chat-agent-skills-button"].firstMatch
        // Menu presentation is flaky after dismissing MCP; reopen until skills appears.
        let skillsMenuDeadline = Date().addingTimeInterval(20)
        while !skillsButton.exists && Date() < skillsMenuDeadline {
            if menuButtonAgain.isHittable {
                menuButtonAgain.tap()
            } else {
                tapElement(menuButtonAgain)
            }
            if skillsButton.waitForExistence(timeout: 3) { break }
            // Dismiss a half-open menu and try again.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(skillsButton.waitForExistence(timeout: 5), "Agent Skills menu item did not appear for OpenCode chat.")
        tapElement(skillsButton)

        XCTAssertTrue(app.navigationBars["Agent Skills"].waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.buttons["agent-skills-picker-add-menu-button"].waitForExistence(timeout: 10)
                || app.buttons["agent-skills-browse-marketplaces-button"].waitForExistence(timeout: 10),
            "OpenCode agent skills settings did not show install/add controls."
        )
        dismissPresentedSheetIfNeeded()
    }

    /// Create a minutely scheduled task on the live daemon and verify it syncs + preferably fires.
    private func createAndVerifyMinutelyScheduledTaskOnRealInstance(_ config: CloudE2EConfiguration) throws {
        // Warm SSH before daemon writes (:8787). Chat alone is not always enough after a long
        // provision/chat gap — explicitly hit OpenCode "Check runtime" when available.
        let chatTab = app.tabBars.buttons["Chat"].firstMatch
        if chatTab.waitForExistence(timeout: 10) {
            chatTab.tap()
            _ = app.descendants(matching: .any)["chat-composer-input"].firstMatch.waitForExistence(timeout: 15)
            let menuButton = app.buttons["chat-more-menu-button"].firstMatch
            if menuButton.waitForExistence(timeout: 10) {
                if menuButton.isHittable { menuButton.tap() } else { tapElement(menuButton) }
                let runtimeButton = app.descendants(matching: .any)["chat-agent-runtime-settings-button"].firstMatch
                if runtimeButton.waitForExistence(timeout: 5) {
                    tapElement(runtimeButton)
                    if openCodeRuntimeNavigationBar().waitForExistence(timeout: 10) {
                        let checkRuntime = app.buttons["agent-runtime-check-button"].firstMatch
                        if checkRuntime.waitForExistence(timeout: 5) {
                            if checkRuntime.isHittable { checkRuntime.tap() } else { tapElement(checkRuntime) }
                            // Wait for status text; prefer full healthy (OpenCode + daemon on :8787).
                            let statusDeadline = Date().addingTimeInterval(45)
                            while Date() < statusDeadline {
                                let health = app.staticTexts.matching(
                                    NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "healthy", "daemon")
                                ).firstMatch
                                if health.exists { break }
                                RunLoop.current.run(until: Date().addingTimeInterval(1))
                            }
                            // Second check after a short settle in case the first probe raced cloud-init.
                            RunLoop.current.run(until: Date().addingTimeInterval(3))
                            if checkRuntime.isEnabled {
                                if checkRuntime.isHittable { checkRuntime.tap() } else { tapElement(checkRuntime) }
                                RunLoop.current.run(until: Date().addingTimeInterval(10))
                            }
                        }
                        closeAgentRuntimeSettingsIfNeeded()
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        let tasksTab = app.tabBars.buttons["Regular Tasks"].firstMatch
        XCTAssertTrue(tasksTab.waitForExistence(timeout: 30))
        tasksTab.tap()

        XCTAssertTrue(app.navigationBars["Regular Tasks"].waitForExistence(timeout: 20))
        let addButton = app.buttons["regular-tasks-add-button"].firstMatch
        let emptyAddButton = app.buttons["regular-tasks-add-empty-button"].firstMatch
        let addByLabel = app.buttons["Add Task"].firstMatch
        XCTAssertTrue(
            addButton.waitForExistence(timeout: 20)
                || emptyAddButton.waitForExistence(timeout: 20)
                || addByLabel.waitForExistence(timeout: 5),
            "Regular Tasks add control did not appear for OpenCode agent."
        )
        // Prefer the empty-state CTA (large target); toolbar + is always present but less reliable on iOS 26.
        func openNewTaskEditor(preferringEmpty: Bool) {
            let control: XCUIElement = {
                if preferringEmpty, emptyAddButton.exists { return emptyAddButton }
                if addByLabel.exists { return addByLabel }
                if emptyAddButton.exists { return emptyAddButton }
                return addButton
            }()
            XCTAssertTrue(control.waitForExistence(timeout: 10), "Add Task control missing.")
            XCTAssertTrue(control.isEnabled, "Add Task control is disabled (provider lock?).")
            if control.isHittable {
                control.tap()
            } else {
                tapElement(control)
            }
        }

        openNewTaskEditor(preferringEmpty: true)
        let titleField = app.descendants(matching: .any)["regular-task-title-field"].firstMatch
        if !titleField.waitForExistence(timeout: 5) {
            // Fall back to the other affordance if the first tap did not present the sheet.
            openNewTaskEditor(preferringEmpty: false)
        }
        XCTAssertTrue(
            titleField.waitForExistence(timeout: 20)
                || app.navigationBars["New Task"].waitForExistence(timeout: 5)
                || app.buttons["regular-task-save-button"].waitForExistence(timeout: 5)
                || app.buttons["Cancel"].waitForExistence(timeout: 5),
            "New Task editor did not present after tapping Add."
        )

        let taskTitle = "E2E minutely \(config.runIDFragment)"
        let taskPrompt = "E2E scheduled task ping \(config.runIDFragment). Reply with one short OK."

        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        replaceText(in: titleField, with: taskTitle, preferPasteboard: false)

        let promptField = app.descendants(matching: .any)["regular-task-prompt-field"].firstMatch
        XCTAssertTrue(promptField.waitForExistence(timeout: 10))
        promptField.tap()
        promptField.typeText(taskPrompt)

        let frequencyPicker = app.descendants(matching: .any)["regular-task-frequency-picker"].firstMatch
        XCTAssertTrue(frequencyPicker.waitForExistence(timeout: 10))
        frequencyPicker.tap()
        // TaskFrequency.minutely displayName is "Minutes"
        let minutesOption = app.buttons["Minutes"].firstMatch
        if minutesOption.waitForExistence(timeout: 3) {
            minutesOption.tap()
        } else {
            // Some iOS versions expose menu actions differently
            let minutesMenu = app.menuItems["Minutes"].firstMatch
            XCTAssertTrue(minutesMenu.waitForExistence(timeout: 3), "Could not select Minutes frequency.")
            minutesMenu.tap()
        }

        let saveButton = app.buttons["regular-task-save-button"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))
        let saveDeadline = Date().addingTimeInterval(10)
        while !saveButton.isEnabled && Date() < saveDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(saveButton.isEnabled, "Save stayed disabled for scheduled task form.")
        let saveStarted = Date()
        saveButton.tap()

        // Stay on the editor: dismiss error alerts and re-tap Save when it becomes enabled again
        // (isSaving cleared after a failed/timed-out daemon write). Also re-tap periodically while
        // Save stays enabled — first tap can no-op if the control was not hittable.
        var saved = false
        var sawSaveDisabled = false
        var lastSaveTap = saveStarted
        let saveOverallDeadline = Date().addingTimeInterval(150)
        while Date() < saveOverallDeadline {
            dismissErrorAlertIfPresent()
            if !titleField.exists {
                saved = true
                break
            }
            if saveButton.exists {
                if !saveButton.isEnabled {
                    sawSaveDisabled = true
                } else {
                    let idleEnabled = Date().timeIntervalSince(lastSaveTap) >= 20
                    if sawSaveDisabled || idleEnabled {
                        if saveButton.isHittable {
                            saveButton.tap()
                        } else {
                            tapElement(saveButton)
                        }
                        sawSaveDisabled = false
                        lastSaveTap = Date()
                    }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        if !saved {
            failIfErrorAlertVisible()
            XCTFail("Timed out saving scheduled task — daemon at :8787 may be unavailable (SSH/NIOSSH).")
        }
        XCTAssertTrue(app.navigationBars["Regular Tasks"].waitForExistence(timeout: 15))
        let listRowByTitle = app.staticTexts[taskTitle].firstMatch
        XCTAssertTrue(
            listRowByTitle.waitForExistence(timeout: 20),
            "Saved minutely task did not appear in Regular Tasks list (sync may have failed)."
        )
        let saveSeconds = Date().timeIntervalSince(saveStarted)
        print(String(format: "E2E_TIMING scheduled_task_save_and_list_s=%.2f", saveSeconds))

        // Wait for the live scheduler to fire (minutely, clock-boundary) and land in chat.
        XCTAssertTrue(chatTab.waitForExistence(timeout: 20))
        chatTab.tap()

        let fireDeadline = Date().addingTimeInterval(150)
        var sawScheduledPrompt = false
        while Date() < fireDeadline {
            failIfErrorAlertVisible()
            let promptHit = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", config.runIDFragment)).firstMatch
            if promptHit.exists {
                sawScheduledPrompt = true
                break
            }
            // Pull to refresh-ish: leave and re-enter chat to pick up hydration.
            if tasksTab.waitForExistence(timeout: 2) {
                tasksTab.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                chatTab.tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(5))
        }
        let waitSeconds = Date().timeIntervalSince(saveStarted)
        print(String(format: "E2E_TIMING scheduled_task_fire_wait_s=%.2f saw_prompt=%@", waitSeconds, sawScheduledPrompt ? "yes" : "no"))
        XCTAssertTrue(
            sawScheduledPrompt,
            "Minutely scheduled task did not produce chat content containing '\(config.runIDFragment)' within 150s on the real instance."
        )
    }

    private func closeAgentRuntimeSettingsIfNeeded() {
        let doneButton = app.buttons["agent-runtime-done-button"].firstMatch
        if doneButton.exists {
            doneButton.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            return
        }

        let runtimeNavigationBar = openCodeRuntimeNavigationBar()
        guard runtimeNavigationBar.exists else { return }

        for _ in 0..<3 where runtimeNavigationBar.exists {
            app.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }

    private func dismissPresentedSheetIfNeeded() {
        // Prefer explicit toolbar dismiss controls on settings sheets.
        for title in ["Done", "Close", "Cancel"] {
            let button = app.navigationBars.buttons[title].firstMatch
            if button.exists && button.isHittable {
                button.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                return
            }
        }
        // Fall back to interactive swipe-to-dismiss even when tab bars remain visible under the sheet.
        for _ in 0..<4 {
            if app.buttons["chat-more-menu-button"].firstMatch.exists
                && !app.navigationBars["MCP Servers"].exists
                && !app.navigationBars["Agent Skills"].exists
                && !openCodeRuntimeNavigationBar().exists {
                return
            }
            app.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
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
        clearExistingFieldValue(element)

        if preferPasteboard {
            UIPasteboard.general.string = text
            element.press(forDuration: 1.0)
            let pasteMenuItem = app.menuItems["Paste"].firstMatch
            if pasteMenuItem.waitForExistence(timeout: 2) {
                pasteMenuItem.tap()
                // Paste on SecureField is flaky on recent simulators — fall through if still empty.
                let after = (element.value as? String) ?? ""
                if !after.isEmpty, after != element.placeholderValue {
                    return
                }
            }
            clearExistingFieldValue(element)
        }

        // typeText in chunks to reduce truncation on long secrets.
        let chunkSize = 32
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            element.typeText(String(text[index..<end]))
            index = end
        }
    }

    /// Clears the full current field value so replacements never leave a corrupted prefix.
    private func clearExistingFieldValue(_ element: XCUIElement) {
        guard let current = element.value as? String,
              !current.isEmpty,
              current != element.placeholderValue else {
            return
        }

        element.press(forDuration: 1.2)
        let selectAll = app.menuItems["Select All"].firstMatch
        if selectAll.waitForExistence(timeout: 1.5) {
            selectAll.tap()
            element.typeText(XCUIKeyboardKey.delete.rawValue)
            return
        }

        // No Select All menu — delete the full known value character by character.
        // SecureField values are often bullets (•); still delete current.count times.
        let deleteCount = max(current.count, 1)
        let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount)
        element.typeText(deletes)
    }

    /// Type a secret into a SecureField without using UIPasteboard (avoids iOS paste privacy hangs).
    private func typeSecureToken(into element: XCUIElement, token: String) {
        element.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        clearExistingFieldValue(element)
        let chunkSize = 24
        var index = token.startIndex
        while index < token.endIndex {
            let end = token.index(index, offsetBy: chunkSize, limitedBy: token.endIndex) ?? token.endIndex
            element.typeText(String(token[index..<end]))
            index = end
        }
        // Do not press Return/Done here — resign focus by tapping Settings after Connect.
    }

    /// Legacy name kept for call sites that previously pasted; always types to avoid paste hangs.
    private func enterSecureToken(_ element: XCUIElement, _ token: String) {
        typeSecureToken(into: element, token: token)
    }

    private func tapElement(_ element: XCUIElement) {
        guard element.exists else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }
        // Element-relative center avoids not-hittable failures from leftover keyboard/overlays.
        let center = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
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
        dismissKeyboardIfNeeded()
        if !element.isHittable {
            _ = scrollToElement(element, timeout: 10)
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        tapElement(element)
    }

    private func scrollToElement(
        _ element: XCUIElement,
        timeout: TimeInterval,
        direction: ScrollDirection = .up
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists {
                // Prefer existence only — isHittable can throw with invalid activation points.
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
        return element.exists
    }

    /// Dismiss a blocking error alert if present (returns true when one was dismissed).
    @discardableResult
    private func dismissErrorAlertIfPresent() -> Bool {
        let alertCount = app.alerts.count
        guard alertCount > 0 else { return false }
        let alert = app.alerts.element(boundBy: 0)
        guard alert.waitForExistence(timeout: 1) else { return false }
        let ok = alert.buttons["OK"].firstMatch
        if ok.exists {
            ok.tap()
        } else {
            alert.buttons.firstMatch.tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        return true
    }

    private func failIfErrorAlertVisible() {
        // Querying alerts during sheet transitions can throw snapshot errors on recent Xcode;
        // only inspect when the hierarchy reports at least one alert.
        let alerts = app.alerts
        guard alerts.count > 0 else { return }
        let alert = alerts.element(boundBy: 0)
        guard alert.waitForExistence(timeout: 0.5) else { return }
        let message = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
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
    let runID: String
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

    /// Short unique token embedded in scheduled-task prompts so E2E can detect a live fire in chat.
    var runIDFragment: String { runID }

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

        let runID = String(environment["MOBILECODE_E2E_RUN_ID"] ?? UUID().uuidString.prefix(8).lowercased())
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
            runID: runID,
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
        // Prefer runner-generated secrets, then home/local overrides. Never prefer the
        // committed sample `mobilecode-e2e.env` (often stale placeholders / expired tokens).
        paths.append("\(repoRoot)/scripts/e2e/.mobilecode-e2e.generated.env")
        paths.append("\(NSHomeDirectory())/.mobilecode-e2e.env")
        paths.append("\(repoRoot)/.mobilecode-e2e.env")
        paths.append("\(repoRoot)/scripts/e2e/mobilecode-e2e.env")

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
        try deleteCreatedResourcesBestEffort()
    }

    /// Deletes only this run's exact server and SSH key (`config.serverName` / `config.sshKeyName`).
    /// Broad shared-prefix cleanup belongs to the shell pre/post-clean phase so parallel E2E jobs
    /// (or intentionally kept droplets under the same prefix) are not torn down by another run.
    func deleteCreatedResourcesBestEffort() throws {
        guard config.deleteCreatedServers else {
            print("Skipping cloud cleanup because MOBILECODE_E2E_DELETE_CREATED_SERVERS is 0.")
            return
        }

        try validateSafety()

        let servers = try listServers()
        let matches = servers.filter { $0.name == config.serverName }

        if matches.isEmpty {
            print("No cloud server matched exact cleanup name '\(config.serverName)' (prefix-wide delete is owned by the E2E runner).")
        } else {
            for server in matches {
                try deleteServer(id: server.id)
                print("Deleted \(config.provider.rawValue) server \(server.name) (\(server.id)) during UI-test teardown.")
            }
        }

        // Best-effort SSH key cleanup for this run only (shell runner cleans stale keys by prefix).
        if let keys = try? listSSHKeys() {
            let keyMatches = keys.filter { $0.name == config.sshKeyName }
            for key in keyMatches {
                try? deleteSSHKey(id: key.id)
                print("Deleted \(config.provider.rawValue) SSH key \(key.name) (\(key.id)) during UI-test teardown.")
            }
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

    private func listSSHKeys() throws -> [RemoteServer] {
        switch config.provider {
        case .digitalocean:
            return try listDigitalOceanSSHKeys()
        case .hetzner:
            return try listHetznerSSHKeys()
        }
    }

    private func deleteSSHKey(id: String) throws {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url: URL
        switch config.provider {
        case .digitalocean:
            url = URL(string: "https://api.digitalocean.com/v2/account/keys/\(encodedID)")!
        case .hetzner:
            url = URL(string: "https://api.hetzner.cloud/v1/ssh_keys/\(encodedID)")!
        }

        let response = try request(method: "DELETE", url: url)
        guard response.statusCode == 404 || (200..<300).contains(response.statusCode) else {
            throw CleanupError.httpError(statusCode: response.statusCode, body: response.body)
        }
    }

    private func listDigitalOceanSSHKeys() throws -> [RemoteServer] {
        var keys: [RemoteServer] = []
        var nextURL = URL(string: "https://api.digitalocean.com/v2/account/keys?per_page=200")!

        while true {
            let response = try request(method: "GET", url: nextURL)
            guard (200..<300).contains(response.statusCode) else {
                throw CleanupError.httpError(statusCode: response.statusCode, body: response.body)
            }
            guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw CleanupError.invalidResponse
            }

            if let sshKeys = payload["ssh_keys"] as? [[String: Any]] {
                keys.append(contentsOf: sshKeys.compactMap { key in
                    guard let id = key["id"], let name = key["name"] as? String else { return nil }
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

        return keys
    }

    private func listHetznerSSHKeys() throws -> [RemoteServer] {
        var keys: [RemoteServer] = []
        var page = 1

        while true {
            let url = URL(string: "https://api.hetzner.cloud/v1/ssh_keys?per_page=50&page=\(page)")!
            let response = try request(method: "GET", url: url)
            guard (200..<300).contains(response.statusCode) else {
                throw CleanupError.httpError(statusCode: response.statusCode, body: response.body)
            }
            guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                throw CleanupError.invalidResponse
            }

            if let sshKeys = payload["ssh_keys"] as? [[String: Any]] {
                keys.append(contentsOf: sshKeys.compactMap { key in
                    guard let id = key["id"], let name = key["name"] as? String else { return nil }
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

        return keys
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
