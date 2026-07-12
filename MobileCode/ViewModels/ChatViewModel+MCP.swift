//
//  ChatViewModel+MCP.swift
//  CodeAgentsMobile
//
//  Purpose: ChatViewModel MCP cache & deferred server fetch
//

import SwiftUI
import Observation
import SwiftData

extension ChatViewModel {
    /// Just-in-time work before an OpenCode prompt. MCP listing is intentionally skipped:
    /// OpenCode send does not use the app-side server list (tools come from remote `opencode.json`).
    /// MCP refresh stays on post-ready deferred startup and explicit Abilities actions.
    func ensureSendTimeSetup(for project: RemoteProject, includeRules: Bool) async {
        let plan = ChatMCPServerSetupPlanner.plan(
            cachedServerCount: cachedMCPServers.count,
            isInvalidated: isMCPCacheInvalidated,
            lastFetchedAt: mcpCacheLastFetchedAt,
            now: Date(),
            staleInterval: mcpCacheStaleInterval,
            includeRules: includeRules,
            allowMCPFetch: false
        )
        if plan.shouldFetchMCPServers {
            await fetchMCPServersForSetupIfCurrent(project: project, operation: "chat.ensureSendTimeMCPServers")
        }
        guard plan.shouldEnsureRules else { return }
        do {
            let session = try await ServiceManager.shared.sshService.getConnection(
                for: project,
                purpose: .fileOperations
            )
            try await CodeAgentsUIRules.ensureRulesFile(
                session: session,
                project: project,
                onlyIfMissing: true
            )
        } catch {
            SSHLogger.log(
                "Failed to ensure CodeAgents UI rules for project \(project.id): \(error.localizedDescription)",
                level: .warning
            )
        }
    }

    func refreshMCPServersAfterChatReadyIfNeeded(project: RemoteProject, now: Date = Date()) async {
        let plan = ChatMCPServerSetupPlanner.plan(
            cachedServerCount: cachedMCPServers.count,
            isInvalidated: isMCPCacheInvalidated,
            lastFetchedAt: mcpCacheLastFetchedAt,
            now: now,
            staleInterval: mcpCacheStaleInterval,
            includeRules: false
        )
        guard plan.shouldFetchMCPServers else { return }
        await fetchMCPServersForSetupIfCurrent(project: project, operation: "chat.postReadyMCPServers")
    }

    func fetchMCPServersForSetupIfCurrent(project: RemoteProject, operation: String) async {
        guard projectId == project.id else { return }

        let timingStart = DispatchTime.now().uptimeNanoseconds
        var timingStatus = ChatRecoveryTiming.Status.complete
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project.id.uuidString,
                operation: operation,
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "cachedServers": .count(cachedMCPServers.count),
                    "invalidated": .flag(isMCPCacheInvalidated),
                    "status": .status(timingStatus)
                ]
            )
        }

        await fetchMCPServers()
        guard projectId == project.id else {
            timingStatus = .skipped
            return
        }
    }


    /// Fetch MCP servers for the current project
    @MainActor
    func fetchMCPServers() async {
        guard let project = ProjectContext.shared.activeProject else {
            print("📝 fetchMCPServers: No active agent")
            return
        }
        
        guard !isFetchingMCPServers else {
            print("📝 fetchMCPServers: Already fetching")
            return
        }
        
        isFetchingMCPServers = true
        defer { isFetchingMCPServers = false }

        let timingStart = DispatchTime.now().uptimeNanoseconds
        var fetchedCount = cachedMCPServers.count
        var connectedCount = cachedMCPServers.filter { $0.status == .connected }.count
        var timingStatus = ChatRecoveryTiming.Status.complete
        defer {
            ChatRecoveryTiming.log(
                runtime: timingRuntimeName(for: project),
                projectID: project.id.uuidString,
                operation: "chat.fetchMCPServers",
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - timingStart,
                metadata: [
                    "cachedServers": .count(cachedMCPServers.count),
                    "connectedServers": .count(connectedCount),
                    "fetchedServers": .count(fetchedCount),
                    "status": .status(timingStatus)
                ]
            )
        }
        
        do {
            let fetchedServers = try await mcpService.fetchServers(for: project)
            guard !Task.isCancelled, projectId == project.id else {
                timingStatus = .cancelled
                return
            }
            cachedMCPServers = fetchedServers
            mcpCacheLastFetchedAt = Date()
            isMCPCacheInvalidated = false
            fetchedCount = cachedMCPServers.count
            print("📝 Fetched and cached \(cachedMCPServers.count) MCP servers")
            
            // Log connected servers
            let connectedServers = cachedMCPServers.filter { $0.status == .connected }
            connectedCount = connectedServers.count
            print("📝 Connected MCP servers: \(connectedServers.map { $0.name }.joined(separator: ", "))")
        } catch {
            timingStatus = .failed
            print("⚠️ Failed to fetch MCP servers: \(error)")
            cachedMCPServers = []
            mcpCacheLastFetchedAt = nil
            isMCPCacheInvalidated = true
            fetchedCount = 0
            connectedCount = 0
        }
    }

    
    /// Refresh MCP servers (useful after configuration changes)
    func refreshMCPServers() async {
        cachedMCPServers = []
        mcpCacheLastFetchedAt = nil
        isMCPCacheInvalidated = true
        await fetchMCPServers()
    }

    
    /// Invalidate MCP cache (call when configuration changes)
    func invalidateMCPCache() {
        cachedMCPServers = []
        mcpCacheLastFetchedAt = nil
        isMCPCacheInvalidated = true
        print("📝 MCP cache invalidated")
    }

    
    /// Handle MCP configuration changed notification
    @objc func handleMCPConfigurationChanged() {
        print("📝 MCP configuration changed notification received")
        print("📝 Current cached MCP servers before invalidation: \(cachedMCPServers.count)")
        invalidateMCPCache()
    }
}
