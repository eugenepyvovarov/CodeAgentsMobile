//
//  CloudProviderProtocol.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-08-12.
//

import Foundation

// MARK: - Cloud Server Models

struct CloudServer: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let status: String
    let publicIP: String?
    let privateIP: String?
    let region: String
    let imageInfo: String
    let sizeInfo: String
    let providerType: String
}

// MARK: - SSH Key Models

struct CloudSSHKey: Identifiable, Codable {
    let id: String
    let name: String
    let fingerprint: String
    let publicKey: String
}

// MARK: - Cloud Provider Protocol

protocol CloudProviderProtocol {
    var providerType: String { get }
    var apiToken: String { get set }
    
    // Authentication
    func validateToken() async throws -> Bool
    
    // Server Management
    func listServers() async throws -> [CloudServer]
    func getServer(id: String) async throws -> CloudServer?
    
    // SSH Key Management
    func listSSHKeys() async throws -> [CloudSSHKey]
    func addSSHKey(name: String, publicKey: String) async throws -> CloudSSHKey
    func deleteSSHKey(id: String) async throws
    
    // Server Creation
    func createServer(name: String, region: String, size: String, image: String, sshKeyIds: [String], userData: String?) async throws -> CloudServer
    
    // Server Options (for server creation UI)
    func listRegions() async throws -> [(id: String, name: String)]
    func listSizes() async throws -> [(id: String, name: String, description: String)]
    func listImages() async throws -> [(id: String, name: String)]
}

// MARK: - Cloud Provider Errors

enum CloudProviderError: LocalizedError {
    case invalidToken
    case insufficientPermissions
    case rateLimitExceeded
    case serverNotFound
    case networkError(Error)
    case apiError(statusCode: Int, message: String)
    case unknownError
    
    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Invalid API token. Please check and try again."
        case .insufficientPermissions:
            return "Token needs read permission for viewing or read-write for creating."
        case .rateLimitExceeded:
            return "Too many requests. Please wait and try again."
        case .serverNotFound:
            return "Server not found."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(_, let message):
            return message
        case .unknownError:
            return "An unknown error occurred."
        }
    }
}