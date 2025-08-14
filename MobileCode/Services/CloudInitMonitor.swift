//
//  CloudInitMonitor.swift
//  CodeAgentsMobile
//
//  Purpose: Monitor and update cloud-init status for servers being provisioned
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
class CloudInitMonitor: ObservableObject {
    static let shared = CloudInitMonitor()
    
    private var monitoringTasks: [UUID: Task<Void, Never>] = [:]
    private var modelContext: ModelContext?
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Start monitoring all servers that need cloud-init status checks
    func startMonitoring(modelContext: ModelContext) {
        self.modelContext = modelContext
        
        // Fetch all servers that need monitoring
        do {
            let descriptor = FetchDescriptor<Server>(
                predicate: #Predicate { server in
                    server.providerId != nil && !server.cloudInitComplete
                }
            )
            let servers = try modelContext.fetch(descriptor)
            
            SSHLogger.log("Found \(servers.count) servers needing cloud-init monitoring", level: .info)
            
            // Start monitoring each server
            for server in servers {
                startMonitoring(server: server)
            }
        } catch {
            SSHLogger.log("Failed to fetch servers for monitoring: \(error)", level: .error)
        }
    }
    
    /// Start monitoring a specific server
    func startMonitoring(server: Server) {
        // Cancel any existing monitoring for this server
        stopMonitoring(server: server)
        
        SSHLogger.log("Starting cloud-init monitoring for server: \(server.name)", level: .info)
        
        // Create a new monitoring task
        let task = Task {
            await monitorCloudInit(for: server)
        }
        
        monitoringTasks[server.id] = task
    }
    
    /// Stop monitoring a specific server
    func stopMonitoring(server: Server) {
        if let existingTask = monitoringTasks[server.id] {
            existingTask.cancel()
            monitoringTasks.removeValue(forKey: server.id)
            SSHLogger.log("Stopped cloud-init monitoring for server: \(server.name)", level: .info)
        }
    }
    
    /// Stop all monitoring
    func stopAllMonitoring() {
        for (_, task) in monitoringTasks {
            task.cancel()
        }
        monitoringTasks.removeAll()
        SSHLogger.log("Stopped all cloud-init monitoring", level: .info)
    }
    
    // MARK: - Private Methods
    
    private func monitorCloudInit(for server: Server) async {
        var attempts = 0
        let maxAttempts = 120 // 20 minutes (120 * 10 seconds)
        let checkInterval: UInt64 = 10_000_000_000 // 10 seconds in nanoseconds
        
        // Wait initial time for server to boot
        try? await Task.sleep(nanoseconds: 20_000_000_000) // 20 seconds
        
        while attempts < maxAttempts && !Task.isCancelled {
            attempts += 1
            
            // Update status to checking
            await updateServerStatus(server: server, status: "checking")
            
            // Check cloud-init status
            if let status = await checkCloudInitStatus(for: server) {
                await updateServerStatus(server: server, status: status)
                
                // If done or error, stop monitoring
                if status == "done" || status == "error" {
                    await markCloudInitComplete(server: server, success: status == "done")
                    stopMonitoring(server: server)
                    return
                }
            }
            
            // Wait before next check
            try? await Task.sleep(nanoseconds: checkInterval)
        }
        
        // Timeout reached
        if !Task.isCancelled {
            SSHLogger.log("Cloud-init monitoring timeout for server: \(server.name)", level: .warning)
            await updateServerStatus(server: server, status: "timeout")
            await markCloudInitComplete(server: server, success: false)
            stopMonitoring(server: server)
        }
    }
    
    private func checkCloudInitStatus(for server: Server) async -> String? {
        do {
            let sshService = ServiceManager.shared.sshService
            let session = try await sshService.connect(to: server, purpose: .cloudInit)
            
            // Check cloud-init status
            let output = try await session.execute("sudo cloud-init status")
            
            // Disconnect after checking
            session.disconnect()
            
            // Parse the output
            if output.contains("status: done") {
                SSHLogger.log("Cloud-init complete for server: \(server.name)", level: .info)
                return "done"
            } else if output.contains("status: running") {
                return "running"
            } else if output.contains("status: error") {
                SSHLogger.log("Cloud-init error for server: \(server.name)", level: .error)
                return "error"
            } else {
                return "running" // Default to running if status unclear
            }
        } catch {
            SSHLogger.log("Failed to check cloud-init status for \(server.name): \(error)", level: .warning)
            // Don't return nil immediately - SSH might not be ready yet
            return nil
        }
    }
    
    private func updateServerStatus(server: Server, status: String) async {
        guard let modelContext = modelContext else { return }
        
        server.cloudInitStatus = status
        
        do {
            try modelContext.save()
        } catch {
            SSHLogger.log("Failed to save server status: \(error)", level: .error)
        }
    }
    
    private func markCloudInitComplete(server: Server, success: Bool) async {
        guard let modelContext = modelContext else { return }
        
        server.cloudInitComplete = success
        server.cloudInitStatus = success ? "done" : server.cloudInitStatus
        
        do {
            try modelContext.save()
            SSHLogger.log("Marked cloud-init \(success ? "complete" : "failed") for server: \(server.name)", level: .info)
        } catch {
            SSHLogger.log("Failed to save cloud-init completion: \(error)", level: .error)
        }
    }
}