//
//  AgentAvatarService.swift
//  CodeAgentsMobile
//
//  Purpose: Read/write agent avatars (emoji/image) via remote identity + optional image file.
//

import Foundation
import SwiftData
import UIKit

enum AgentAvatarServiceError: LocalizedError {
    case invalidEmoji
    case invalidImage
    case invalidPath
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmoji:
            return "Choose a single emoji."
        case .invalidImage:
            return "Could not process that image."
        case .invalidPath:
            return "Invalid avatar image path."
        case .uploadFailed(let message):
            return message
        }
    }
}

@MainActor
final class AgentAvatarService {
    static let shared = AgentAvatarService()

    private let sshService: SSHService
    private let identityService: ProxyAgentIdentityService

    init(
        sshService: SSHService? = nil,
        identityService: ProxyAgentIdentityService? = nil
    ) {
        self.sshService = sshService ?? .shared
        self.identityService = identityService ?? .shared
    }

    // MARK: - Cache helpers

    static func applyCacheMetadata(_ avatar: AgentAvatarDescriptor?, to project: RemoteProject) {
        let descriptor = avatar ?? .empty
        project.avatarKind = descriptor.kind
        project.avatarEmoji = descriptor.kind == .emoji ? descriptor.emoji : nil
        project.avatarRemoteUpdatedAt = descriptor.updatedAt
        if descriptor.kind != .image {
            project.avatarLocalImagePath = nil
        }
    }

    // MARK: - Refresh

    /// Pull remote avatar metadata (and image thumbnail when needed) into local cache.
    func refresh(for project: RemoteProject, modelContext: ModelContext?) async {
        do {
            let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
            guard let document = await identityService.readIdentityDocument(for: project, session: session) else {
                Self.applyCacheMetadata(nil, to: project)
                try? modelContext?.save()
                return
            }
            Self.applyCacheMetadata(document.avatar, to: project)

            if document.avatar?.kind == .image,
               let relative = document.avatar?.image.flatMap({ AgentAvatarPathValidation.validatedProjectRelativePath($0) }) {
                await cacheRemoteImage(project: project, relativePath: relative, session: session)
            }

            try? modelContext?.save()
        } catch {
            SSHLogger.log("Avatar refresh failed: \(error.localizedDescription)", level: .debug)
        }
    }

    // MARK: - Mutations

    func setEmoji(
        _ emoji: String,
        for project: RemoteProject,
        modelContext: ModelContext?,
        updatedBy: AgentAvatarUpdatedBy = .user
    ) async throws {
        let normalized = Self.normalizeEmoji(emoji)
        guard !normalized.isEmpty else { throw AgentAvatarServiceError.invalidEmoji }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let document = try await identityService.updateIdentityDocument(for: project, session: session) { doc in
            doc.avatar = AgentAvatarDescriptor(
                kind: .emoji,
                emoji: normalized,
                image: doc.avatar?.image,
                updatedAt: Date(),
                updatedBy: updatedBy
            )
        }
        Self.applyCacheMetadata(document.avatar, to: project)
        try? modelContext?.save()
    }

    func setImage(
        data: Data,
        for project: RemoteProject,
        modelContext: ModelContext?,
        updatedBy: AgentAvatarUpdatedBy = .user
    ) async throws {
        guard let processed = Self.prepareAvatarImageData(data) else {
            throw AgentAvatarServiceError.invalidImage
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let relative = AgentProjectFileLayout.avatarImageRelativePath
        let remotePath = AgentProjectFileLayout.remotePath(projectPath: project.path, relativePath: relative)
        try await writeRemoteFile(data: processed, remotePath: remotePath, session: session)

        let document = try await identityService.updateIdentityDocument(for: project, session: session) { doc in
            doc.avatar = AgentAvatarDescriptor(
                kind: .image,
                emoji: nil,
                image: relative,
                updatedAt: Date(),
                updatedBy: updatedBy
            )
        }
        Self.applyCacheMetadata(document.avatar, to: project)
        await cacheLocalImageData(processed, for: project)
        try? modelContext?.save()
    }

    func clear(
        for project: RemoteProject,
        modelContext: ModelContext?,
        updatedBy: AgentAvatarUpdatedBy = .user,
        removeImageFile: Bool = true
    ) async throws {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let previousImage = await identityService.readIdentityDocument(for: project, session: session)?.avatar?.image

        let document = try await identityService.updateIdentityDocument(for: project, session: session) { doc in
            doc.avatar = AgentAvatarDescriptor(
                kind: .none,
                emoji: nil,
                image: nil,
                updatedAt: Date(),
                updatedBy: updatedBy
            )
        }

        if removeImageFile {
            let relative = previousImage.flatMap { AgentAvatarPathValidation.validatedProjectRelativePath($0) }
                ?? AgentProjectFileLayout.avatarImageRelativePath
            let remotePath = AgentProjectFileLayout.remotePath(projectPath: project.path, relativePath: relative)
            _ = try? await session.execute("rm -f \(shellEscaped(remotePath))")
        }

        Self.applyCacheMetadata(document.avatar, to: project)
        project.avatarLocalImagePath = nil
        try? modelContext?.save()
    }

    /// Copy avatar metadata + image from source agent to clone (new agent_id already on clone).
    /// - Parameter imageAlreadyCopied: When true (Duplicate Agent bootstrap already `cp`'d the image),
    ///   only identity metadata is written — avoids a second remote image copy.
    func copyAvatar(
        from source: RemoteProject,
        to clone: RemoteProject,
        imageAlreadyCopied: Bool = false
    ) async throws {
        let sourceSession = try await sshService.getConnection(for: source, purpose: .fileOperations)
        guard let sourceDoc = await identityService.readIdentityDocument(for: source, session: sourceSession),
              let avatar = sourceDoc.avatar,
              avatar.kind != .none,
              avatar.isVisible else {
            return
        }

        let cloneSession = try await sshService.getConnection(for: clone, purpose: .fileOperations)

        var next = avatar
        next.updatedAt = Date()
        next.updatedBy = .user

        if avatar.kind == .image {
            let destRelative = AgentProjectFileLayout.avatarImageRelativePath
            if !imageAlreadyCopied {
                let relative = avatar.image.flatMap { AgentAvatarPathValidation.validatedProjectRelativePath($0) }
                    ?? AgentProjectFileLayout.avatarImageRelativePath
                let sourcePath = AgentProjectFileLayout.remotePath(projectPath: source.path, relativePath: relative)
                let destPath = AgentProjectFileLayout.remotePath(projectPath: clone.path, relativePath: destRelative)
                let destDir = (destPath as NSString).deletingLastPathComponent
                let copyCmd = """
                mkdir -p \(shellEscaped(destDir)) && \
                if [ -f \(shellEscaped(sourcePath)) ]; then cp \(shellEscaped(sourcePath)) \(shellEscaped(destPath)); fi
                """
                _ = try await cloneSession.execute(copyCmd)
            }
            // Prefer canonical path on clone even if source used a custom relative path.
            next.image = destRelative
        }

        _ = try await identityService.updateIdentityDocument(for: clone, session: cloneSession) { doc in
            doc.avatar = next
        }
        Self.applyCacheMetadata(next, to: clone)
    }

    // MARK: - Image helpers

    nonisolated static func normalizeEmoji(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Keep first extended grapheme cluster only.
        return String(trimmed.prefix(1))
    }

    nonisolated static func prepareAvatarImageData(_ data: Data, maxEdge: CGFloat = 256) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        let renderer = UIGraphicsImageRenderer(size: target)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        // Prefer PNG for simple icons; fall back to JPEG for large photos.
        if let png = rendered.pngData(), png.count <= 350_000 {
            return png
        }
        return rendered.jpegData(compressionQuality: 0.85)
    }

    private func writeRemoteFile(data: Data, remotePath: String, session: SSHSession) async throws {
        let dir = (remotePath as NSString).deletingLastPathComponent
        let base64 = data.base64EncodedString()
        // Chunk-free: avatars are small after resize.
        let command = """
        mkdir -p \(shellEscaped(dir)) && printf '%s' \(shellEscaped(base64)) | (base64 -d 2>/dev/null || base64 --decode) > \(shellEscaped(remotePath))
        """
        do {
            _ = try await session.execute(command)
        } catch {
            throw AgentAvatarServiceError.uploadFailed(error.localizedDescription)
        }
    }

    private func cacheRemoteImage(project: RemoteProject, relativePath: String, session: SSHSession) async {
        let remotePath = AgentProjectFileLayout.remotePath(projectPath: project.path, relativePath: relativePath)
        let marker = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let start = "__AVATAR_B64_START_\(marker)__"
        let end = "__AVATAR_B64_END_\(marker)__"
        let command = """
        printf \(shellEscaped(start)); \
        if [ -f \(shellEscaped(remotePath)) ]; then (base64 -w 0 \(shellEscaped(remotePath)) 2>/dev/null || base64 \(shellEscaped(remotePath))); else printf MISSING; fi; \
        printf \(shellEscaped(end))
        """
        guard let output = try? await session.execute(command),
              let s = output.range(of: start),
              let e = output.range(of: end),
              s.upperBound <= e.lowerBound else {
            return
        }
        let payload = String(output[s.upperBound..<e.lowerBound])
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard payload != "MISSING", let data = Data(base64Encoded: payload) else { return }
        await cacheLocalImageData(data, for: project)
    }

    private func cacheLocalImageData(_ data: Data, for project: RemoteProject) async {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AgentAvatars", isDirectory: true)
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(project.id.uuidString).img")
        do {
            try data.write(to: file, options: .atomic)
            project.avatarLocalImagePath = file.path
        } catch {
            SSHLogger.log("Avatar local cache write failed: \(error.localizedDescription)", level: .debug)
        }
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
