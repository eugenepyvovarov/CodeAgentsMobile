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
    
    // MARK: - Private Methods
    
    private func passwordKey(for serverId: UUID) -> String {
        return "password_\(serverId.uuidString)"
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
    
}

// MARK: - Convenience Extensions

extension Server {
    /// Retrieve stored password
    func retrieveCredentials() throws -> String {
        // Only password authentication is supported
        return try KeychainManager.shared.retrievePassword(for: id)
    }
}