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
    private let approvalStore: ToolApprovalStore
    private let pushManager: PushNotificationsManager

    init(
        projectService: ProjectService? = nil,
        sshService: SSHService? = nil,
        mcpService: CodingAgentMCPService? = nil,
        skillSyncService _: AgentSkillSyncService? = nil,
        approvalStore: ToolApprovalStore? = nil,
        pushManager: PushNotificationsManager? = nil
    ) {
        self.projectService = projectService ?? ServiceManager.shared.projectService
        self.sshService = sshService ?? ServiceManager.shared.sshService
        self.mcpService = mcpService ?? .shared
        self.approvalStore = approvalStore ?? .shared
        self.pushManager = pushManager ?? .shared
    }

    /// Duplicate `source` into a new agent. Does **not** change the active project.
    ///
    /// Fast path: one remote bootstrap script (mkdir + server-local `cp` for rules/skills/avatar),
    /// one batched `opencode.json` write for MCP, then local SwiftData. Push registration runs after return.
    func duplicate(
        source: RemoteProject,
        request: DuplicateAgentRequest,
        modelContext: ModelContext,
        onProgress: ((DuplicateAgentProgress) -> Void)? = nil
    ) async throws -> DuplicateAgentResult {
        let progress = onProgress ?? { _ in }
        progress(.preparing)

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
            progress(.creatingFolder)
            // Pooled file-ops session shared for bootstrap + rules guard.
            let session = try await sshService.getConnection(for: source, purpose: .fileOperations)

            let bootstrap = AgentDuplicationRemoteBootstrap.shellScript(
                sourcePath: source.path,
                clonePath: intendedPath,
                copyRules: request.copyRules,
                copySkills: request.copySkills,
                copyAvatarImage: request.copyAvatar
            )
            progress(.copyingWorkspace)
            let bootstrapOutput = try await session.execute(bootstrap)
            switch AgentDuplicationRemoteBootstrap.interpretOutput(bootstrapOutput) {
            case .failure(let error):
                throw error
            case .success:
                break
            }

            let remotePath = intendedPath
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

            // Rules tool-call guard (single remote command after bootstrap copy).
            if request.copyRules {
                do {
                    try await CodeAgentsUIRules.ensureRulesFile(
                        session: session,
                        project: clone,
                        onlyIfMissing: false
                    )
                } catch {
                    warnings.append("Rules: \(error.localizedDescription)")
                }
            }

            if request.copySkills {
                assignSkillsLocally(from: source, to: clone, modelContext: modelContext)
            }

            progress(.configuringTools)

            // Batch MCP: user servers (optional) + managed scheduler + avatar in one write.
            let mcpWarnings = await configureMCPBatched(
                from: source,
                to: clone,
                copyProjectMCP: request.copyProjectMCP
            )
            warnings.append(contentsOf: mcpWarnings)

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
                    try await AgentAvatarService.shared.copyAvatar(
                        from: source,
                        to: clone,
                        imageAlreadyCopied: true
                    )
                } catch {
                    warnings.append("Avatar: \(error.localizedDescription)")
                }
            }

            progress(.finishing)

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

            // Defer push — not required to show "Agent Created".
            let agentDisplayName = "\(clone.displayTitle)@\(server.name)"
            let cloneId = clone.id
            Task { @MainActor in
                await self.pushManager.registerProjectSubscription(
                    project: clone,
                    server: server,
                    agentDisplayName: agentDisplayName
                )
                SSHLogger.log(
                    "Deferred push registration for duplicated agent \(cloneId.uuidString)",
                    level: .debug
                )
            }

            SSHLogger.log(
                "Duplicated agent \(source.id.uuidString) → \(clone.id.uuidString) path=\(remotePath) warnings=\(warnings.count) (fast path)",
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
        case .failedToCreateDirectory, .failedToDeleteDirectory:
            return .failedToCreateDirectory
        case .noWritePermission:
            return .noWritePermission
        case .serverNotFound:
            return .serverNotFound
        case .projectNotFound:
            return .failedToCreateDirectory
        }
    }

    /// Mirror skill assignment rows only — remote skill trees were copied in bootstrap via `cp -a`.
    private func assignSkillsLocally(
        from source: RemoteProject,
        to clone: RemoteProject,
        modelContext: ModelContext
    ) {
        let sourceId = source.id
        let descriptor = FetchDescriptor<AgentSkillAssignment>(
            predicate: #Predicate { assignment in
                assignment.projectId == sourceId
            }
        )
        let assignments = (try? modelContext.fetch(descriptor)) ?? []
        for assignment in assignments {
            modelContext.insert(AgentSkillAssignment(projectId: clone.id, skillSlug: assignment.skillSlug))
        }
    }

    /// One load of source MCP + one write of clone config (user servers + managed scheduler/avatar).
    private func configureMCPBatched(
        from source: RemoteProject,
        to clone: RemoteProject,
        copyProjectMCP: Bool
    ) async -> [String] {
        var warnings: [String] = []
        var configurations: [String: OpenCodeMCPServerConfiguration] = [:]

        if copyProjectMCP {
            do {
                let sourceConfigs = try await mcpService.projectServerConfigurations(for: source)
                for (name, configuration) in sourceConfigs {
                    if MCPServer.isManagedServer(name) { continue }
                    if let headers = configuration.headers, headersContainSourceHints(headers, source: source) {
                        warnings.append("MCP “\(name)” headers may still reference the source agent; review after open.")
                    }
                    configurations[name] = configuration
                }
            } catch {
                warnings.append("MCP: \(error.localizedDescription)")
            }
        }

        // Always provision managed tools so the clone can schedule tasks and set an avatar.
        if let scheduler = mcpService.managedSchedulerConfiguration(for: clone) {
            configurations[MCPServer.managedSchedulerServerName] = scheduler
        }
        configurations[MCPServer.managedAvatarServerName] = mcpService.managedAvatarConfiguration(for: clone)

        do {
            try await mcpService.deployManagedAvatarScript(for: clone)
        } catch {
            warnings.append("Avatar MCP script: \(error.localizedDescription)")
        }

        do {
            try await mcpService.writeProjectServerConfigurations(
                configurations,
                for: clone,
                activateLive: false
            )
        } catch {
            warnings.append("MCP config: \(error.localizedDescription)")
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

}
