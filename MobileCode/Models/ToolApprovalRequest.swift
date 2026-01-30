//
//  ToolApprovalRequest.swift
//  CodeAgentsMobile
//
//  Purpose: Represents a pending tool permission request from the proxy
//

import Foundation

struct ToolApprovalRequest: Identifiable {
    let id: String
    let toolName: String
    let input: [String: Any]
    let suggestions: [String]
    let blockedPath: String?
    let agentId: UUID
}
