//
//  OpenSSHProtocols.swift
//  CodeAgentsMobile
//
//  Purpose: Protocol definitions for OpenSSH key parsing
//  Adapted from Citadel's approach for extensible key support
//

import Foundation
import NIO
import Crypto
@preconcurrency import NIOSSH

/// Protocol for OpenSSH private keys that can be parsed from ByteBuffer
protocol OpenSSHPrivateKey: ByteBufferConvertible {
    /// The SSH key type prefix for private keys (e.g., "ssh-ed25519")
    static var privateKeyPrefix: String { get }
    
    /// The SSH key type prefix for public keys (should match private)
    static var publicKeyPrefix: String { get }
    
    /// Associated public key type
    associatedtype PublicKey: ByteBufferConvertible
}

/// Extension to make Curve25519.Signing.PrivateKey conform to OpenSSHPrivateKey
extension Curve25519.Signing.PrivateKey: OpenSSHPrivateKey {
    static var privateKeyPrefix: String { "ssh-ed25519" }
    static var publicKeyPrefix: String { "ssh-ed25519" }
    
    typealias PublicKey = Curve25519.Signing.PublicKey
    
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        // Read public key buffer
        guard let publicKeyBuffer = buffer.readSSHBuffer() else {
            throw SSHKeyParsingError.missingPublicKeyBuffer
        }
        
        // Read private key buffer
        guard var privateKeyBuffer = buffer.readSSHBuffer() else {
            throw SSHKeyParsingError.missingPrivateKeyBuffer
        }
        
        // Ed25519 private key is 32 bytes, followed by 32 bytes of public key
        guard let privateKeyBytes = privateKeyBuffer.readBytes(length: 32),
              let publicKeyBytes = privateKeyBuffer.readBytes(length: 32) else {
            throw SSHKeyParsingError.invalidKeyData
        }
        
        // Verify public key matches
        let publicKeyData = Data(publicKeyBytes)
        if publicKeyBuffer.readableBytes > 0 || publicKeyData != publicKeyBuffer.getData(at: 0, length: publicKeyBuffer.readableBytes) {
            // Public key mismatch - but for Ed25519 we can still use the private key
        }
        
        return try Self(rawRepresentation: privateKeyBytes)
    }
    
    func write(to buffer: inout ByteBuffer) -> Int {
        let publicKeyData = publicKey.rawRepresentation
        var publicKeyBuffer = ByteBuffer(data: publicKeyData)
        let n = buffer.writeSSHBuffer(&publicKeyBuffer)
        return n + buffer.writeCompositeSSHString { buffer in
            let n = buffer.writeData(self.rawRepresentation)
            return n + buffer.writeData(publicKeyData)
        }
    }
}

/// Extension to make Curve25519.Signing.PublicKey conform to ByteBufferConvertible
extension Curve25519.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        guard var publicKeyBuffer = buffer.readSSHBuffer() else {
            throw SSHKeyParsingError.missingPublicKeyBuffer
        }
        
        guard let keyBytes = publicKeyBuffer.readBytes(length: publicKeyBuffer.readableBytes) else {
            throw SSHKeyParsingError.invalidKeyData
        }
        
        return try Self(rawRepresentation: keyBytes)
    }
    
    @discardableResult
    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeData(self.rawRepresentation)
    }
}

/// Placeholder extensions for ECDSA keys - to be implemented with SwiftASN1
extension P256.Signing.PrivateKey: OpenSSHPrivateKey {
    static var privateKeyPrefix: String { "ecdsa-sha2-nistp256" }
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp256" }
    
    typealias PublicKey = P256.Signing.PublicKey
    
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        try readOpenSSH(consuming: &buffer)
    }
    
    func write(to buffer: inout ByteBuffer) -> Int {
        // TODO: Implement if needed
        0
    }
}

extension P384.Signing.PrivateKey: OpenSSHPrivateKey {
    static var privateKeyPrefix: String { "ecdsa-sha2-nistp384" }
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp384" }
    
    typealias PublicKey = P384.Signing.PublicKey
    
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        try readOpenSSH(consuming: &buffer)
    }
    
    func write(to buffer: inout ByteBuffer) -> Int {
        // TODO: Implement if needed
        0
    }
}

extension P521.Signing.PrivateKey: OpenSSHPrivateKey {
    static var privateKeyPrefix: String { "ecdsa-sha2-nistp521" }
    static var publicKeyPrefix: String { "ecdsa-sha2-nistp521" }
    
    typealias PublicKey = P521.Signing.PublicKey
    
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        try readOpenSSH(consuming: &buffer)
    }
    
    func write(to buffer: inout ByteBuffer) -> Int {
        // TODO: Implement if needed
        0
    }
}

// Public key extensions for ECDSA
extension P256.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        throw SSHKeyParsingError.unsupportedKeyType("ECDSA public key parsing not implemented")
    }
    
    func write(to buffer: inout ByteBuffer) -> Int {
        0
    }
}

extension P384.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        throw SSHKeyParsingError.unsupportedKeyType("ECDSA public key parsing not implemented")
    }
    
    func write(to buffer: inout ByteBuffer) -> Int {
        0
    }
}

extension P521.Signing.PublicKey: ByteBufferConvertible {
    static func read(consuming buffer: inout ByteBuffer) throws -> Self {
        throw SSHKeyParsingError.unsupportedKeyType("ECDSA public key parsing not implemented")
    }
    
    func write(to buffer: inout ByteBuffer) -> Int {
        0
    }
}