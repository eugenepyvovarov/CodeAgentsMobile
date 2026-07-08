//
//  AgentDaemonAuthService.swift
//  CodeAgentsMobile
//
//  Purpose: Auth-method preference for the agent daemon (:8787) Anthropic credentials.
//           Extracted from ClaudeCodeService so installer/task provider UI no longer
//           depend on the legacy Claude chat stack.
//

import Foundation

/// Authentication method for Anthropic credentials used by the agent daemon.
enum ClaudeAuthMethod: String, CaseIterable {
    case apiKey = "apiKey"
    case token = "token"
}

@MainActor
protocol AgentDaemonAuthServing: AnyObject {
    func getCurrentAuthMethod() -> ClaudeAuthMethod
    func setAuthMethod(_ method: ClaudeAuthMethod)
}

/// Persists how Anthropic credentials are supplied to the agent daemon `.env`
/// (`ANTHROPIC_API_KEY` vs `CLAUDE_CODE_OAUTH_TOKEN`).
@MainActor
final class AgentDaemonAuthService: AgentDaemonAuthServing {
    static let shared = AgentDaemonAuthService()

    /// Historical UserDefaults key (kept for migration compatibility).
    static let authMethodKey = "claudeAuthMethod"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func getCurrentAuthMethod() -> ClaudeAuthMethod {
        let rawValue = userDefaults.string(forKey: Self.authMethodKey) ?? ClaudeAuthMethod.apiKey.rawValue
        return ClaudeAuthMethod(rawValue: rawValue) ?? .apiKey
    }

    func setAuthMethod(_ method: ClaudeAuthMethod) {
        userDefaults.set(method.rawValue, forKey: Self.authMethodKey)
    }
}
