//
//  AgentDuplicationService.swift
//  CodeAgentsMobile
//
//  Purpose: Orchestrate Duplicate Agent — new path + remapped local config from a source agent.
//

import Foundation
import SwiftData

enum AgentEnvCopyMode: String, Equatable, Sendable {
    case off
    case keysOnly
    case keysAndValues
}

struct DuplicateAgentRequest: Equatable, Sendable {
    let sourceProjectId: UUID
    let displayName: String
    let folderName: String
    var copyRules: Bool = true
    var copySkills: Bool = true
    var copyProjectMCP: Bool = true
    var copyPermissions: Bool = true
    var envMode: AgentEnvCopyMode = .off
    var copyTasks: Bool = false
    var copyAvatar: Bool = true
}

struct DuplicateAgentResult: Sendable {
    let projectId: UUID
    let path: String
    let warnings: [String]
}

enum AgentDuplicationError: LocalizedError, Equatable {
    case sourceNotFound
    case serverNotFound
    case invalidFolderName
    case emptyDisplayName
    case directoryAlreadyExists
    case localPathCollision
    case failedToCreateDirectory
    case noWritePermission
    case localSaveFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "Source agent was not found."
        case .serverNotFound:
            return "Server for this agent was not found."
        case .invalidFolderName:
            return "Invalid folder name."
        case .emptyDisplayName:
            return "Enter an agent name."
        case .directoryAlreadyExists:
            return ProjectServiceError.directoryAlreadyExists.errorDescription
        case .localPathCollision:
            return "An agent with this folder path already exists in the app. Choose a different folder name."
        case .failedToCreateDirectory:
            return ProjectServiceError.failedToCreateDirectory.errorDescription
        case .noWritePermission:
            return ProjectServiceError.noWritePermission.errorDescription
        case .localSaveFailed(let message):
            return message
        }
    }
}

@MainActor
final class AgentDuplicationService {
    static let shared = AgentDuplicationService()

    private let projectService: ProjectService
    private let sshService: SSHService
    private let mcpService: CodingAgentMCPService
    private let skillSyncService: AgentSkillSyncService
    private let approvalStore: ToolApprovalStore
    private let pushManager: PushNotificationsManager

    init(
        projectService: ProjectService? = nil,
        sshService: SSHService? = nil,
        mcpService: CodingAgentMCPService? = nil,
        skillSyncService: AgentSkillSyncService? = nil,
        approvalStore: ToolApprovalStore? = nil,
        pushManager: PushNotificationsManager? = nil
    ) {
        self.projectService = projectService ?? ServiceManager.shared.projectService
        self.sshService = sshService ?? ServiceManager.shared.sshService
        self.mcpService = mcpService ?? .shared
        self.skillSyncService = skillSyncService ?? .shared
        self.approvalStore = approvalStore ?? .shared
        self.pushManager = pushManager ?? .shared
    }

    /// Duplicate `source` into a new agent. Does **not** change the active project.
    func duplicate(
        source: RemoteProject,
        request: DuplicateAgentRequest,
        modelContext: ModelContext
    ) async throws -> DuplicateAgentResult {
        if let fieldError = AgentDuplicationPath.validateRequestFields(
            displayName: request.displayName,
            folderName: request.folderName
        ) {
            throw fieldError
        }

        guard let safeFolder = SSHShellQuoting.sanitizedPathComponent(request.folderName) else {
            throw AgentDuplicationError.invalidFolderName
        }

        guard let server = resolveServer(for: source, modelContext: modelContext) else {
            throw AgentDuplicationError.serverNotFound
        }

        let parentPath = AgentDuplicationPath.parentDirectory(of: source.path)
            ?? server.defaultProjectsPath
            ?? "/root/projects"
        let intendedPath = AgentDuplicationPath.join(parent: parentPath, folderName: safeFolder)

        if localPathExists(intendedPath, serverId: server.id, modelContext: modelContext) {
            throw AgentDuplicationError.localPathCollision
        }

        var createdRemotePath: String?
        do {
            let remotePath = try await projectService.createAgentDirectory(
                folderName: safeFolder,
                parentPath: parentPath,
                on: server,
                allowFallback: false,
                failIfExists: true
            )
            createdRemotePath = remotePath

            let basePath = AgentDuplicationPath.parentDirectory(of: remotePath) ?? parentPath
            let displayName = AgentDuplicationPath.resolvedDisplayName(
                displayName: request.displayName,
                folderName: safeFolder
            )

            let clone = RemoteProject(
                name: safeFolder,
                displayName: displayName,
                serverId: server.id,
                basePath: basePath
            )
            // Ensure path matches verified remote path (RemoteProject init joins base/name).
            clone.path = remotePath
            clone.resetOpenCodeRuntimeState()
            clone.clearClaudeProxyTransportState(clearActiveStreamingMessage: true)
            clone.proxyAgentId = nil
            clone.unreadConversationId = nil
            clone.lastKnownUnreadCursor = 0
            clone.lastReadUnreadCursor = 0
            clone.lastMessageAt = nil
            clone.envVarsPendingSync = false
            clone.envVarsLastSyncedAt = nil
            clone.envVarsLastSyncError = nil
            clone.lastSuccessfulRuntimeProviderRawValue = nil
            clone.lastSuccessfulClaudeProviderRawValue = nil

            modelContext.insert(clone)

            var warnings: [String] = []
            var didCopyPermissions = false

            if request.copyRules {
                do {
                    try await copyRules(from: source, to: clone)
                } catch {
                    warnings.append("Rules: \(error.localizedDescription)")
                }
            }

            if request.copySkills {
                let skillWarnings = await copySkills(
                    from: source,
                    to: clone,
                    modelContext: modelContext
                )
                warnings.append(contentsOf: skillWarnings)
            }

            if request.copyProjectMCP {
                let mcpWarnings = await copyProjectMCP(from: source, to: clone)
                warnings.append(contentsOf: mcpWarnings)
            }

            if request.copyPermissions {
                approvalStore.copyAgentApprovals(from: source.id, to: clone.id)
                didCopyPermissions = true
            }

            if request.envMode != .off {
                let envWarnings = await copyAndSyncEnvironment(
                    from: source,
                    to: clone,
                    mode: request.envMode,
                    modelContext: modelContext
                )
                warnings.append(contentsOf: envWarnings)
            }

            if request.copyTasks {
                let taskWarnings = copyTasks(from: source, to: clone, modelContext: modelContext)
                warnings.append(contentsOf: taskWarnings)
            }

            if request.copyAvatar {
                do {
                    try await AgentAvatarService.shared.copyAvatar(from: source, to: clone)
                } catch {
                    warnings.append("Avatar: \(error.localizedDescription)")
                }
            }

            // After identity may have been created for env, refresh managed scheduler headers.
            if request.copyProjectMCP || request.envMode != .off {
                do {
                    try await mcpService.ensureManagedSchedulerServerIfNeeded(for: clone)
                } catch {
                    // Non-fatal when MCP was already provisioned without identity.
                    if !warnings.contains(where: { $0.hasPrefix("Managed scheduler") }) {
                        warnings.append("Managed scheduler MCP: \(error.localizedDescription)")
                    }
                }
            }

            // Always try to provision avatar MCP on the clone so the agent can set its face.
            do {
                try await mcpService.ensureManagedAvatarServerIfNeeded(for: clone)
            } catch {
                warnings.append("Avatar MCP: \(error.localizedDescription)")
            }

            do {
                try modelContext.save()
            } catch {
                rollbackCloneOwnedLocalState(
                    clone: clone,
                    modelContext: modelContext,
                    clearPermissions: didCopyPermissions
                )
                throw AgentDuplicationError.localSaveFailed(error.localizedDescription)
            }

            ShortcutSyncService.shared.sync(using: modelContext)

            let agentDisplayName = "\(clone.displayTitle)@\(server.name)"
            await pushManager.registerProjectSubscription(
                project: clone,
                server: server,
                agentDisplayName: agentDisplayName
            )

            SSHLogger.log(
                "Duplicated agent \(source.id.uuidString) → \(clone.id.uuidString) path=\(remotePath) warnings=\(warnings.count)",
                level: .info
            )

            return DuplicateAgentResult(
                projectId: clone.id,
                path: remotePath,
                warnings: warnings
            )
        } catch let error as ProjectServiceError {
            if let path = createdRemotePath {
                try? await projectService.removeAgentDirectory(at: path, on: server)
            }
            throw mapProjectError(error)
        } catch let error as AgentDuplicationError {
            if let path = createdRemotePath {
                // Only roll back remote when local insert/save failed hard.
                // Exclusive mkdir means only the creator owns this leaf path.
                if case .localSaveFailed = error {
                    try? await projectService.removeAgentDirectory(at: path, on: server)
                }
            }
            throw error
        } catch {
            if let path = createdRemotePath {
                try? await projectService.removeAgentDirectory(at: path, on: server)
            }
            throw error
        }
    }

    // MARK: - Copy helpers

    private func resolveServer(for project: RemoteProject, modelContext: ModelContext) -> Server? {
        if let server = ServerManager.shared.server(withId: project.serverId) {
            return server
        }
        let serverId = project.serverId
        let descriptor = FetchDescriptor<Server>(
            predicate: #Predicate { server in
                server.id == serverId
            }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func localPathExists(_ path: String, serverId: UUID, modelContext: ModelContext) -> Bool {
        let normalized = PathUtils.normalize(path)
        let descriptor = FetchDescriptor<RemoteProject>(
            predicate: #Predicate { project in
                project.serverId == serverId
            }
        )
        let projects = (try? modelContext.fetch(descriptor)) ?? []
        return projects.contains { PathUtils.normalize($0.path) == normalized }
    }

    private func mapProjectError(_ error: ProjectServiceError) -> AgentDuplicationError {
        switch error {
        case .invalidName:
            return .invalidFolderName
        case .directoryAlreadyExists:
            return .directoryAlreadyExists
        case .failedToCreateDirectory:
            return .failedToCreateDirectory
        case .noWritePermission:
            return .noWritePermission
        case .serverNotFound:
            return .serverNotFound
        case .projectNotFound:
            return .failedToCreateDirectory
        }
    }

    private func copyRules(from source: RemoteProject, to clone: RemoteProject) async throws {
        let session = try await sshService.getConnection(for: source, purpose: .fileOperations)
        guard let content = try await readRulesContent(for: source, session: session) else {
            return
        }

        let writeSession = try await sshService.getConnection(for: clone, purpose: .fileOperations)
        let rulesPath = AgentProjectFileLayout.remotePath(
            projectPath: clone.path,
            relativePath: AgentProjectFileLayout.rulesPrimaryRelativePath
        )
        let rulesDirectory = (rulesPath as NSString).deletingLastPathComponent
        _ = try await writeSession.execute("mkdir -p \(shellEscaped(rulesDirectory))")

        let guarded = CodeAgentsUIRules.ensuringToolCallGuard(in: content)
        guard let data = guarded.data(using: .utf8) else {
            throw SSHError.fileTransferFailed("Invalid rules content")
        }
        let base64 = data.base64EncodedString()
        let writeCommand = "printf '%s' \(shellEscaped(base64)) | base64 -d > \(shellEscaped(rulesPath))"
        _ = try await writeSession.execute(writeCommand)

        try await CodeAgentsUIRules.ensureRulesFile(
            session: writeSession,
            project: clone,
            onlyIfMissing: false
        )
    }

    private func readRulesContent(for project: RemoteProject, session: SSHSession) async throws -> String? {
        let candidates = AgentProjectFileLayout.rulesReadCandidates.map(\.relativePath)
        for relative in candidates {
            let path = AgentProjectFileLayout.remotePath(projectPath: project.path, relativePath: relative)
            do {
                let raw = try await session.readFile(path)
                return raw
            } catch {
                let message = error.localizedDescription.lowercased()
                if message.contains("no such file") || message.contains("cannot open") {
                    continue
                }
                throw error
            }
        }
        return nil
    }

    private func copySkills(
        from source: RemoteProject,
        to clone: RemoteProject,
        modelContext: ModelContext
    ) async -> [String] {
        var warnings: [String] = []
        let sourceId = source.id
        let descriptor = FetchDescriptor<AgentSkillAssignment>(
            predicate: #Predicate { assignment in
                assignment.projectId == sourceId
            }
        )
        let assignments = (try? modelContext.fetch(descriptor)) ?? []
        guard !assignments.isEmpty else { return [] }

        let skills = (try? modelContext.fetch(FetchDescriptor<AgentSkill>())) ?? []
        let skillBySlug = Dictionary(uniqueKeysWithValues: skills.map { ($0.slug, $0) })

        for assignment in assignments {
            let slug = assignment.skillSlug
            var installed = false

            if let skill = skillBySlug[slug] {
                do {
                    try await skillSyncService.installSkill(skill, to: clone)
                    installed = true
                } catch {
                    // Fall through to remote directory copy.
                    SSHLogger.log(
                        "Skill library install failed for \(slug); trying remote copy: \(error.localizedDescription)",
                        level: .debug
                    )
                }
            }

            if !installed {
                do {
                    try await copyRemoteSkillDirectory(slug: slug, from: source, to: clone)
                    installed = true
                } catch {
                    if skillBySlug[slug] == nil {
                        warnings.append("Skill “\(slug)” is not in the local library and was missing on the source agent.")
                    } else {
                        warnings.append("Skill “\(slug)”: \(error.localizedDescription)")
                    }
                }
            }

            // Only assign after remote files exist so Abilities does not show a broken enable.
            if installed {
                modelContext.insert(AgentSkillAssignment(projectId: clone.id, skillSlug: slug))
            }
        }
        return warnings
    }

    /// Best-effort: `cp -a` source `.opencode/skills/<slug>` → clone when local library is missing/fails.
    private func copyRemoteSkillDirectory(slug: String, from source: RemoteProject, to clone: RemoteProject) async throws {
        guard SSHShellQuoting.isSafePathComponent(slug) else {
            throw SkillLibraryError.invalidSkill("Unsafe skill slug")
        }

        let session = try await sshService.getConnection(for: source, purpose: .fileOperations)
        let relative = "\(AgentProjectFileLayout.skillsInstallRelativePath)/\(slug)"
        let sourceSkill = AgentProjectFileLayout.remotePath(projectPath: source.path, relativePath: relative)
        let destRoot = AgentProjectFileLayout.remotePath(
            projectPath: clone.path,
            relativePath: AgentProjectFileLayout.skillsInstallRelativePath
        )
        let destSkill = "\(destRoot)/\(slug)"

        let qSource = SSHShellQuoting.quote(sourceSkill)
        let qDestRoot = SSHShellQuoting.quote(destRoot)
        let qDest = SSHShellQuoting.quote(destSkill)

        let exists = try await session.execute("test -d \(qSource) && echo EXISTS || echo MISSING")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard exists == "EXISTS" else {
            throw SkillLibraryError.invalidSkill("Missing remote skill folder for \(slug)")
        }

        _ = try await session.execute("mkdir -p -- \(qDestRoot)")
        // Same server: remote-to-remote copy (source and clone share SSH host).
        _ = try await session.execute("rm -rf -- \(qDest) && cp -a -- \(qSource) \(qDest)")
    }

    private func copyProjectMCP(from source: RemoteProject, to clone: RemoteProject) async -> [String] {
        var warnings: [String] = []
        let configurations: [String: OpenCodeMCPServerConfiguration]
        do {
            configurations = try await mcpService.projectServerConfigurations(for: source)
        } catch {
            return ["MCP: \(error.localizedDescription)"]
        }

        for (name, configuration) in configurations.sorted(by: { $0.key < $1.key }) {
            if MCPServer.isManagedServer(name) {
                continue
            }
            // Write the full OpenCode configuration so oauth / timeout / enabled are not dropped
            // by the MCPServer round-trip used by the generic addServer path.
            if let headers = configuration.headers, headersContainSourceHints(headers, source: source) {
                warnings.append("MCP “\(name)” headers may still reference the source agent; review after open.")
            }
            do {
                try await mcpService.addServerConfiguration(
                    named: name,
                    configuration: configuration,
                    scope: .project,
                    for: clone,
                    allowManaged: false
                )
            } catch {
                warnings.append("MCP “\(name)”: \(error.localizedDescription)")
            }
        }

        do {
            try await mcpService.ensureManagedSchedulerServerIfNeeded(for: clone)
        } catch {
            warnings.append("Managed scheduler MCP: \(error.localizedDescription)")
        }

        return warnings
    }

    /// Delete clone-owned SwiftData rows and optional UserDefaults approvals after a failed final save.
    private func rollbackCloneOwnedLocalState(
        clone: RemoteProject,
        modelContext: ModelContext,
        clearPermissions: Bool
    ) {
        let cloneId = clone.id

        let skillDescriptor = FetchDescriptor<AgentSkillAssignment>(
            predicate: #Predicate { assignment in
                assignment.projectId == cloneId
            }
        )
        for row in (try? modelContext.fetch(skillDescriptor)) ?? [] {
            modelContext.delete(row)
        }

        let envDescriptor = FetchDescriptor<AgentEnvironmentVariable>(
            predicate: #Predicate { item in
                item.projectId == cloneId
            }
        )
        for row in (try? modelContext.fetch(envDescriptor)) ?? [] {
            modelContext.delete(row)
        }

        let taskDescriptor = FetchDescriptor<AgentScheduledTask>(
            predicate: #Predicate { task in
                task.projectId == cloneId
            }
        )
        for row in (try? modelContext.fetch(taskDescriptor)) ?? [] {
            modelContext.delete(row)
        }

        if clearPermissions {
            approvalStore.removeAgentApprovals(for: cloneId)
        }

        modelContext.delete(clone)
        try? modelContext.save()
    }

    private func headersContainSourceHints(_ headers: [String: String], source: RemoteProject) -> Bool {
        let path = source.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentId = source.proxyAgentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let projectId = source.id.uuidString
        for value in headers.values {
            if !path.isEmpty, value.contains(path) { return true }
            if !agentId.isEmpty, value.contains(agentId) { return true }
            if value.localizedCaseInsensitiveContains(projectId) { return true }
        }
        return false
    }

    /// Copy env rows locally, then ensure a **new** daemon identity and push replaceEnv for the clone only.
    private func copyAndSyncEnvironment(
        from source: RemoteProject,
        to clone: RemoteProject,
        mode: AgentEnvCopyMode,
        modelContext: ModelContext
    ) async -> [String] {
        guard mode != .off else { return [] }

        let sourceId = source.id
        let descriptor = FetchDescriptor<AgentEnvironmentVariable>(
            predicate: #Predicate { item in
                item.projectId == sourceId
            }
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        guard !rows.isEmpty else { return [] }

        var copied: [AgentEnvironmentVariable] = []
        for row in rows {
            let value: String
            switch mode {
            case .off:
                continue
            case .keysOnly:
                value = ""
            case .keysAndValues:
                value = row.value
            }
            let item = AgentEnvironmentVariable(
                projectId: clone.id,
                key: row.key,
                value: value,
                isEnabled: row.isEnabled
            )
            modelContext.insert(item)
            copied.append(item)
        }

        clone.envVarsPendingSync = true
        clone.envVarsLastSyncError = nil

        do {
            let agentId = try await AgentIdentityService.shared.ensureAgentId(
                for: clone,
                modelContext: modelContext
            )
            let payload = copied.map {
                AgentEnvItem(key: $0.key, value: $0.value, enabled: $0.isEnabled)
            }
            try await AgentEnvService.shared.replaceEnv(agentId: agentId, env: payload, project: clone)
            clone.envVarsPendingSync = false
            clone.envVarsLastSyncedAt = Date()
            clone.envVarsLastSyncError = nil
            return []
        } catch {
            clone.envVarsPendingSync = true
            clone.envVarsLastSyncError = error.localizedDescription
            return ["Environment: saved locally; daemon sync failed — \(error.localizedDescription)"]
        }
    }

    private func copyTasks(
        from source: RemoteProject,
        to clone: RemoteProject,
        modelContext: ModelContext
    ) -> [String] {
        let sourceId = source.id
        let descriptor = FetchDescriptor<AgentScheduledTask>(
            predicate: #Predicate { task in
                task.projectId == sourceId
            }
        )
        let tasks = (try? modelContext.fetch(descriptor)) ?? []
        for task in tasks {
            modelContext.insert(
                AgentScheduledTask(
                    projectId: clone.id,
                    title: task.title,
                    prompt: task.prompt,
                    isEnabled: false,
                    timeZoneId: task.timeZoneId,
                    frequency: task.frequency,
                    interval: task.interval,
                    weekdayMask: task.weekdayMask,
                    monthlyMode: task.monthlyMode,
                    dayOfMonth: task.dayOfMonth,
                    ordinalWeek: task.ordinalWeek,
                    ordinalWeekday: task.ordinalWeekday,
                    monthOfYear: task.monthOfYear,
                    timeOfDayMinutes: task.timeOfDayMinutes,
                    nextRunAt: nil,
                    lastRunAt: nil,
                    remoteId: nil
                )
            )
        }
        if !tasks.isEmpty {
            return ["Scheduled tasks were copied disabled. Review prompts before enabling."]
        }
        return []
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
