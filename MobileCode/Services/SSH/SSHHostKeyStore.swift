//
//  SSHHostKeyStore.swift
//  CodeAgentsMobile
//
//  Purpose: Trust-on-first-use SSH host key pinning in Keychain.
//

import Foundation
@preconcurrency import NIOSSH
import CryptoKit

/// Persists accepted SSH host public keys (OpenSSH format) keyed by host:port.
enum SSHHostKeyStore {
    private static let accountPrefix = "ssh.hostkey."

    struct HostIdentity: Hashable {
        let host: String
        let port: Int

        var account: String {
            "\(accountPrefix)\(host.lowercased()):\(port)"
        }

        var displayName: String {
            port == 22 ? host : "\(host):\(port)"
        }
    }

    /// OpenSSH public-key string for storage / comparison.
    static func openSSHString(for key: NIOSSHPublicKey) -> String {
        String(openSSHPublicKey: key)
    }

    /// Short fingerprint for UI (SHA-256 of the OpenSSH key blob, base64).
    static func fingerprint(for key: NIOSSHPublicKey) -> String {
        fingerprint(openSSHKey: openSSHString(for: key))
    }

    static func fingerprint(openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let material = parts.count >= 2 ? String(parts[1]) : openSSHKey
        let data = Data(material.utf8)
        let digest = SHA256.hash(data: data)
        let b64 = Data(digest).base64EncodedString()
        return "SHA256:\(b64)"
    }

    static func loadPinnedKey(for identity: HostIdentity) -> String? {
        try? KeychainManager.shared.retrieveGenericSecret(account: identity.account)
    }

    static func pin(_ openSSHKey: String, for identity: HostIdentity) throws {
        try KeychainManager.shared.storeGenericSecret(openSSHKey, account: identity.account)
    }

    /// Clears a pinned key so the next connect can re-TOFU (user-initiated rotation).
    static func clearPin(for identity: HostIdentity) throws {
        try KeychainManager.shared.deleteGenericSecret(account: identity.account)
    }

    enum VerificationResult: Equatable {
        case acceptedFirstUse(fingerprint: String)
        case matched
        case mismatched(expectedFingerprint: String, presentedFingerprint: String)
    }

    /// TOFU: store on first use; require exact match thereafter.
    static func verify(hostKey: NIOSSHPublicKey, host: String, port: Int) -> VerificationResult {
        let identity = HostIdentity(host: host, port: port)
        let presented = openSSHString(for: hostKey)
        let presentedFP = fingerprint(openSSHKey: presented)

        if let pinned = loadPinnedKey(for: identity) {
            if pinned == presented {
                return .matched
            }
            return .mismatched(
                expectedFingerprint: fingerprint(openSSHKey: pinned),
                presentedFingerprint: presentedFP
            )
        }

        do {
            try pin(presented, for: identity)
            return .acceptedFirstUse(fingerprint: presentedFP)
        } catch {
            // If Keychain write fails, still allow this session but do not pin.
            SSHLogger.log("Failed to pin host key for \(identity.displayName): \(error)", level: .error)
            return .acceptedFirstUse(fingerprint: presentedFP)
        }
    }
}
