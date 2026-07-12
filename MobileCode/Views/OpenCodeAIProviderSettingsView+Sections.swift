//
//  OpenCodeAIProviderSettingsView+Sections.swift
//  CodeAgentsMobile
//
//  Purpose: Home status surface and Change-sheet wizard (save happens on final step)
//

import SwiftUI

private extension String {
    var trimmedOpenCodeValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OpenCodeAIChangeStep: Hashable {
    case connect
    case model
    case thinking
}

extension OpenCodeAIProviderSettingsView {
    var editsDisabled: Bool {
        server != nil && useGlobalDefaults
    }

    // MARK: - Home

    @ViewBuilder
    var scopeSection: some View {
        if let server {
            Section {
                Toggle("Use Global Defaults", isOn: $useGlobalDefaults)
                    .accessibilityIdentifier("opencode-ai-use-global-toggle")

                LabeledContent("Server", value: server.name)

                if useGlobalDefaults {
                    Label("This server follows the global CodeAgents provider setup.", systemImage: "arrow.triangle.branch")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Scope")
            }
        }
    }

    var currentSetupSection: some View {
        Section {
            Button {
                guard !editsDisabled else { return }
                changePath = NavigationPath()
                showChangeSheet = true
            } label: {
                currentSetupCard
            }
            .buttonStyle(.plain)
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-change-setup-button")
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(Color.clear)
        } header: {
            Text("Current")
        } footer: {
            if editsDisabled {
                Text("Turn off Use Global Defaults to change this server’s provider.")
            } else {
                Text(changeHomeFooterText)
            }
        }
    }

    var changeHomeFooterText: String {
        if server == nil {
            let count = servers.count
            if count == 0 {
                return "Tap the card to choose a provider and model. Add a server before OpenCode can save the setup."
            }
            return "Tap the card to choose provider, sign-in, and model. Saving at the end writes to all \(count) server\(count == 1 ? "" : "s")."
        }
        return "Tap the card to choose provider, sign-in, and model. Saving at the end writes to this server."
    }

    var currentSetupCard: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedProviderSymbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedProviderName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(selectedProviderSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(currentModelSummaryLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "cpu")
                        .foregroundStyle(.secondary)
                }

                if showsThinkingSection {
                    Label {
                        Text("Thinking · \(selectedThinkingTitle)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "brain")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 4)

            HStack {
                Text("Change…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)

        return Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.15)).interactive(),
                        in: .rect(cornerRadius: 16)
                    )
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
                    )
            }
        }
    }

    var currentModelSummaryLine: String {
        if customProviderEnabled {
            let id = profile.customModelID.trimmedOpenCodeValue
            if id.isEmpty {
                return "No model selected"
            }
            let name = profile.customModelName.trimmedOpenCodeValue
            return name.isEmpty ? id : "\(name) · \(id)"
        }

        guard let modelID = profile.resolvedModelID?.trimmedOpenCodeValue, !modelID.isEmpty else {
            return "No model selected"
        }
        if selectedModelUnavailable {
            return "\(modelID) · not on server"
        }
        if let choice = selectedModelChoice,
           choice.modelName.caseInsensitiveCompare(choice.modelID) != .orderedSame {
            return "\(choice.modelName) · \(modelID)"
        }
        return modelID
    }

    @ViewBuilder
    var homeStatusSection: some View {
        if isRefreshingStatus || statusMessage != nil {
            Section {
                if isRefreshingStatus {
                    HStack {
                        ProgressView()
                        Text("Checking OpenCode providers…")
                            .foregroundColor(.secondary)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ToolbarContentBuilder
    var homeToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { await refreshProviderStatusIfPossible() }
                } label: {
                    Label(
                        isRefreshingStatus ? "Refreshing…" : "Refresh Providers",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRefreshingStatus)
                .accessibilityIdentifier("opencode-ai-refresh-providers-button")

                if canRemoveProviderAuth {
                    Divider()

                    if server == nil {
                        Button(role: .destructive) {
                            removeAuthFromAllServers = true
                            confirmRemoveAuth = true
                        } label: {
                            Label(
                                "Disconnect \(selectedProviderName) on All Servers…",
                                systemImage: "person.2.crop.square.stack"
                            )
                        }
                        .disabled(editsDisabled || isRemovingAuth)
                        .accessibilityIdentifier("opencode-ai-remove-auth-all-servers-button")
                    } else if let targetServer = authActionTargetServer {
                        Button(role: .destructive) {
                            removeAuthFromAllServers = false
                            confirmRemoveAuth = true
                        } label: {
                            Label(
                                "Disconnect \(selectedProviderName) on \(targetServer.name)…",
                                systemImage: "person.crop.circle.badge.xmark"
                            )
                        }
                        .disabled(editsDisabled || isRemovingAuth)
                        .accessibilityIdentifier("opencode-ai-remove-auth-server-button")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityIdentifier("opencode-ai-more-menu-button")
        }
    }

    // MARK: - Change sheet

    var changeSetupSheet: some View {
        NavigationStack(path: $changePath) {
            changeProviderStep
                .navigationDestination(for: OpenCodeAIChangeStep.self) { step in
                    switch step {
                    case .connect:
                        changeConnectStep
                    case .model:
                        changeModelStep
                    case .thinking:
                        changeThinkingStep
                    }
                }
        }
    }

    var changeProviderStep: some View {
        List {
            if !signedInProviderChoices.isEmpty {
                Section("Signed in") {
                    ForEach(signedInProviderChoices) { choice in
                        changeProviderRow(choice)
                    }
                }
            }

            Section(signedInProviderChoices.isEmpty ? "Providers" : "More providers") {
                ForEach(moreProviderChoices) { choice in
                    changeProviderRow(choice)
                }
            }
        }
        .navigationTitle("Choose Provider")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $changeProviderSearchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search by name or id"
        )
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { showChangeSheet = false }
            }
        }
    }

    func changeProviderRow(_ choice: OpenCodeProviderChoice) -> some View {
        Button {
            selectProvider(choice)
            advanceAfterProviderSelection()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.name)
                        .foregroundColor(.primary)
                    Text(choice.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if choice.isConnected {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else if !choice.isCustom,
                          choice.id.caseInsensitiveCompare(profile.normalizedProviderID) == .orderedSame {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("opencode-ai-change-provider-\(choice.id)")
    }

    var signedInProviderChoices: [OpenCodeProviderChoice] {
        filteredChangeProviderChoices.filter { $0.isConnected && !$0.isCustom }
    }

    var moreProviderChoices: [OpenCodeProviderChoice] {
        filteredChangeProviderChoices.filter { !$0.isConnected || $0.isCustom }
    }

    var filteredChangeProviderChoices: [OpenCodeProviderChoice] {
        let query = changeProviderSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = providerChoices.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected {
                return lhs.isConnected && !rhs.isConnected
            }
            if lhs.isCustom != rhs.isCustom {
                return !lhs.isCustom && rhs.isCustom
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    func advanceAfterProviderSelection() {
        if changeFlowNeedsConnect {
            changePath.append(OpenCodeAIChangeStep.connect)
        } else {
            changePath.append(OpenCodeAIChangeStep.model)
        }
    }

    var changeFlowNeedsConnect: Bool {
        if selectedProviderUsesNoCredential {
            return false
        }
        if providerIsConnected {
            return false
        }
        // Custom always needs endpoint + key configuration.
        if customProviderEnabled {
            return true
        }
        return true
    }

    var changeConnectStep: some View {
        Form {
            Section {
                LabeledContent("Provider", value: selectedProviderName)
                LabeledContent("Sign in with", value: selectedConnectionMethodTitle)
                LabeledContent("Server status") {
                    Text(selectedConnectionStatusTitle)
                        .foregroundColor(providerIsConnected || selectedProviderUsesNoCredential ? .green : .secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            if customProviderEnabled {
                Section("Endpoint") {
                    customProviderFields
                }
            }

            if showsAuthModePicker {
                Section {
                    Picker("Sign-in method", selection: authModeBinding) {
                        Text("API Key").tag(OpenCodeProviderAuthMode.apiKey)
                        Text("OAuth").tag(OpenCodeProviderAuthMode.oauth)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("opencode-ai-auth-mode-picker")
                } footer: {
                    Text("Prefer OAuth / subscription for headless remote servers when available.")
                }
            }

            if profile.authMode == .oauth && availableOAuthMethods.count > 1 {
                Section {
                    Picker("OAuth method", selection: oauthMethodIndexBinding) {
                        ForEach(availableOAuthMethods, id: \.index) { item in
                            Text(item.method.shortDisplayLabel).tag(Optional.some(item.index))
                        }
                    }
                    .accessibilityIdentifier("opencode-ai-oauth-method-picker")
                } footer: {
                    Text("Headless / device code is best for SSH servers (no browser on the host).")
                }
            }

            Section {
                if selectedProviderUsesNoCredential {
                    Label(
                        "OpenCode Zen uses bundled models — no provider credential required.",
                        systemImage: "checkmark.seal.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.footnote)
                } else if profile.requiresAPIKeyCredential {
                    if providerConnectedInStatus {
                        Label(
                            "\(selectedProviderName) is connected via \(serverAuthTypeDisplayLabel ?? "API Key"). You can paste a new key to replace it.",
                            systemImage: "checkmark.seal.fill"
                        )
                        .foregroundStyle(.green)
                        .font(.footnote)
                    }

                    SecureField(
                        providerConnectedInStatus ? "Replace API Key on Server" : "API Key",
                        text: $apiKey
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("opencode-ai-api-key-field")

                    if canUseLegacyAPIKeyForOpenCode {
                        Button {
                            useLegacyAPIKeyForOpenCode()
                        } label: {
                            Label("Use for OpenCode", systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("opencode-ai-use-legacy-key-button")

                        Text("Copies the matching Claude Code Proxy API key into OpenCode storage and leaves the legacy key unchanged.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    providerOAuthConnectionView
                }
            } footer: {
                Text(credentialFooterText)
            }

            if customProviderEnabled {
                Section("API Style") {
                    Picker("API Style", selection: npmDriverBinding) {
                        ForEach(OpenCodeProviderNPMDriver.allCases) { driver in
                            Text(driver.displayName).tag(driver)
                        }
                    }
                }
            }
        }
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Pure OAuth providers (e.g. GitHub Copilot) have no API key path.
            if supportsOAuthAuth && !supportsAPIKeyAuth && profile.authMode != .oauth {
                profile.authMode = .oauth
            }
            if profile.authMode == .oauth {
                seedOAuthPromptDefaults()
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") {
                    changePath.append(OpenCodeAIChangeStep.model)
                }
                .disabled(!canContinueFromConnect)
                .accessibilityIdentifier("opencode-ai-connect-continue-button")
            }
        }
    }

    var canContinueFromConnect: Bool {
        if selectedProviderUsesNoCredential {
            return true
        }
        if customProviderEnabled {
            let id = profile.providerID.trimmedOpenCodeValue
            let base = profile.customBaseURL.trimmedOpenCodeValue
            let keyReady = providerConnectedInStatus || !apiKey.trimmedOpenCodeValue.isEmpty
            return !id.isEmpty && !base.isEmpty && keyReady
        }
        if profile.requiresAPIKeyCredential {
            return providerConnectedInStatus || !apiKey.trimmedOpenCodeValue.isEmpty
        }
        // OAuth / subscription
        return providerIsConnected
    }

    var oauthMethodIndexBinding: Binding<Int?> {
        Binding(
            get: {
                oauthMethodIndex ?? selectedOAuthMethod?.index
            },
            set: { newValue in
                oauthMethodIndex = newValue
                oauthAuthorization = nil
                oauthCode = ""
                seedOAuthPromptDefaults()
            }
        )
    }

    var changeModelStep: some View {
        Group {
            if customProviderEnabled {
                Form {
                    Section {
                        TextField("Model ID", text: $profile.customModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("opencode-ai-custom-model-id-field")

                        TextField("Model Name", text: $profile.customModelName)
                            .accessibilityIdentifier("opencode-ai-custom-model-name-field")
                    } footer: {
                        Text("Enter the model id your OpenAI-compatible endpoint expects. \(changeSaveScopeFooter)")
                    }
                }
            } else if selectedProviderModelChoices.isEmpty {
                Form {
                    Section {
                        TextField("Model ID", text: $profile.modelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("opencode-ai-model-id-field")
                    } footer: {
                        Text(manualModelFooterText)
                    }
                }
            } else {
                List {
                    Section {
                        ForEach(filteredChangeModelChoices) { choice in
                            Button {
                                handleModelChoiceSelection(choice)
                            } label: {
                                modelChoiceRow(choice)
                            }
                            .disabled(isApplying)
                            .accessibilityIdentifier("opencode-ai-model-choice-\(choice.id)")
                        }
                    } footer: {
                        Text(modelListSaveFooterText)
                    }
                }
                .searchable(
                    text: $changeModelSearchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search models"
                )
            }
        }
        .navigationTitle("Choose Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if usesManualModelEntry {
                    changeSheetSaveToolbarButton
                } else if showsThinkingSection && modelStepComplete {
                    Button("Continue") {
                        changePath.append(OpenCodeAIChangeStep.thinking)
                    }
                    .disabled(!modelStepComplete || isApplying)
                    .accessibilityIdentifier("opencode-ai-model-continue-button")
                } else if modelStepComplete {
                    // Explicit save for free-text re-entry or retry after a failed apply.
                    changeSheetSaveToolbarButton
                }
            }
        }
        .interactiveDismissDisabled(isApplying)
    }

    func handleModelChoiceSelection(_ choice: OpenCodeModelChoice) {
        selectModel(choice)
        if choice.supportsReasoning {
            // Thinking is the last configuration step before save.
            changePath.append(OpenCodeAIChangeStep.thinking)
            return
        }
        guard canApply else { return }
        Task { await finishChangeAndApply() }
    }

    /// Free-text model entry (custom endpoint or empty catalog).
    var usesManualModelEntry: Bool {
        customProviderEnabled || selectedProviderModelChoices.isEmpty
    }

    var manualModelFooterText: String {
        let base: String
        if providerStatus == nil {
            base = "Provider catalog not loaded yet. Enter a model id manually, or cancel and refresh."
        } else {
            base = "No models reported for this provider. Enter a model id manually."
        }
        return "\(base) \(changeSaveScopeFooter)"
    }

    var modelListSaveFooterText: String {
        "Tap a model to save. Models with Thinking open one more step first. \(changeSaveScopeFooter)"
    }

    var changeSaveScopeFooter: String {
        if let server {
            return "Saves on \(server.name)."
        }
        let count = servers.count
        if count == 0 {
            return "Add a server to save."
        }
        return "Saves on all \(count) server\(count == 1 ? "" : "s")."
    }

    var changeSheetSaveButtonTitle: String {
        if isApplying {
            return "Saving…"
        }
        if let server {
            return "Save on \(server.name)"
        }
        let count = servers.count
        if count <= 1 {
            return "Save on Server"
        }
        return "Save on All \(count) Servers"
    }

    var changeSheetSaveAccessibilityID: String {
        server == nil
            ? "opencode-ai-apply-all-servers-button"
            : "opencode-ai-apply-server-button"
    }

    @ViewBuilder
    var changeSheetSaveToolbarButton: some View {
        Button {
            Task { await finishChangeAndApply() }
        } label: {
            if isApplying {
                ProgressView()
            } else {
                Text(changeSheetSaveButtonTitle)
            }
        }
        .disabled(!canApply || isApplying || (server == nil && servers.isEmpty))
        .accessibilityIdentifier(changeSheetSaveAccessibilityID)
    }

    func modelChoiceRow(_ choice: OpenCodeModelChoice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.id)
                    .foregroundColor(.primary)
                Text(modelChoiceSubtitle(choice))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if choice.supportsReasoning {
                Text("Thinking")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(.tint)
            }

            if choice.isDeprecated {
                Text("Deprecated")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }

            if choice.matches(storedModelID: profile.modelID)
                || (profile.resolvedModelID.map { choice.matches(storedModelID: $0) } ?? false) {
                Image(systemName: isApplying ? "arrow.triangle.2.circlepath" : "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }

    var filteredChangeModelChoices: [OpenCodeModelChoice] {
        let query = changeModelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return selectedProviderModelChoices }
        return selectedProviderModelChoices.filter {
            $0.modelName.localizedCaseInsensitiveContains(query)
                || $0.modelID.localizedCaseInsensitiveContains(query)
                || $0.providerName.localizedCaseInsensitiveContains(query)
        }
    }

    func modelChoiceSubtitle(_ choice: OpenCodeModelChoice) -> String {
        var parts: [String] = []
        if choice.modelName.caseInsensitiveCompare(choice.modelID) != .orderedSame {
            parts.append(choice.modelName)
        }
        if choice.supportsReasoning {
            parts.append("supports thinking")
        }
        return parts.isEmpty ? choice.providerName : parts.joined(separator: " · ")
    }

    var changeThinkingStep: some View {
        List {
            Section {
                ForEach(thinkingChoices) { choice in
                    Button {
                        selectThinking(choice)
                        if canApply {
                            Task { await finishChangeAndApply() }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.title)
                                    .foregroundColor(.primary)
                                if let subtitle = choice.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            if choice.id.caseInsensitiveCompare(profile.variant) == .orderedSame {
                                Image(systemName: isApplying ? "arrow.triangle.2.circlepath" : "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(isApplying)
                    .accessibilityIdentifier(
                        "opencode-ai-thinking-choice-\(choice.id.isEmpty ? "default" : choice.id)"
                    )
                }
            } footer: {
                Text("Selecting a thinking level saves this setup. \(changeSaveScopeFooter)")
            }
        }
        .navigationTitle("Thinking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await finishChangeAndApply() }
                } label: {
                    if isApplying {
                        ProgressView()
                    } else {
                        Text(changeSheetSaveButtonTitle)
                    }
                }
                .disabled(!canApply || isApplying || (server == nil && servers.isEmpty))
                .accessibilityIdentifier(changeSheetSaveAccessibilityID)
            }
        }
        .interactiveDismissDisabled(isApplying)
    }

    // MARK: - Shared connect helpers (used by Change sheet)

    @ViewBuilder
    var customProviderFields: some View {
        TextField("Provider ID", text: $profile.providerID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-provider-id-field")

        TextField("Display Name", text: $profile.providerName)
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-provider-name-field")

        TextField("Base URL", text: $profile.customBaseURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-custom-base-url-field")
    }

    @ViewBuilder
    var providerOAuthConnectionView: some View {
        if providerConnectedInStatus {
            Label(
                "\(selectedProviderName) is connected via \(serverAuthTypeDisplayLabel ?? selectedOAuthMethodTitle) on \(statusSourceName ?? "the server").",
                systemImage: "checkmark.seal.fill"
            )
            .foregroundStyle(.green)
            .font(.footnote)

            Text("This uses OAuth / subscription login — not an API key. Disconnect from the ··· menu to switch accounts or sign-in method.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if oauthCompletedForTargetServer {
            Label(
                "\(selectedOAuthMethodTitle) finished on \(oauthTargetServer?.name ?? "the server"). Continue and choose a model to save.",
                systemImage: "checkmark.seal.fill"
            )
            .foregroundStyle(.green)
            .font(.footnote)
        } else if oauthTargetServer == nil {
            Label("Add a server before using OAuth login", systemImage: "server.rack")
                .foregroundStyle(.secondary)
                .font(.footnote)
        } else if selectedOAuthMethod == nil && providerStatus != nil {
            Label(
                "OAuth login is not available for \(selectedProviderName) on this OpenCode server",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .foregroundStyle(.secondary)
            .font(.footnote)

            Text("Refresh providers or switch to API Key if available. Do not type /connect in CodeAgents chat; slash commands there are treated as skills.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let authorization = oauthAuthorization {
            oauthCompletionView(authorization)
        } else {
            oauthPromptFields

            let method = selectedOAuthMethod?.method
            let isHeadless = method?.isHeadlessPreferred == true
            Label(
                isHeadless
                    ? "Device code login — open the link on any device and enter the code"
                    : "Browser login runs on the OpenCode server (prefer headless when offered)",
                systemImage: isHeadless ? "iphone.and.arrow.forward" : "safari"
            )
            .foregroundStyle(.secondary)
            .font(.footnote)

            Button {
                Task { await startProviderOAuth() }
            } label: {
                savingLabel(
                    isWorking: isStartingOAuth,
                    title: "Start \(selectedOAuthMethodTitle) Login",
                    systemImage: "person.crop.circle.badge.plus"
                )
            }
            .disabled(
                editsDisabled
                    || isStartingOAuth
                    || selectedOAuthMethod == nil
                    || (selectedOAuthMethod.map { !oauthPromptInputsReady(for: $0.method) } ?? true)
            )
            .accessibilityIdentifier("opencode-ai-start-oauth-login-button")
        }
    }

    @ViewBuilder
    var oauthPromptFields: some View {
        ForEach(selectedOAuthPrompts) { prompt in
            if prompt.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "select",
               let options = prompt.options, !options.isEmpty {
                Picker(prompt.message, selection: oauthPromptBinding(for: prompt.key, defaultValue: options.first?.value ?? "")) {
                    ForEach(options, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .accessibilityIdentifier("opencode-ai-oauth-prompt-\(prompt.key)")
            } else {
                TextField(
                    prompt.placeholder ?? prompt.message,
                    text: oauthPromptBinding(for: prompt.key, defaultValue: prompt.placeholder ?? "")
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(prompt.key.lowercased().contains("url") ? .URL : .default)
                .accessibilityIdentifier("opencode-ai-oauth-prompt-\(prompt.key)")
            }
        }
    }

    func oauthPromptBinding(for key: String, defaultValue: String) -> Binding<String> {
        Binding(
            get: {
                if let value = oauthPromptInputs[key] {
                    return value
                }
                return defaultValue
            },
            set: { oauthPromptInputs[key] = $0 }
        )
    }

    @ViewBuilder
    func oauthCompletionView(_ authorization: OpenCodeProviderOAuthAuthorization) -> some View {
        if let url = URL(string: authorization.url) {
            Link(destination: url) {
                Label("Open Login Page", systemImage: "arrow.up.forward.app")
            }
            .accessibilityIdentifier("opencode-ai-open-oauth-login-link")
        } else {
            Text(authorization.url)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundColor(.secondary)
        }

        if let confirmationCode = oauthConfirmationCode(from: authorization.instructions) {
            LabeledContent("Code") {
                HStack(spacing: 8) {
                    Text(confirmationCode)
                        .font(.body.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Button {
                        copyOAuthConfirmationCode(confirmationCode)
                    } label: {
                        Image(systemName: copiedOAuthConfirmationCode ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copiedOAuthConfirmationCode ? "Copied code" : "Copy code")
                }
            }
        } else if !authorization.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(authorization.instructions)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        if authorization.isCodeBased {
            TextField("Authorization Code", text: $oauthCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("opencode-ai-oauth-authorization-code-field")
        }

        Button {
            Task { await completeProviderOAuth() }
        } label: {
            savingLabel(
                isWorking: isCompletingOAuth,
                title: authorization.isCodeBased ? "Complete Login" : "I Finished Login",
                systemImage: "checkmark.circle"
            )
        }
        .disabled(
            editsDisabled
                || isCompletingOAuth
                || (authorization.isCodeBased && oauthCode.trimmedOpenCodeValue.isEmpty)
        )
        .accessibilityIdentifier("opencode-ai-complete-oauth-login-button")

        Button(role: .cancel) {
            resetOAuthState()
            seedOAuthPromptDefaults()
        } label: {
            Label("Cancel Login", systemImage: "xmark.circle")
        }
        .disabled(isCompletingOAuth)

        Text(authorization.isAutoBased
            ? "Approve on the login page, then tap “I Finished Login” so OpenCode can finish on the server."
            : "Finish login, paste the authorization code if required, then complete.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}
