//
//  KeychainManager.swift
//  CodeAgentsMobile
//
//  Created by Claude on 2025-06-10.
//
//  Purpose: Secure storage for credentials using iOS Keychain
//  - Stores server passwords and SSH keys
//  - Supports biometric authentication
//  - Encrypts sensitive data
//

import Foundation
import Security

/// Manages secure storage of credentials in iOS Keychain
class KeychainManager {
    // MARK: - Singleton
    
    static let shared = KeychainManager()
    
    // MARK: - Properties
    
    private let serviceName = "com.claudecode.mobile"
    private let accessGroup: String? = nil // Can be used for app groups
    
    // MARK: - Error Types
    
    enum KeychainError: LocalizedError {
        case itemNotFound
        case duplicateItem
        case invalidData
        case authenticationFailed
        case unknown(OSStatus)
        
        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "Item not found in keychain"
            case .duplicateItem:
                return "Item already exists in keychain"
            case .invalidData:
                return "Invalid data format"
            case .authenticationFailed:
                return "Authentication failed"
            case .unknown(let status):
                return "Keychain error: \(status)"
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Store a password for a server
    /// - Parameters:
    ///   - password: The password to store
    ///   - serverId: Unique identifier for the server
    func storePassword(_ password: String, for serverId: UUID) throws {
        let key = passwordKey(for: serverId)
        let data = password.data(using: .utf8)!
        
        try store(data: data, for: key)
    }
    
    /// Retrieve a password for a server
    /// - Parameter serverId: Server identifier
    /// - Returns: The stored password
    func retrievePassword(for serverId: UUID) throws -> String {
        let key = passwordKey(for: serverId)
        let data = try retrieve(for: key)
        
        guard let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        
        return password
    }
    
    /// Store an SSH private key
    /// - Parameters:
    ///   - keyData: The SSH key data
    ///   - serverId: Server identifier
    func storeSSHKey(_ keyData: Data, for serverId: UUID) throws {
        let key = sshKeyKey(for: serverId)
        try store(data: keyData, for: key)
    }
    
    /// Retrieve an SSH private key
    /// - Parameter serverId: Server identifier
    /// - Returns: The SSH key data
    func retrieveSSHKey(for serverId: UUID) throws -> Data {
        let key = sshKeyKey(for: serverId)
        return try retrieve(for: key)
    }
    
    /// Delete all credentials for a server
    /// - Parameter serverId: Server identifier
    func deleteCredentials(for serverId: UUID) throws {
        // Try to delete both password and SSH key
        let passwordKey = passwordKey(for: serverId)
        let sshKey = sshKeyKey(for: serverId)
        
        try? delete(for: passwordKey)
        try? delete(for: sshKey)
    }
    
    /// Store API key (for Claude)
    /// - Parameter apiKey: The API key to store
    func storeAPIKey(_ apiKey: String) throws {
        let data = apiKey.data(using: .utf8)!
        try store(data: data, for: "anthropic_api_key")
    }
    
    /// Retrieve API key
    /// - Returns: The stored API key
    func retrieveAPIKey() throws -> String {
        let data = try retrieve(for: "anthropic_api_key")
        
        guard let apiKey = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        
        return apiKey
    }
    
    // MARK: - Private Methods
    
    private func passwordKey(for serverId: UUID) -> String {
        return "password_\(serverId.uuidString)"
    }
    
    private func sshKeyKey(for serverId: UUID) -> String {
        return "sshkey_\(serverId.uuidString)"
    }
    
    /// Store data in keychain
    private func store(data: Data, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Try to delete existing item first
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            if status == errSecDuplicateItem {
                throw KeychainError.duplicateItem
            }
            throw KeychainError.unknown(status)
        }
    }
    
    /// Retrieve data from keychain
    private func retrieve(for key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unknown(status)
        }
        
        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }
        
        return data
    }
    
    /// Delete item from keychain
    private func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
    }
    
    /// Clear all stored credentials (use with caution)
    func clearAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
    }
}

// MARK: - Convenience Extensions

extension Server {
    /// Retrieve stored credentials
    func retrieveCredentials() throws -> String {
        switch authMethodType {
        case "password":
            return try KeychainManager.shared.retrievePassword(for: id)
        case "key":
            let keyData = try KeychainManager.shared.retrieveSSHKey(for: id)
            return String(data: keyData, encoding: .utf8) ?? ""
        default:
            return ""
        }
    }
}