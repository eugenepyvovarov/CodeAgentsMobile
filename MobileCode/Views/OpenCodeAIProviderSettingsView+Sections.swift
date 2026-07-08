//
//  OpenCodeAIProviderSettingsView+Sections.swift
//  CodeAgentsMobile
//
//  Purpose: Form section builders for OpenCode AI provider settings
//

import SwiftUI

private extension String {
    var trimmedOpenCodeValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension OpenCodeAIProviderSettingsView {
    var editsDisabled: Bool {
        server != nil && useGlobalDefaults
    }

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

    var connectionSection: some View {
        Section {
            Button {
                showProviderPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedProviderSymbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedProviderName)
                            .font(.body)
                            .foregroundColor(.primary)
                        Text(selectedProviderSubtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
            .disabled(editsDisabled)
            .accessibilityIdentifier("opencode-ai-provider-picker-button")

            if customProviderEnabled {
                customProviderFields
            }

            if supportsChatGPTAuth {
                Picker("Sign in with", selection: authModeBinding) {
                    Text("API Key").tag(OpenCodeProviderAuthMode.apiKey)
                    Text("ChatGPT Plus/Pro").tag(OpenCodeProviderAuthMode.openAIChatGPT)
                }
                .pickerStyle(.segmented)
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-auth-mode-picker")
            } else if selectedProviderUsesNoCredential {
                LabeledContent("Sign in with") {
                    Text("No key")
                        .foregroundColor(.secondary)
                }
            } else {
                LabeledContent("Sign in with") {
                    Text("API Key")
                        .foregroundColor(.secondary)
                }
            }

            if selectedProviderUsesNoCredential {
                Label("No API key required", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.footnote)
            } else if profile.requiresAPIKeyCredential {
                if providerConnectedInStatus {
                    Label("\(selectedProviderName) is authorized on \(statusSourceName ?? "the server")", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                }

                SecureField(providerConnectedInStatus ? "Replace API Key on Server" : "API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
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
                chatGPTConnectionView
            }

            authRemovalControls
        } header: {
            Text("Connection")
        } footer: {
            Text(credentialFooterText)
        }
    }

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
    var chatGPTConnectionView: some View {
        if providerConnectedInStatus {
            Label("OpenAI is connected on \(statusSourceName ?? "the server")", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.footnote)

            Text("Remove auth below to sign in with a different OpenAI account.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if chatGPTOAuthCompletedForTargetServer {
            Label("OpenAI authorization completed on \(chatGPTOAuthTargetServer?.name ?? "the server")", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.footnote)

            Text("Apply to validate the selected model after OpenCode refreshes its provider cache.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if chatGPTOAuthTargetServer == nil {
            Label("Add a server before using ChatGPT Plus/Pro", systemImage: "server.rack")
                .foregroundStyle(.secondary)
                .font(.footnote)
        } else if chatGPTOAuthMethod == nil {
            Label("ChatGPT Plus/Pro login is not available from this OpenCode server", systemImage: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .font(.footnote)

            Text("Refresh providers or use API Key. Do not type /connect in CodeAgents chat; slash commands there are treated as skills.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else if let authorization = chatGPTOAuthAuthorization {
            chatGPTOAuthCompletionView(authorization)
        } else {
            Label("OpenAI login will open in your browser", systemImage: "safari")
                .foregroundStyle(.secondary)
                .font(.footnote)

            Button {
                Task { await startChatGPTOAuth() }
            } label: {
                savingLabel(isWorking: isStartingChatGPTOAuth, title: "Start ChatGPT Login", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(editsDisabled || isStartingChatGPTOAuth)
            .accessibilityIdentifier("opencode-ai-start-chatgpt-login-button")
        }
    }

    @ViewBuilder
    func chatGPTOAuthCompletionView(_ authorization: OpenCodeProviderOAuthAuthorization) -> some View {
        if let url = URL(string: authorization.url) {
            Link(destination: url) {
                Label("Open OpenAI Login", systemImage: "arrow.up.forward.app")
            }
            .accessibilityIdentifier("opencode-ai-open-chatgpt-login-link")
        } else {
            Text(authorization.url)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundColor(.secondary)
        }

        if let confirmationCode = chatGPTConfirmationCode(from: authorization.instructions) {
            LabeledContent("Code") {
                HStack(spacing: 8) {
                    Text(confirmationCode)
                        .font(.body.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Button {
                        copyChatGPTConfirmationCode(confirmationCode)
                    } label: {
                        Image(systemName: copiedChatGPTConfirmationCode ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(copiedChatGPTConfirmationCode ? "Copied code" : "Copy code")
                }
            }
        } else if !authorization.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(authorization.instructions)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        if authorization.isCodeBased {
            TextField("Authorization Code", text: $chatGPTOAuthCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("opencode-ai-chatgpt-authorization-code-field")
        }

        Button {
            Task { await completeChatGPTOAuth() }
        } label: {
            savingLabel(
                isWorking: isCompletingChatGPTOAuth,
                title: authorization.isCodeBased ? "Complete Login" : "I Finished in Browser",
                systemImage: "checkmark.circle"
            )
        }
        .disabled(editsDisabled || isCompletingChatGPTOAuth || (authorization.isCodeBased && chatGPTOAuthCode.trimmedOpenCodeValue.isEmpty))
        .accessibilityIdentifier("opencode-ai-complete-chatgpt-login-button")

        Button(role: .cancel) {
            resetChatGPTOAuthState()
        } label: {
            Label("Cancel Login", systemImage: "xmark.circle")
        }
        .disabled(isCompletingChatGPTOAuth)

        Text("Finish the browser login, then return here.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    var authRemovalControls: some View {
        if canRemoveProviderAuth, server == nil {
            Button(role: .destructive) {
                removeAuthFromAllServers = true
                confirmRemoveAuth = true
            } label: {
                savingLabel(
                    isWorking: isRemovingAuth,
                    title: "Remove Auth on All Servers",
                    systemImage: "person.2.crop.square.stack.fill"
                )
            }
            .disabled(editsDisabled || isRemovingAuth)
            .accessibilityIdentifier("opencode-ai-remove-auth-all-servers-button")
        } else if canRemoveProviderAuth, let targetServer = authActionTargetServer {
            Button(role: .destructive) {
                removeAuthFromAllServers = false
                confirmRemoveAuth = true
            } label: {
                savingLabel(
                    isWorking: isRemovingAuth,
                    title: "Remove Auth on \(targetServer.name)",
                    systemImage: "person.crop.circle.badge.xmark"
                )
            }
            .disabled(editsDisabled || isRemovingAuth)
            .accessibilityIdentifier("opencode-ai-remove-auth-server-button")
        }
    }

    var modelSection: some View {
        Section {
            if customProviderEnabled {
                TextField("Model ID", text: $profile.customModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-custom-model-id-field")

                TextField("Model Name", text: $profile.customModelName)
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-custom-model-name-field")

                LabeledContent("Default Model") {
                    Text(profile.resolvedModelID ?? "Add model ID")
                        .foregroundColor(.secondary)
                }
            } else if selectedProviderModelChoices.isEmpty {
                TextField("Model ID", text: $profile.modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-model-id-field")
            } else {
                Button {
                    showModelPicker = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedModelTitle)
                                .foregroundColor(.primary)
                            Text(selectedModelSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-model-picker-button")

                if selectedModelUnavailable {
                    Label("Selected model is not available for \(selectedProviderName). Choose another model.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

        } header: {
            Text("Model")
        }
    }

    @ViewBuilder
    var thinkingSection: some View {
        if showsThinkingSection {
            Section {
                Button {
                    showThinkingPicker = true
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedThinkingTitle)
                                .foregroundColor(.primary)
                            Text(selectedThinkingSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(editsDisabled)
                .accessibilityIdentifier("opencode-ai-thinking-picker-button")
            } header: {
                Text("Thinking")
            } footer: {
                Text("Maps to OpenCode model options and optional prompt variant. Default leaves the server’s model default.")
            }
        }
    }

    var advancedSection: some View {
        Section {
            if customProviderEnabled {
                Picker("API Style", selection: npmDriverBinding) {
                    ForEach(OpenCodeProviderNPMDriver.allCases) { driver in
                        Text(driver.displayName).tag(driver)
                    }
                }
                .disabled(editsDisabled)
            }

            DisclosureGroup("Small Model Override", isExpanded: $showAdvancedModels) {
                TextField("Small Model Override", text: $profile.smallModelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(editsDisabled)
                    .accessibilityIdentifier("opencode-ai-small-model-id-field")

                Button {
                    profile.smallModelID = ""
                } label: {
                    Label("Use Selected Model", systemImage: "arrow.down.circle")
                }
                .disabled(editsDisabled || profile.smallModelID.trimmedOpenCodeValue.isEmpty)
                .accessibilityIdentifier("opencode-ai-use-selected-small-model-button")
            }
        } header: {
            Text("Advanced")
        }
    }

    var applySection: some View {
        Section {
            if let server {
                Button {
                    Task { await applySettings(to: server) }
                } label: {
                    savingLabel(isWorking: isApplying, title: "Apply to This Server", systemImage: "checkmark.circle")
                }
                .disabled(isApplying || !canApply)
                .accessibilityIdentifier("opencode-ai-apply-server-button")
            } else {
                Button {
                    confirmApplyAll = true
                } label: {
                    savingLabel(isWorking: isApplying, title: "Apply to All Servers", systemImage: "checkmark.circle")
                }
                .disabled(isApplying || servers.isEmpty || !canApply)
                .accessibilityIdentifier("opencode-ai-apply-all-servers-button")
            }

        } header: {
            Text("Apply")
        } footer: {
            Text("Apply writes the provider and model to OpenCode, then validates the selected model on the target server.")
        }
    }

    @ViewBuilder
    var statusSection: some View {
        if isRefreshingStatus || providerStatus != nil || statusMessage != nil {
            Section {
                if isRefreshingStatus {
                    HStack {
                        ProgressView()
                        Text("Checking OpenCode providers...")
                            .foregroundColor(.secondary)
                    }
                }

                if let statusSourceName, let providerStatus {
                    LabeledContent("Provider list") {
                        Text("\(providerStatus.providers.count) from \(statusSourceName)")
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
}
