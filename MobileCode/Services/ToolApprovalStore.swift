//
//  ToolApprovalStore.swift
//  CodeAgentsMobile
//
//  Purpose: Store tool permission decisions for chat-only approvals
//

import Combine
import Foundation

enum ToolApprovalDecision: String, Codable {
    case allow
    case deny
}

enum ToolApprovalScope {
    case once
    case agent
    case global
}

struct ToolApprovalRecord {
    let decision: ToolApprovalDecision
    let scope: ToolApprovalScope
}

final class ToolApprovalStore: ObservableObject {
    static let shared = ToolApprovalStore()

    /// Bumped whenever approvals change so SwiftUI views can refresh.
    @Published private(set) var revision = 0

    private let defaults = UserDefaults.standard
    private let globalAllowKey = "toolApproval.global.allow"
    private let globalDenyKey = "toolApproval.global.deny"
    private let agentAllowKey = "toolApproval.agent.allow"
    private let agentDenyKey = "toolApproval.agent.deny"
    private let agentKnownKey = "toolApproval.agent.known"
    private let agentDefaultsKey = "toolApproval.agent.defaultsApplied"
    private let agentPolicyKey = "toolApproval.agent.policy"

    private let defaultAllowTools = ["Read", "Skill"]
    private let defaultsVersion = 2

    private init() {}

    private func bumpRevision() {
        if Thread.isMainThread {
            revision &+= 1
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.revision &+= 1
            }
        }
    }

    func ensureDefaults(for agentId: UUID) {
        if hasAppliedDefaults(agentId: agentId) {
            return
        }

        var allow = loadAgentToolSet(key: agentAllowKey, agentId: agentId)
        let deny = loadAgentToolSet(key: agentDenyKey, agentId: agentId)
        for tool in defaultAllowTools {
            let normalized = normalize(tool)
            if !deny.contains(normalized) {
                allow.insert(normalized)
            }
        }
        saveAgentToolSet(key: agentAllowKey, agentId: agentId, tools: allow)
        markDefaultsApplied(agentId: agentId)
        bumpRevision()
    }

    func decision(for toolName: String, agentId: UUID) -> ToolApprovalRecord? {
        let tool = normalize(toolName)

        if let policy = agentPolicy(for: agentId) {
            return ToolApprovalRecord(decision: policy, scope: .agent)
        }

        let agentAllow = loadAgentToolSet(key: agentAllowKey, agentId: agentId)
        let agentDeny = loadAgentToolSet(key: agentDenyKey, agentId: agentId)
        if agentDeny.contains(tool) {
            return ToolApprovalRecord(decision: .deny, scope: .agent)
        }
        if agentAllow.contains(tool) {
            return ToolApprovalRecord(decision: .allow, scope: .agent)
        }

        let globalAllow = loadToolSet(key: globalAllowKey)
        let globalDeny = loadToolSet(key: globalDenyKey)
        if globalDeny.contains(tool) {
            return ToolApprovalRecord(decision: .deny, scope: .global)
        }
        if globalAllow.contains(tool) {
            return ToolApprovalRecord(decision: .allow, scope: .global)
        }

        return nil
    }

    func allowedTools(for agentId: UUID) -> Set<String> {
        loadAgentToolSet(key: agentAllowKey, agentId: agentId)
    }

    func deniedTools(for agentId: UUID) -> Set<String> {
        loadAgentToolSet(key: agentDenyKey, agentId: agentId)
    }

    func recordKnownTool(_ toolName: String, agentId: UUID) {
        let trimmed = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var known = loadAgentKnownTools(agentId: agentId)
        let normalized = normalize(trimmed)
        if known.contains(where: { normalize($0) == normalized }) {
            return
        }
        known.append(trimmed)
        saveAgentKnownTools(agentId: agentId, tools: known)
        bumpRevision()
    }

    func knownTools(for agentId: UUID) -> [String] {
        var combined: [String] = defaultAllowTools
        combined.append(contentsOf: loadAgentKnownTools(agentId: agentId))

        var seen = Set<String>()
        var unique: [String] = []
        for name in combined {
            let normalized = normalize(name)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            unique.append(name)
        }

        unique.sort { lhs, rhs in
            let leftDisplay = ToolPermissionInfo.displayName(for: lhs)
            let rightDisplay = ToolPermissionInfo.displayName(for: rhs)
            let primary = leftDisplay.localizedCaseInsensitiveCompare(rightDisplay)
            if primary != .orderedSame {
                return primary == .orderedAscending
            }
            return normalize(lhs) < normalize(rhs)
        }
        return unique
    }

    func setDecision(
        toolName: String,
        decision: ToolApprovalDecision,
        agentId: UUID
    ) {
        setAgentPolicy(nil, agentId: agentId)
        record(decision: decision, scope: .agent, toolName: toolName, agentId: agentId)
    }

    func resetDecision(toolName: String, agentId: UUID) {
        setAgentPolicy(nil, agentId: agentId)
        let normalized = normalize(toolName)
        var allow = loadAgentToolSet(key: agentAllowKey, agentId: agentId)
        var deny = loadAgentToolSet(key: agentDenyKey, agentId: agentId)
        allow.remove(normalized)
        deny.remove(normalized)
        saveAgentToolSet(key: agentAllowKey, agentId: agentId, tools: allow)
        saveAgentToolSet(key: agentDenyKey, agentId: agentId, tools: deny)
        bumpRevision()
    }

    func approvalsPayload(for agentId: UUID) -> (allow: [String], deny: [String]) {
        ensureDefaults(for: agentId)
        if let policy = agentPolicy(for: agentId) {
            if policy == .allow {
                return (["*"], [])
            }
            return ([], ["*"])
        }
        let allow = Array(allowedTools(for: agentId)).sorted()
        let deny = Array(deniedTools(for: agentId)).sorted()
        return (allow, deny)
    }

    func agentPolicy(for agentId: UUID) -> ToolApprovalDecision? {
        let map = defaults.dictionary(forKey: agentPolicyKey) ?? [:]
        guard let raw = map[agentId.uuidString] as? String else { return nil }
        return ToolApprovalDecision(rawValue: raw)
    }

    func setAgentPolicy(_ decision: ToolApprovalDecision?, agentId: UUID) {
        var map = defaults.dictionary(forKey: agentPolicyKey) ?? [:]
        if let decision {
            map[agentId.uuidString] = decision.rawValue
        } else {
            map.removeValue(forKey: agentId.uuidString)
        }
        defaults.set(map, forKey: agentPolicyKey)
        bumpRevision()
    }

    static func normalizeToolName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func record(
        decision: ToolApprovalDecision,
        scope: ToolApprovalScope,
        toolName: String,
        agentId: UUID
    ) {
        let tool = normalize(toolName)

        switch scope {
        case .once:
            return
        case .agent:
            var allow = loadAgentToolSet(key: agentAllowKey, agentId: agentId)
            var deny = loadAgentToolSet(key: agentDenyKey, agentId: agentId)
            switch decision {
            case .allow:
                allow.insert(tool)
                deny.remove(tool)
            case .deny:
                deny.insert(tool)
                allow.remove(tool)
            }
            saveAgentToolSet(key: agentAllowKey, agentId: agentId, tools: allow)
            saveAgentToolSet(key: agentDenyKey, agentId: agentId, tools: deny)
        case .global:
            var allow = loadToolSet(key: globalAllowKey)
            var deny = loadToolSet(key: globalDenyKey)
            switch decision {
            case .allow:
                allow.insert(tool)
                deny.remove(tool)
            case .deny:
                deny.insert(tool)
                allow.remove(tool)
            }
            saveToolSet(key: globalAllowKey, tools: allow)
            saveToolSet(key: globalDenyKey, tools: deny)
        }

        bumpRevision()
    }

    private func normalize(_ toolName: String) -> String {
        toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func hasAppliedDefaults(agentId: UUID) -> Bool {
        let map = defaults.dictionary(forKey: agentDefaultsKey) ?? [:]
        if let version = map[agentId.uuidString] as? Int {
            return version >= defaultsVersion
        }
        if let applied = map[agentId.uuidString] as? Bool {
            // Backwards-compatibility for older installs that stored a Bool.
            return applied && defaultsVersion <= 1
        }
        return false
    }

    private func markDefaultsApplied(agentId: UUID) {
        var map = defaults.dictionary(forKey: agentDefaultsKey) ?? [:]
        map[agentId.uuidString] = defaultsVersion
        defaults.set(map, forKey: agentDefaultsKey)
    }

    private func loadToolSet(key: String) -> Set<String> {
        guard let values = defaults.array(forKey: key) as? [String] else { return [] }
        return Set(values.map { normalize($0) })
    }

    private func saveToolSet(key: String, tools: Set<String>) {
        let values = Array(tools).sorted()
        defaults.set(values, forKey: key)
    }

    private func loadAgentToolSet(key: String, agentId: UUID) -> Set<String> {
        let map = defaults.dictionary(forKey: key) ?? [:]
        guard let values = map[agentId.uuidString] as? [String] else { return [] }
        return Set(values.map { normalize($0) })
    }

    private func saveAgentToolSet(key: String, agentId: UUID, tools: Set<String>) {
        var map = defaults.dictionary(forKey: key) ?? [:]
        map[agentId.uuidString] = Array(tools).sorted()
        defaults.set(map, forKey: key)
    }

    private func loadAgentKnownTools(agentId: UUID) -> [String] {
        let map = defaults.dictionary(forKey: agentKnownKey) ?? [:]
        return map[agentId.uuidString] as? [String] ?? []
    }

    private func saveAgentKnownTools(agentId: UUID, tools: [String]) {
        var map = defaults.dictionary(forKey: agentKnownKey) ?? [:]
        map[agentId.uuidString] = tools
        defaults.set(map, forKey: agentKnownKey)
    }
}
