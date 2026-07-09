//
//  OpenCodeChatModelChangeSheet.swift
//  CodeAgentsMobile
//
//  Purpose: Chat overflow “Change Model…” — model + thinking for the active server
//

import SwiftUI

/// Focused model/thinking editor opened from chat. Provider connection stays in AI Providers.
struct OpenCodeChatModelChangeSheet: View {
    let server: Server

    @Environment(\.dismiss) private var dismiss
    @StateObject private var providerService = OpenCodeProviderService.shared

    @State private var profile = OpenCodeAIProviderProfile.defaults()
    @State private var usesGlobalDefaults = true
    @State private var providerStatus: OpenCodeProviderStatus?
    @State private var statusSourceName: String?
    @State private var path = NavigationPath()
    @State private var modelSearchText = ""
    @State private var isRefreshing = false
    @State private var isApplying = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showFullProviders = false

    private let settingsStore = OpenCodeAIProviderSettingsStore()

    private enum Step: Hashable {
        case model
        case thinking
    }

    var body: some View {
        NavigationStack(path: $path) {
            homeList
                .navigationTitle("Model")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                            .accessibilityIdentifier("chat-model-change-close-button")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await refreshStatus() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(isRefreshing)
                        .accessibilityIdentifier("chat-model-change-refresh-button")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if path.isEmpty {
                        stickyApplyBar
                    }
                }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .model:
                        modelStep
                    case .thinking:
                        thinkingStep
                    }
                }
        }
        .onAppear {
            loadProfile()
            loadCachedStatus()
            Task { await refreshStatus() }
        }
        .sheet(isPresented: $showFullProviders, onDismiss: {
            loadProfile()
            Task { await refreshStatus() }
        }) {
            NavigationStack {
                OpenCodeAIProviderSettingsView(server: server, navigationTitle: "Server AI")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showFullProviders = false }
                        }
                    }
            }
        }
        .alert("Model", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
    }

    private var homeList: some View {
        List {
            Section {
                Button {
                    modelSearchText = ""
                    path.append(Step.model)
                } label: {
                    currentCard
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-model-change-card-button")
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            } header: {
                Text("Current")
            } footer: {
                Text("Change model or thinking for \(server.name). Switch provider or reconnect from Providers.")
            }

            Section {
                Button {
                    showFullProviders = true
                } label: {
                    Label("Providers & connection…", systemImage: "sparkles")
                }
                .accessibilityIdentifier("chat-model-open-providers-button")
            }

            if isRefreshing || statusMessage != nil {
                Section {
                    if isRefreshing {
                        HStack {
                            ProgressView()
                            Text("Loading models…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Current card

    private var currentCard: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: providerSymbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(providerDisplayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(server.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(modelSummaryLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "cpu")
                        .foregroundStyle(.secondary)
                }

                if showsThinking {
                    Label {
                        Text("Thinking · \(thinkingTitle)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "brain")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 4)

            Text("Change model…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
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

    private var stickyApplyBar: some View {
        VStack(spacing: 0) {
            Divider()
            PrimaryGlassButton(action: {
                Task { await applyToServer() }
            }) {
                if isApplying {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Apply to \(server.name)", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isApplying || !canApply)
            .accessibilityIdentifier("chat-model-apply-button")
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(.bar)
        }
    }

    // MARK: - Change flow

    private var modelStep: some View {
        Group {
            if profile.isCustomProvider {
                Form {
                    Section {
                        TextField("Model ID", text: $profile.customModelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("chat-model-custom-model-id-field")
                        TextField("Model Name", text: $profile.customModelName)
                            .accessibilityIdentifier("chat-model-custom-model-name-field")
                    } footer: {
                        Text("Custom endpoint model id.")
                    }
                }
            } else if modelChoices.isEmpty {
                Form {
                    Section {
                        TextField("Model ID", text: $profile.modelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("chat-model-id-field")
                    } footer: {
                        Text(
                            providerStatus == nil
                                ? "Catalog not loaded yet. Enter a model id or go back and refresh."
                                : "No models reported for \(providerDisplayName). Enter a model id."
                        )
                    }
                }
            } else {
                List(filteredModelChoices) { choice in
                    Button {
                        selectModel(choice)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice.id)
                                    .foregroundStyle(.primary)
                                Text(modelChoiceSubtitle(choice))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                            if isSelectedModel(choice) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .accessibilityIdentifier("chat-model-choice-\(choice.id)")
                }
                .searchable(
                    text: $modelSearchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search models"
                )
            }
        }
        .navigationTitle("Choose Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if showsThinking && modelStepComplete {
                    Button("Continue") {
                        path.append(Step.thinking)
                    }
                    .disabled(!modelStepComplete)
                    .accessibilityIdentifier("chat-model-continue-thinking-button")
                } else {
                    Button("Done") {
                        path = NavigationPath()
                    }
                    .disabled(!modelStepComplete)
                    .accessibilityIdentifier("chat-model-done-button")
                }
            }
        }
    }

    private var thinkingStep: some View {
        List(thinkingChoices) { choice in
            Button {
                profile.variant = choice.id
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(choice.title)
                            .foregroundStyle(.primary)
                        if let subtitle = choice.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if choice.id.caseInsensitiveCompare(profile.variant) == .orderedSame {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .accessibilityIdentifier(
                "chat-thinking-choice-\(choice.id.isEmpty ? "default" : choice.id)"
            )
        }
        .navigationTitle("Thinking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    path = NavigationPath()
                }
                .accessibilityIdentifier("chat-thinking-done-button")
            }
        }
    }

    // MARK: - Data

    private var providerDisplayName: String {
        if profile.isCustomProvider {
            let name = profile.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Other" : name
        }
        return OpenCodeProviderPreset.name(for: profile.normalizedProviderID) ?? profile.trimmedProviderName
    }

    private var providerSymbol: String {
        profile.isCustomProvider ? "plus.circle" : OpenCodeProviderPreset.symbol(for: profile.normalizedProviderID)
    }

    private var modelSummaryLine: String {
        guard let modelID = profile.resolvedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty else {
            return "No model selected"
        }
        if let choice = selectedModelChoice,
           choice.modelName.caseInsensitiveCompare(choice.modelID) != .orderedSame {
            return "\(choice.modelName) · \(modelID)"
        }
        return modelID
    }

    private var modelChoices: [OpenCodeModelChoice] {
        guard !profile.normalizedProviderID.isEmpty else { return [] }
        return providerStatus?.modelChoices(for: profile.normalizedProviderID) ?? []
    }

    private var filteredModelChoices: [OpenCodeModelChoice] {
        let query = modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return modelChoices }
        return modelChoices.filter {
            $0.modelName.localizedCaseInsensitiveContains(query)
                || $0.modelID.localizedCaseInsensitiveContains(query)
                || $0.providerName.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedModelChoice: OpenCodeModelChoice? {
        guard let modelID = profile.resolvedModelID else { return nil }
        return modelChoices.first {
            $0.id.caseInsensitiveCompare(modelID) == .orderedSame
                || $0.modelID.caseInsensitiveCompare(modelID) == .orderedSame
        }
    }

    private var thinkingChoices: [OpenCodeThinkingChoice] {
        if let selectedModelChoice {
            return OpenCodeThinkingSupport.choices(
                for: selectedModelChoice,
                providerID: profile.normalizedProviderID
            )
        }
        return OpenCodeThinkingSupport.fallbackChoices(
            providerID: profile.normalizedProviderID,
            supportsReasoning: false
        )
    }

    private var showsThinking: Bool {
        !profile.isCustomProvider
            && (selectedModelChoice?.supportsReasoning == true || thinkingChoices.count > 1)
    }

    private var thinkingTitle: String {
        let current = profile.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = thinkingChoices.first(where: { $0.id.caseInsensitiveCompare(current) == .orderedSame }) {
            return match.title
        }
        return OpenCodeThinkingChoice.automatic.title
    }

    private var modelStepComplete: Bool {
        guard let modelID = profile.resolvedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !modelID.isEmpty
    }

    private var canApply: Bool {
        profile.isReadyToSave && modelStepComplete
    }

    private func isSelectedModel(_ choice: OpenCodeModelChoice) -> Bool {
        choice.id.caseInsensitiveCompare(profile.modelID) == .orderedSame
            || (profile.resolvedModelID.map { choice.id.caseInsensitiveCompare($0) == .orderedSame } ?? false)
    }

    private func modelChoiceSubtitle(_ choice: OpenCodeModelChoice) -> String {
        var parts: [String] = []
        if choice.modelName.caseInsensitiveCompare(choice.modelID) != .orderedSame {
            parts.append(choice.modelName)
        }
        if choice.supportsReasoning {
            parts.append("supports thinking")
        }
        return parts.isEmpty ? choice.providerName : parts.joined(separator: " · ")
    }

    private func selectModel(_ choice: OpenCodeModelChoice) {
        let previousModelID = profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSmall = profile.smallModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldClearSmall = previousSmall.isEmpty || previousSmall == previousModelID

        profile.modelID = choice.id
        if shouldClearSmall {
            profile.smallModelID = ""
        }
        if !choice.supportsReasoning {
            profile.variant = ""
        } else {
            repairThinking(for: choice)
        }
    }

    private func repairThinking(for model: OpenCodeModelChoice) {
        let current = profile.variant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }
        let valid = OpenCodeThinkingSupport.choices(for: model, providerID: profile.normalizedProviderID)
        let ok = valid.contains { $0.id.caseInsensitiveCompare(current) == .orderedSame }
        if !ok {
            profile.variant = ""
        }
    }

    private func loadProfile() {
        let override = settingsStore.serverOverride(for: server.id)
        usesGlobalDefaults = override.usesGlobalDefaults
        profile = settingsStore.effectiveProfile(for: server.id)
    }

    private func loadCachedStatus() {
        guard providerStatus == nil,
              let cached = providerService.cachedStatus(for: server.id) else { return }
        providerStatus = cached.status
        statusSourceName = "\(cached.serverName) (cached)"
    }

    @MainActor
    private func refreshStatus() async {
        if providerStatus == nil {
            loadCachedStatus()
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            providerStatus = try await providerService.status(for: server)
            statusSourceName = server.name
            if let choice = selectedModelChoice {
                repairThinking(for: choice)
            }
        } catch {
            if providerStatus == nil {
                statusMessage = "Model list unavailable. You can still enter a model id."
            } else {
                statusMessage = "Using cached model list. Live refresh failed."
            }
        }
    }

    @MainActor
    private func applyToServer() async {
        isApplying = true
        defer { isApplying = false }

        do {
            let normalized = profile.normalizedForStorage()
            guard normalized.isReadyToSave, modelStepComplete else {
                throw OpenCodeProviderServiceError.invalidInput
            }

            if usesGlobalDefaults {
                try settingsStore.saveGlobalProfile(normalized)
            } else {
                try settingsStore.saveServerOverride(
                    OpenCodeServerAIProviderOverride(usesGlobalDefaults: false, profile: normalized),
                    for: server.id
                )
            }

            try await providerService.applyAIProviderProfile(normalized, to: server)
            statusMessage = "Applied on \(server.name)."
            // Brief success then close so chat menu summary updates on next open.
            try? await Task.sleep(nanoseconds: 400_000_000)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

#Preview {
    OpenCodeChatModelChangeSheet(
        server: Server(name: "op", host: "example.com", port: 22, username: "user")
    )
}
