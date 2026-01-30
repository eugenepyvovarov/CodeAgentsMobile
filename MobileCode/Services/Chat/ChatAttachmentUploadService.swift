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

final class ChatAttachmentUploadService {
    static let shared = ChatAttachmentUploadService()

    private let sshService = ServiceManager.shared.sshService
    private let fileManager = FileManager.default

    private init() { }

    func resolveFileReferences(
        for attachments: [ChatComposerAttachment],
        in project: RemoteProject
    ) async throws -> [String] {
        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)

        let remoteAttachmentsDir = "\(project.path)/.claude/attachments"
        try await ensureRemoteDirectory(remoteAttachmentsDir, session: session)

        var references: [String] = []
        for attachment in attachments {
            switch attachment {
            case .projectFile(_, _, let relativePath):
                let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    references.append(trimmed)
                }

            case .localFile(_, let displayName, let localURL):
                guard fileManager.fileExists(atPath: localURL.path) else {
                    throw ChatAttachmentError.missingLocalFile(displayName)
                }

                let safeName = sanitizeFilename(displayName)
                let remoteFileName = "\(UUID().uuidString.prefix(8))-\(safeName)"
                let remotePath = "\(remoteAttachmentsDir)/\(remoteFileName)"

                try await uploadFileChunked(localURL: localURL, remotePath: remotePath, session: session)
                references.append(".claude/attachments/\(remoteFileName)")
            }
        }

        var unique: [String] = []
        var seen: Set<String> = []
        for reference in references where seen.insert(reference).inserted {
            unique.append(reference)
        }
        return unique
    }

    // MARK: - Private

    private func ensureRemoteDirectory(_ path: String, session: SSHSession) async throws {
        let escaped = shellEscaped(path)
        _ = try await session.execute("mkdir -p \(escaped)")
    }

    private func uploadFileChunked(localURL: URL, remotePath: String, session: SSHSession) async throws {
        let data = try Data(contentsOf: localURL)
        let base64 = data.base64EncodedString()

        let remoteEscaped = shellEscaped(remotePath)

        // Create or truncate the remote file first.
        _ = try await session.execute(": > \(remoteEscaped)")

        guard !base64.isEmpty else { return }

        // Keep chunks reasonably small to avoid command length issues.
        // Must be divisible by 4 for base64 decoding.
        let chunkSize = 12_000
        var index = base64.startIndex

        while index < base64.endIndex {
            let endIndex = base64.index(index, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = String(base64[index..<endIndex])
            let chunkEscaped = shellEscaped(chunk)
            _ = try await session.execute("printf '%s' \(chunkEscaped) | base64 -d >> \(remoteEscaped)")
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
