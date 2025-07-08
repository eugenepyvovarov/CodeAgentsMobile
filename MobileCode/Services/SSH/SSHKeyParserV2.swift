//
//  SSHKeyParserV2.swift
//  CodeAgentsMobile
//
//  Purpose: Enhanced SSH key parser using ByteBuffer approach
//  Integrates Citadel patterns with SwiftASN1 for ECDSA support
//

import Foundation
import NIO
import Crypto
import SwiftASN1
@preconcurrency import NIOSSH

/// Enhanced SSH key parser using ByteBuffer
class SSHKeyParserV2 {
    
    /// Supported key formats
    enum KeyFormat {
        case pemEC          // -----BEGIN EC PRIVATE KEY-----
        case pemPrivate     // -----BEGIN PRIVATE KEY-----
        case opensshPrivate // -----BEGIN OPENSSH PRIVATE KEY-----
        case pemRSA         // -----BEGIN RSA PRIVATE KEY-----
        case raw            // Raw bytes (for Ed25519)
        case unknown
    }
    
    /// Parse result containing the key and metadata
    struct ParseResult {
        let privateKey: NIOSSHPrivateKey
        let keyType: String
    }
    
    /// OpenSSH format structure
    struct OpenSSHFormat {
        enum Cipher: String {
            case none
            case aes128ctr = "aes128-ctr"
            case aes256ctr = "aes256-ctr"
        }
        
        enum KDF: String {
            case none
            case bcrypt
        }
    }
    
    /// Detect the format of the key data
    static func detectFormat(from data: Data) -> KeyFormat {
        guard let keyString = String(data: data, encoding: .utf8) else {
            // Check if it could be raw binary data
            if data.count == 32 || data.count == 64 {
                return .raw
            }
            return .unknown
        }
        
        if keyString.contains("BEGIN OPENSSH PRIVATE KEY") {
            return .opensshPrivate
        } else if keyString.contains("BEGIN EC PRIVATE KEY") {
            return .pemEC
        } else if keyString.contains("BEGIN PRIVATE KEY") {
            return .pemPrivate
        } else if keyString.contains("BEGIN RSA PRIVATE KEY") {
            return .pemRSA
        } else if data.count == 32 || data.count == 64 {
            // Could be raw Ed25519 key
            return .raw
        }
        
        return .unknown
    }
    
    /// Parse a private key from data
    static func parse(keyData: Data, passphrase: String? = nil) throws -> ParseResult {
        let format = detectFormat(from: keyData)
        
        switch format {
        case .pemEC, .pemPrivate:
            return try parsePEMKey(keyData: keyData, passphrase: passphrase)
            
        case .raw:
            return try parseRawKey(keyData: keyData)
            
        case .opensshPrivate:
            return try parseOpenSSHKey(keyData: keyData, passphrase: passphrase)
            
        case .pemRSA:
            throw SSHKeyParsingError.unsupportedKeyType("RSA keys are not supported. Please use Ed25519, P256, P384, or P521 keys.")
            
        case .unknown:
            throw SSHKeyParsingError.unknownKeyFormat
        }
    }
    
    /// Parse PEM format keys (unchanged from original)
    private static func parsePEMKey(keyData: Data, passphrase: String? = nil) throws -> ParseResult {
        guard let pemString = String(data: keyData, encoding: .utf8) else {
            throw SSHKeyParsingError.invalidKeyData
        }
        
        // First try swift-crypto for unencrypted keys
        if passphrase == nil || passphrase?.isEmpty == true {
            // Try P256
            if let p256Key = try? P256.Signing.PrivateKey(pemRepresentation: pemString) {
                return ParseResult(
                    privateKey: NIOSSHPrivateKey(p256Key: p256Key),
                    keyType: "P256"
                )
            }
            
            // Try P384
            if let p384Key = try? P384.Signing.PrivateKey(pemRepresentation: pemString) {
                return ParseResult(
                    privateKey: NIOSSHPrivateKey(p384Key: p384Key),
                    keyType: "P384"
                )
            }
            
            // Try P521
            if let p521Key = try? P521.Signing.PrivateKey(pemRepresentation: pemString) {
                return ParseResult(
                    privateKey: NIOSSHPrivateKey(p521Key: p521Key),
                    keyType: "P521"
                )
            }
        }
        
        if passphrase != nil {
            throw SSHKeyParsingError.unsupportedFeature("Encrypted PEM keys are not yet supported. Please decrypt the key first.")
        }
        
        throw SSHKeyParsingError.parsingFailed("Unable to parse PEM key. Ensure it's a valid P256, P384, or P521 key.")
    }
    
    /// Parse raw Ed25519 key bytes (unchanged)
    private static func parseRawKey(keyData: Data) throws -> ParseResult {
        let privateKeyData: Data
        
        if keyData.count == 32 {
            privateKeyData = keyData
        } else if keyData.count == 64 {
            // Sometimes the public key is appended
            privateKeyData = keyData.prefix(32)
        } else {
            throw SSHKeyParsingError.invalidKeyData
        }
        
        guard let ed25519Key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) else {
            throw SSHKeyParsingError.parsingFailed("Failed to create Ed25519 key from raw bytes")
        }
        
        return ParseResult(
            privateKey: NIOSSHPrivateKey(ed25519Key: ed25519Key),
            keyType: "Ed25519"
        )
    }
    
    /// Parse OpenSSH format using ByteBuffer
    private static func parseOpenSSHKey(keyData: Data, passphrase: String? = nil) throws -> ParseResult {
        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw SSHKeyParsingError.invalidKeyData
        }
        
        // Extract base64 content
        var key = keyString.replacingOccurrences(of: "\n", with: "")
        
        guard key.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"),
              key.hasSuffix("-----END OPENSSH PRIVATE KEY-----") else {
            throw SSHKeyParsingError.invalidOpenSSHBoundary
        }
        
        key.removeLast("-----END OPENSSH PRIVATE KEY-----".utf8.count)
        key.removeFirst("-----BEGIN OPENSSH PRIVATE KEY-----".utf8.count)
        
        guard let data = Data(base64Encoded: key) else {
            throw SSHKeyParsingError.invalidBase64Payload
        }
        
        var buffer = ByteBuffer(data: data)
        
        // Check magic bytes
        guard buffer.readString(length: "openssh-key-v1".utf8.count) == "openssh-key-v1",
              buffer.readInteger(as: UInt8.self) == 0x00 else {
            throw SSHKeyParsingError.invalidOpenSSHPrefix
        }
        
        // Read cipher and KDF
        guard let cipherNameString = buffer.readSSHString() else {
            throw SSHKeyParsingError.malformedStructure("Missing cipher name")
        }
        
        guard let cipher = OpenSSHFormat.Cipher(rawValue: cipherNameString) else {
            throw SSHKeyParsingError.unsupportedCipher(cipherNameString)
        }
        
        guard let kdfNameString = buffer.readSSHString() else {
            throw SSHKeyParsingError.malformedStructure("Missing KDF name")
        }
        
        guard let kdf = OpenSSHFormat.KDF(rawValue: kdfNameString) else {
            throw SSHKeyParsingError.unsupportedKDF(kdfNameString)
        }
        
        // Skip KDF options
        guard let _ = buffer.readSSHBuffer() else {
            throw SSHKeyParsingError.malformedStructure("Missing KDF options")
        }
        
        // Check for encryption
        if cipher != .none && passphrase == nil {
            throw SSHKeyParsingError.encryptedKeyRequiresPassphrase
        }
        
        // Number of keys
        guard let numKeys = buffer.readInteger(endianness: .big, as: UInt32.self),
              numKeys == 1 else {
            throw SSHKeyParsingError.multipleKeysNotSupported
        }
        
        // Public key
        guard var publicKeyBuffer = buffer.readSSHBuffer() else {
            throw SSHKeyParsingError.missingPublicKeyBuffer
        }
        
        // Key type from public key
        guard let keyType = publicKeyBuffer.readSSHString() else {
            throw SSHKeyParsingError.malformedStructure("Missing key type in public key")
        }
        
        // Private key section
        guard var privateKeyBuffer = buffer.readSSHBuffer() else {
            throw SSHKeyParsingError.missingPrivateKeyBuffer
        }
        
        // TODO: Handle decryption if needed
        if cipher != .none {
            throw SSHKeyParsingError.unsupportedFeature("Encrypted OpenSSH keys not yet supported")
        }
        
        // Check bytes
        guard let check1 = privateKeyBuffer.readInteger(endianness: .big, as: UInt32.self),
              let check2 = privateKeyBuffer.readInteger(endianness: .big, as: UInt32.self),
              check1 == check2 else {
            throw SSHKeyParsingError.invalidCheck
        }
        
        // Private key type
        guard let privateKeyTypeString = privateKeyBuffer.readSSHString() else {
            throw SSHKeyParsingError.malformedStructure("Missing private key type")
        }
        
        guard privateKeyTypeString == keyType else {
            throw SSHKeyParsingError.keyTypeMismatch(expected: keyType, actual: privateKeyTypeString)
        }
        
        // Parse based on key type
        switch keyType {
        case "ssh-ed25519":
            let ed25519Key = try Curve25519.Signing.PrivateKey.read(consuming: &privateKeyBuffer)
            return ParseResult(
                privateKey: NIOSSHPrivateKey(ed25519Key: ed25519Key),
                keyType: "Ed25519"
            )
            
        case "ecdsa-sha2-nistp256":
            let p256Key = try P256.Signing.PrivateKey.read(consuming: &privateKeyBuffer)
            return ParseResult(
                privateKey: NIOSSHPrivateKey(p256Key: p256Key),
                keyType: "P256"
            )
            
        case "ecdsa-sha2-nistp384":
            let p384Key = try P384.Signing.PrivateKey.read(consuming: &privateKeyBuffer)
            return ParseResult(
                privateKey: NIOSSHPrivateKey(p384Key: p384Key),
                keyType: "P384"
            )
            
        case "ecdsa-sha2-nistp521":
            let p521Key = try P521.Signing.PrivateKey.read(consuming: &privateKeyBuffer)
            return ParseResult(
                privateKey: NIOSSHPrivateKey(p521Key: p521Key),
                keyType: "P521"
            )
            
        default:
            throw SSHKeyParsingError.unsupportedKeyType(keyType)
        }
    }
    
    /// Validate key data without parsing
    static func validate(keyData: Data) -> (isValid: Bool, error: String?) {
        let format = detectFormat(from: keyData)
        
        switch format {
        case .pemEC, .pemPrivate:
            return (true, nil)
            
        case .raw:
            if keyData.count == 32 || keyData.count == 64 {
                return (true, nil)
            } else {
                return (false, "Raw key must be 32 bytes (Ed25519 private key)")
            }
            
        case .opensshPrivate:
            // Do basic validation
            guard let keyString = String(data: keyData, encoding: .utf8) else {
                return (false, "Invalid key encoding")
            }
            
            if keyString.contains("ENCRYPTED") {
                return (false, "Encrypted OpenSSH keys require a passphrase")
            }
            
            return (true, nil)
            
        case .pemRSA:
            return (false, "RSA keys are not supported. Please use Ed25519, P256, P384, or P521 keys.")
            
        case .unknown:
            return (false, "Unknown key format. Supported: PEM (ECDSA), OpenSSH, raw bytes (Ed25519)")
        }
    }
    
    /// Detect key type from data
    static func detectKeyType(from data: Data) -> String? {
        if let keyString = String(data: data, encoding: .utf8) {
            // For OpenSSH format, need to decode and check
            if keyString.contains("BEGIN OPENSSH PRIVATE KEY") {
                // Try to extract key type
                if let result = try? parse(keyData: data) {
                    return result.keyType
                }
            }
            
            // Check content for hints
            if keyString.contains("Ed25519") {
                return "Ed25519"
            } else if keyString.contains("prime256v1") {
                return "P256"
            } else if keyString.contains("secp384r1") {
                return "P384"
            } else if keyString.contains("secp521r1") {
                return "P521"
            }
        }
        
        // Check for raw Ed25519
        if data.count == 32 || data.count == 64 {
            return "Ed25519"
        }
        
        return "Unknown"
    }
}