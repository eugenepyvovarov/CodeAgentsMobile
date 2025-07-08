//
//  SSHKeyParsingError.swift
//  CodeAgentsMobile
//
//  Purpose: Comprehensive error types for SSH key parsing
//  Inspired by Citadel's specific error handling approach
//

import Foundation

/// Comprehensive errors for SSH key parsing operations
public enum SSHKeyParsingError: LocalizedError {
    // Format errors
    case invalidOpenSSHBoundary
    case invalidBase64Payload
    case invalidPEMBoundary
    case unknownKeyFormat
    
    // Structure errors
    case invalidOpenSSHPrefix
    case missingPublicKeyBuffer
    case missingPrivateKeyBuffer
    case missingComment
    case invalidCheck
    case invalidPadding
    
    // Key data errors
    case invalidKeyData
    case invalidPublicKeyInPrivateKey
    case invalidKeySize(expected: Int, actual: Int)
    case missingKeyComponent(String)
    
    // Type errors
    case unsupportedKeyType(String)
    case unsupportedCipher(String)
    case unsupportedKDF(String)
    case keyTypeMismatch(expected: String, actual: String)
    
    // Encryption errors
    case encryptedKeyRequiresPassphrase
    case decryptionFailed
    case invalidPassphrase
    
    // Parsing errors
    case parsingFailed(String)
    case truncatedData(needed: Int, available: Int)
    case malformedStructure(String)
    
    // Feature errors
    case unsupportedFeature(String)
    case multipleKeysNotSupported
    
    public var errorDescription: String? {
        switch self {
        // Format errors
        case .invalidOpenSSHBoundary:
            return "Invalid OpenSSH key boundaries. Expected '-----BEGIN OPENSSH PRIVATE KEY-----' and '-----END OPENSSH PRIVATE KEY-----'"
        case .invalidBase64Payload:
            return "Invalid base64 encoded key data"
        case .invalidPEMBoundary:
            return "Invalid PEM key boundaries"
        case .unknownKeyFormat:
            return "Unknown key format. Supported formats: OpenSSH, PEM"
            
        // Structure errors
        case .invalidOpenSSHPrefix:
            return "Invalid OpenSSH key prefix. Expected 'openssh-key-v1\\0'"
        case .missingPublicKeyBuffer:
            return "Missing public key data in OpenSSH key"
        case .missingPrivateKeyBuffer:
            return "Missing private key data in OpenSSH key"
        case .missingComment:
            return "Missing comment field in OpenSSH key"
        case .invalidCheck:
            return "Invalid check bytes in OpenSSH key. Key may be corrupted or passphrase incorrect"
        case .invalidPadding:
            return "Invalid padding in OpenSSH key"
            
        // Key data errors
        case .invalidKeyData:
            return "Invalid key data"
        case .invalidPublicKeyInPrivateKey:
            return "Public key in private key section doesn't match"
        case .invalidKeySize(let expected, let actual):
            return "Invalid key size: expected \(expected) bytes, got \(actual) bytes"
        case .missingKeyComponent(let component):
            return "Missing key component: \(component)"
            
        // Type errors
        case .unsupportedKeyType(let type):
            return "Unsupported key type: \(type)"
        case .unsupportedCipher(let cipher):
            return "Unsupported cipher: \(cipher)"
        case .unsupportedKDF(let kdf):
            return "Unsupported key derivation function: \(kdf)"
        case .keyTypeMismatch(let expected, let actual):
            return "Key type mismatch: expected \(expected), got \(actual)"
            
        // Encryption errors
        case .encryptedKeyRequiresPassphrase:
            return "This key is encrypted and requires a passphrase"
        case .decryptionFailed:
            return "Failed to decrypt key. Check your passphrase"
        case .invalidPassphrase:
            return "Invalid passphrase"
            
        // Parsing errors
        case .parsingFailed(let reason):
            return "Failed to parse key: \(reason)"
        case .truncatedData(let needed, let available):
            return "Truncated data: needed \(needed) bytes, only \(available) available"
        case .malformedStructure(let description):
            return "Malformed key structure: \(description)"
            
        // Feature errors
        case .unsupportedFeature(let feature):
            return "Unsupported feature: \(feature)"
        case .multipleKeysNotSupported:
            return "Multiple keys in one file are not supported"
        }
    }
    
    /// Helper to create user-friendly error messages for common issues
    public var userGuidance: String? {
        switch self {
        case .unsupportedKeyType(let type) where type.contains("ecdsa"):
            return "OpenSSH ECDSA keys require conversion to PEM format.\n\nPlease run:\nssh-keygen -p -m PEM -f your_key_file"
        case .encryptedKeyRequiresPassphrase:
            return "This key is password-protected. Please provide the passphrase when importing."
        case .invalidPassphrase, .invalidCheck:
            return "The passphrase appears to be incorrect. Please try again."
        case .unsupportedKeyType(let type) where type.contains("rsa"):
            return "RSA keys are not supported. Please use Ed25519 or ECDSA keys for better security."
        default:
            return nil
        }
    }
}