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
    
    // MARK: - Error Types
    
    enum KeychainError: LocalizedError {
        case itemNotFound
        case invalidData
        case unknown(OSStatus)
        
        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                return "Item not found in keychain"
            case .invalidData:
                return "Invalid data format"
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
    
    
    /// Delete password for a server
    /// - Parameter serverId: Server identifier
    func deletePassword(for serverId: UUID) throws {
        let passwordKey = passwordKey(for: serverId)
        try delete(for: passwordKey)
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
    
    /// Delete API key
    func deleteAPIKey() throws {
        try delete(for: "anthropic_api_key")
    }
    
    /// Check if API key exists
    /// - Returns: True if API key is stored
    func hasAPIKey() -> Bool {
        do {
            _ = try retrieveAPIKey()
            return true
        } catch {
            return false
        }
    }
    
    /// Store authentication token (for Claude Code OAuth)
    /// - Parameter token: The authentication token to store
    func storeAuthToken(_ token: String) throws {
        let data = token.data(using: .utf8)!
        try store(data: data, for: "claude_auth_token")
    }
    
    /// Retrieve authentication token
    /// - Returns: The stored authentication token
    func retrieveAuthToken() throws -> String {
        let data = try retrieve(for: "claude_auth_token")
        
        guard let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        
        return token
    }
    
    /// Delete authentication token
    func deleteAuthToken() throws {
        try delete(for: "claude_auth_token")
    }
    
    /// Check if authentication token exists
    /// - Returns: True if authentication token is stored
    func hasAuthToken() -> Bool {
        do {
            _ = try retrieveAuthToken()
            return true
        } catch {
            return false
        }
    }
    
    // MARK: - SSH Key Methods
    
    /// Store an SSH private key
    /// - Parameters:
    ///   - privateKey: The private key data
    ///   - keyId: Unique identifier for the SSH key
    func storeSSHKey(_ privateKey: Data, for keyId: UUID) throws {
        let key = sshKeyKey(for: keyId)
        try store(data: privateKey, for: key, syncToiCloud: true)
    }
    
    /// Retrieve an SSH private key
    /// - Parameter keyId: SSH key identifier
    /// - Returns: The stored private key data
    func retrieveSSHKey(for keyId: UUID) throws -> Data {
        let key = sshKeyKey(for: keyId)
        return try retrieve(for: key, syncToiCloud: true)
    }
    
    /// Delete SSH key
    /// - Parameter keyId: SSH key identifier
    func deleteSSHKey(for keyId: UUID) throws {
        let key = sshKeyKey(for: keyId)
        try delete(for: key, syncToiCloud: true)
        
        // Also delete associated passphrase if exists
        let passphraseKey = sshKeyPassphraseKey(for: keyId)
        try? delete(for: passphraseKey, syncToiCloud: true)
    }
    
    /// Store passphrase for an SSH key
    /// - Parameters:
    ///   - passphrase: The passphrase to store
    ///   - keyId: SSH key identifier
    func storeSSHKeyPassphrase(_ passphrase: String, for keyId: UUID) throws {
        let key = sshKeyPassphraseKey(for: keyId)
        let data = passphrase.data(using: .utf8)!
        try store(data: data, for: key, syncToiCloud: true)
    }
    
    /// Retrieve passphrase for an SSH key
    /// - Parameter keyId: SSH key identifier
    /// - Returns: The stored passphrase, or nil if not stored
    func retrieveSSHKeyPassphrase(for keyId: UUID) -> String? {
        let key = sshKeyPassphraseKey(for: keyId)
        
        do {
            let data = try retrieve(for: key, syncToiCloud: true)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    // MARK: - Private Methods
    
    private func passwordKey(for serverId: UUID) -> String {
        return "password_\(serverId.uuidString)"
    }
    
    private func sshKeyKey(for keyId: UUID) -> String {
        return "sshkey_\(keyId.uuidString)"
    }
    
    private func sshKeyPassphraseKey(for keyId: UUID) -> String {
        return "sshkey_passphrase_\(keyId.uuidString)"
    }
    
    
    /// Store data in keychain
    private func store(data: Data, for key: String, syncToiCloud: Bool = false) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: syncToiCloud ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Enable iCloud sync if requested
        if syncToiCloud {
            query[kSecAttrSynchronizable as String] = true
        }
        
        // Try to delete existing item first
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            throw KeychainError.unknown(status)
        }
    }
    
    /// Retrieve data from keychain
    private func retrieve(for key: String, syncToiCloud: Bool = false) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        // Enable iCloud sync if requested
        if syncToiCloud {
            query[kSecAttrSynchronizable as String] = true
        }
        
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
    private func delete(for key: String, syncToiCloud: Bool = false) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        // Enable iCloud sync if requested
        if syncToiCloud {
            query[kSecAttrSynchronizable as String] = true
        }
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
    }
    
}

// MARK: - Convenience Extensions

extension Server {
    /// Retrieve stored password
    func retrieveCredentials() throws -> String {
        // Only password authentication is supported
        return try KeychainManager.shared.retrievePassword(for: id)
    }
}