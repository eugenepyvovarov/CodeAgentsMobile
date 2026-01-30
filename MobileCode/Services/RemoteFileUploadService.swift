//
//  RemoteFileUploadService.swift
//  CodeAgentsMobile
//
//  Purpose: Upload local files into a remote agent project directory over SSH.
//

import Foundation

enum RemoteFileUploadError: LocalizedError {
    case missingLocalFile(String)

    var errorDescription: String? {
        switch self {
        case .missingLocalFile(let name):
            return "Missing local file: \(name)"
        }
    }
}

final class RemoteFileUploadService {
    static let shared = RemoteFileUploadService()

    private let sshService = ServiceManager.shared.sshService
    private let fileManager = FileManager.default

    private init() { }

    func uploadFile(localURL: URL, remotePath: String, in project: RemoteProject) async throws {
        guard fileManager.fileExists(atPath: localURL.path) else {
            throw RemoteFileUploadError.missingLocalFile(localURL.lastPathComponent)
        }

        let session = try await sshService.getConnection(for: project, purpose: .fileOperations)

        let parentDir = (remotePath as NSString).deletingLastPathComponent
        if !parentDir.isEmpty {
            try await ensureRemoteDirectory(parentDir, session: session)
        }

        try await uploadFileChunked(localURL: localURL, remotePath: remotePath, session: session)
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

    private func shellEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}

