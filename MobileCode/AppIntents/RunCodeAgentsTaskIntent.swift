//
//  RunCodeAgentsTaskIntent.swift
//  CodeAgentsMobile
//
//  Created by Codex on 2025-07-06.
//

import AppIntents
import SwiftData

struct RunCodeAgentsTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Run CodeAgents Task"
    static var description = IntentDescription(
        "Run a CodeAgents agent remotely and return Claude's final response."
    )
    
    @Parameter(title: "Agent", requestValueDialog: IntentDialog("Which agent should CodeAgents run?"))
    var project: ProjectAppEntity
    
    @Parameter(title: "Prompt", default: "", inputOptions: .init(multiline: true))
    var prompt: String
    
    static var parameterSummary: some ParameterSummary {
        Summary("Run CodeAgents task on \(\.$project)") {
            \.$prompt
        }
    }
    
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = ShortcutProjectStore()
        guard let metadata = store.project(withId: project.id) else {
            return .result(value: "ERROR: Agent not found.")
        }
        let modelContext = await ShortcutPersistenceController.shared.makeContext()
        
        do {
            let response = try await ShortcutClaudeRunner.shared.run(
                metadata: metadata,
                promptInput: prompt,
                timeout: 60,
                modelContext: modelContext
            )
            return .result(value: response)
        } catch let error as ShortcutExecutionError {
            return .result(value: errorMessage(for: error))
        } catch {
            return .result(value: "ERROR: \(error.localizedDescription)")
        }
    }
    
    private func errorMessage(for error: ShortcutExecutionError) -> String {
        switch error {
        case .emptyPrompt:
            return "ERROR: Provide a prompt in the Shortcut before running."
        case .emptyResponse:
            return "ERROR: Claude returned an empty response."
        case .timeout(let seconds):
            return "ERROR: Claude run exceeded \(seconds) seconds."
        case .claudeFailure(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "ERROR: Claude service failed."
            }
            if trimmed.hasPrefix("ERROR:") {
                return trimmed
            }
            return "ERROR: \(trimmed)"
        }
    }
}

extension RunCodeAgentsTaskIntent {
    init(prompt: String) {
        self.init()
        self.prompt = prompt
    }
}
