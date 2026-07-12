//
//  ChatAttachmentUploadService.swift
//  CodeAgentsMobile
//
//  Purpose: Uploads local attachments into the active agent folder and returns @file reference paths.
//

import Foundation

enum ChatAttachmentError: LocalizedError {
    case missingLocalFile(String)

    var errorDescription: String? {
        switch self {
        case .missingLocalFile(let name):
            return "Missing local file: \(name)"
        }
    }
}

/// Reusable SSH + remote attachments directory for serial multi-file chat uploads.
struct ChatAttachmentUploadContext {
    let session: SSHSession
    let remoteAttachmentsDir: String
}

final class ChatAttachmentUploadService {
    static let shared = ChatAttachmentUploadService()

    /// Base64 payload size that fits in a single remote shell command (ARG_MAX headroom).
    /// Must stay divisible by 4 for base64. Larger than the old 12KB chunks → fewer SSH round-trips.
    static let maxSingleShotBase64Length = 48_000
    /// Chunk size for multi-command uploads (divisible by 4).
    static let chunkBase64Length = 48_000

    private let sshService = ServiceManager.shared.sshService
    private let fileManager = FileManager.default

    private init() { }

    /// One pooled session + `mkdir -p` for a batch of serial uploads.
    func prepareUploadContext(for project: RemoteProject) async throws -> ChatAttachmentUploadContext {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)
        let remoteAttachmentsDir = AgentProjectFileLayout.remotePath(
            projectPath: project.path,
            relativePath: AgentProjectFileLayout.attachmentsRelativePath
        )
        try await ensureRemoteDirectory(remoteAttachmentsDir, session: session)
        return ChatAttachmentUploadContext(session: session, remoteAttachmentsDir: remoteAttachmentsDir)
    }

    func resolveFileReferences(
        for attachments: [ChatComposerAttachment],
        in project: RemoteProject
    ) async throws -> [String] {
        let context = try await prepareUploadContext(for: project)

        var references: [String] = []
        for attachment in attachments {
            switch attachment {
            case .projectFile(_, _, let relativePath):
                let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    references.append(trimmed)
                }

            case .localFile(_, let displayName, let localURL):
                let reference = try await uploadLocalFile(
                    localURL: localURL,
                    displayName: displayName,
                    using: context
                )
                references.append(reference)
            }
        }

        var unique: [String] = []
        var seen: Set<String> = []
        for reference in references where seen.insert(reference).inserted {
            unique.append(reference)
        }
        return unique
    }

    /// Upload a single local file (used by initial send and failed-attachment retry).
    func uploadLocalFile(
        localURL: URL,
        displayName: String,
        in project: RemoteProject
    ) async throws -> String {
        let context = try await prepareUploadContext(for: project)
        return try await uploadLocalFile(
            localURL: localURL,
            displayName: displayName,
            using: context
        )
    }

    /// Upload using a prepared context (shared session + directory). Serial one-by-one is intentional.
    func uploadLocalFile(
        localURL: URL,
        displayName: String,
        using context: ChatAttachmentUploadContext
    ) async throws -> String {
        guard fileManager.fileExists(atPath: localURL.path) else {
            throw ChatAttachmentError.missingLocalFile(displayName)
        }

        let safeName = sanitizeFilename(displayName)
        let remoteFileName = "\(UUID().uuidString.prefix(8))-\(safeName)"
        let remotePath = "\(context.remoteAttachmentsDir)/\(remoteFileName)"

        try await uploadFileData(localURL: localURL, remotePath: remotePath, session: context.session)
        return AgentProjectFileLayout.attachmentReference(fileName: remoteFileName)
    }

    // MARK: - Private

    private func ensureRemoteDirectory(_ path: String, session: SSHSession) async throws {
        let escaped = shellEscaped(path)
        _ = try await session.execute("mkdir -p \(escaped)")
    }

    private func uploadFileData(localURL: URL, remotePath: String, session: SSHSession) async throws {
        let data = try Data(contentsOf: localURL)
        let base64 = data.base64EncodedString()
        let remoteEscaped = shellEscaped(remotePath)

        guard !base64.isEmpty else {
            _ = try await session.execute(": > \(remoteEscaped)")
            return
        }

        // Small/medium files: one round-trip (truncate + write).
        if base64.count <= Self.maxSingleShotBase64Length {
            let chunkEscaped = shellEscaped(base64)
            _ = try await session.execute(
                "printf '%s' \(chunkEscaped) | base64 -d > \(remoteEscaped)"
            )
            return
        }

        // Large files: fewer, larger chunks than the old 12KB path.
        _ = try await session.execute(": > \(remoteEscaped)")
        let chunkSize = Self.chunkBase64Length
        var index = base64.startIndex
        while index < base64.endIndex {
            let endIndex = base64.index(index, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = String(base64[index..<endIndex])
            let chunkEscaped = shellEscaped(chunk)
            _ = try await session.execute(
                "printf '%s' \(chunkEscaped) | base64 -d >> \(remoteEscaped)"
            )
            index = endIndex
        }
    }

    private func sanitizeFilename(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "file" }

        var result = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_" {
                result.append(Character(scalar))
            } else {
                result.append("_")
            }
        }

        let collapsed = result
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))

        return collapsed.isEmpty ? "file" : collapsed
    }

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
