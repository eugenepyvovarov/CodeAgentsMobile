//
//  SkillMarketplaceService.swift
//  CodeAgentsMobile
//
//  Purpose: Fetch skill marketplaces and download skill folders
//

import Foundation

struct SkillMarketplaceRepository: Hashable, Sendable {
    let owner: String
    let repo: String
}

struct SkillGitHubFolderReference: Hashable, Sendable {
    let owner: String
    let repo: String
    let branch: String
    let path: String
}

struct SkillMarketplaceListing: Hashable, Sendable {
    let owner: String
    let repo: String
    let branch: String
    let document: SkillMarketplaceDocument
}

struct SkillDownloadResult: Hashable, Sendable {
    let skillRoot: URL
    let cleanupRoot: URL
}

enum SkillMarketplaceError: LocalizedError, Sendable {
    case invalidGitHubURL
    case unsupportedGitHubURL
    case invalidRepositoryPath
    case invalidGitHubFolderURL
    case marketplaceNotFound
    case invalidMarketplaceDocument(String)
    case invalidPluginSource(String)
    case requestFailed(Int)
    case missingSkillFile
    case emptySkillFolder

    var errorDescription: String? {
        switch self {
        case .invalidGitHubURL:
            return "GitHub URL is invalid."
        case .unsupportedGitHubURL:
            return "Only https://github.com/{owner}/{repo} URLs are supported."
        case .invalidRepositoryPath:
            return "GitHub URL must include owner and repo names."
        case .invalidGitHubFolderURL:
            return "GitHub URL must be a folder URL like https://github.com/{owner}/{repo}/tree/{branch}/{path}."
        case .marketplaceNotFound:
            return "Marketplace manifest not found on main or master."
        case .invalidMarketplaceDocument(let message):
            return "Marketplace manifest is invalid: \(message)"
        case .invalidPluginSource(let message):
            return "Marketplace plugin source is invalid: \(message)"
        case .requestFailed(let status):
            return "Request failed with status \(status)."
        case .missingSkillFile:
            return "SKILL.md not found in the selected source."
        case .emptySkillFolder:
            return "Skill folder download produced no files."
        }
    }
}

struct SkillMarketplaceService {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared, decoder: JSONDecoder = JSONDecoder()) {
        self.session = session
        self.decoder = decoder
    }

    static func parseGitHubRepository(from raw: String) throws -> SkillMarketplaceRepository {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw SkillMarketplaceError.invalidGitHubURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw SkillMarketplaceError.unsupportedGitHubURL
        }
        guard url.host?.lowercased() == "github.com" else {
            throw SkillMarketplaceError.unsupportedGitHubURL
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 2 else {
            throw SkillMarketplaceError.invalidRepositoryPath
        }

        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        guard !owner.isEmpty, !repo.isEmpty else {
            throw SkillMarketplaceError.invalidRepositoryPath
        }

        return SkillMarketplaceRepository(owner: owner, repo: repo)
    }

    static func parseGitHubFolderURL(from raw: String) throws -> SkillGitHubFolderReference {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw SkillMarketplaceError.invalidGitHubURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw SkillMarketplaceError.unsupportedGitHubURL
        }
        guard url.host?.lowercased() == "github.com" else {
            throw SkillMarketplaceError.unsupportedGitHubURL
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = path.split(separator: "/").map { component in
            String(component).removingPercentEncoding ?? String(component)
        }
        guard components.count >= 5 else {
            throw SkillMarketplaceError.invalidGitHubFolderURL
        }
        guard components[2] == "tree" else {
            throw SkillMarketplaceError.invalidGitHubFolderURL
        }

        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        let branch = components[3]
        let pathComponents = components[4...]
        guard !owner.isEmpty, !repo.isEmpty, !branch.isEmpty, !pathComponents.isEmpty else {
            throw SkillMarketplaceError.invalidGitHubFolderURL
        }

        let folderPath = pathComponents.joined(separator: "/")
        return SkillGitHubFolderReference(owner: owner, repo: repo, branch: branch, path: folderPath)
    }

    func fetchMarketplace(owner: String, repo: String) async throws -> SkillMarketplaceListing {
        let branches = ["main", "master"]
        var lastStatus: Int?

        for branch in branches {
            let manifestURL = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/.claude-plugin/marketplace.json")!
            do {
                let text = try await fetchRawText(from: manifestURL)
                guard let data = text.data(using: .utf8) else {
                    throw SkillMarketplaceError.invalidMarketplaceDocument("Manifest encoding error")
                }
                let document = try decoder.decode(SkillMarketplaceDocument.self, from: data)
                return SkillMarketplaceListing(owner: owner, repo: repo, branch: branch, document: document)
            } catch let error as SkillMarketplaceError {
                if case .requestFailed(let status) = error, status == 404 {
                    lastStatus = status
                    continue
                }
                throw error
            }
        }

        if let status = lastStatus {
            throw SkillMarketplaceError.requestFailed(status)
        }
        throw SkillMarketplaceError.marketplaceNotFound
    }

    func fetchSkillContent(reference: SkillGitHubFolderReference) async throws -> String {
        let normalizedPath = normalizePath(reference.path)
        let url = URL(string: "https://raw.githubusercontent.com/\(reference.owner)/\(reference.repo)/\(reference.branch)/\(normalizedPath)/SKILL.md")!
        return try await fetchRawText(from: url, missingFileError: .missingSkillFile)
    }

    func fetchSkillContent(plugin: SkillMarketplacePlugin,
                           listing: SkillMarketplaceListing) async throws -> String {
        switch try resolvePluginSource(plugin.source, pluginRoot: listing.document.metadata?.pluginRoot, listing: listing) {
        case .github(let reference):
            return try await fetchSkillContent(reference: reference)
        case .url(let url):
            return try await fetchRawText(from: url, missingFileError: .missingSkillFile)
        }
    }

    func downloadSkillFolder(reference: SkillGitHubFolderReference) async throws -> SkillDownloadResult {
        let normalizedPath = normalizePath(reference.path)
        return try await downloadFolder(owner: reference.owner,
                                        repo: reference.repo,
                                        branch: reference.branch,
                                        pluginPath: normalizedPath)
    }

    func downloadSkillFolder(plugin: SkillMarketplacePlugin,
                             listing: SkillMarketplaceListing) async throws -> SkillDownloadResult {
        switch try resolvePluginSource(plugin.source, pluginRoot: listing.document.metadata?.pluginRoot, listing: listing) {
        case .github(let reference):
            return try await downloadSkillFolder(reference: reference)
        case .url(let url):
            return try await downloadSkillFolder(from: url)
        }
    }

    // MARK: - Private

    private enum ResolvedSource {
        case github(SkillGitHubFolderReference)
        case url(URL)
    }

    private func resolvePluginSource(_ source: SkillMarketplacePluginSource,
                                     pluginRoot: String?,
                                     listing: SkillMarketplaceListing) throws -> ResolvedSource {
        switch source {
        case .path(let value):
            let normalized = normalizePath(value)
            let root = pluginRoot.map { normalizePath($0) } ?? ""
            let resolvedPath: String
            if root.isEmpty || normalized.hasPrefix(root) {
                resolvedPath = normalized
            } else {
                resolvedPath = "\(root)/\(normalized)"
            }
            let reference = SkillGitHubFolderReference(owner: listing.owner,
                                                       repo: listing.repo,
                                                       branch: listing.branch,
                                                       path: resolvedPath)
            return .github(reference)
        case .github(let repo, let ref, let path):
            guard let path else {
                throw SkillMarketplaceError.invalidPluginSource("Missing path for GitHub source")
            }
            let repository = try parseRepositoryString(repo)
            let branch = ref?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBranch = (branch?.isEmpty == false) ? branch! : listing.branch
            let reference = SkillGitHubFolderReference(owner: repository.owner,
                                                       repo: repository.repo,
                                                       branch: resolvedBranch,
                                                       path: normalizePath(path))
            return .github(reference)
        case .url(let value):
            guard let url = URL(string: value) else {
                throw SkillMarketplaceError.invalidPluginSource("Invalid URL source")
            }
            return .url(url)
        case .unknown(let value):
            throw SkillMarketplaceError.invalidPluginSource("Unsupported source \(value)")
        }
    }

    private func parseRepositoryString(_ raw: String) throws -> SkillMarketplaceRepository {
        if raw.hasPrefix("http") {
            return try SkillMarketplaceService.parseGitHubRepository(from: raw)
        }
        let url = "https://github.com/\(raw)"
        return try SkillMarketplaceService.parseGitHubRepository(from: url)
    }

    private func normalizePath(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("./") {
            trimmed = String(trimmed.dropFirst(2))
        }
        while trimmed.hasPrefix("/") {
            trimmed = String(trimmed.dropFirst())
        }
        return trimmed
    }

    private struct GitTreeResponse: Decodable {
        let tree: [GitTreeEntry]
    }

    private struct GitTreeEntry: Decodable {
        let path: String
        let type: String
    }

    private func downloadFolder(owner: String,
                                repo: String,
                                branch: String,
                                pluginPath: String) async throws -> SkillDownloadResult {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("codeagents-skill-\(UUID().uuidString)", isDirectory: true)
        let skillRoot = tempRoot.appendingPathComponent("skill", isDirectory: true)
        try fileManager.createDirectory(at: skillRoot, withIntermediateDirectories: true)

        let entries = try await fetchGitTree(owner: owner, repo: repo, branch: branch)
        let prefix = pluginPath.hasSuffix("/") ? pluginPath : "\(pluginPath)/"
        let skipComponents: Set<String> = [
            ".git",
            ".github",
            ".claude-plugin",
            ".mcp-bundler",
            ".DS_Store",
            "Thumbs.db"
        ]

        let files = entries.filter { entry in
            guard entry.type == "blob" else { return false }
            guard entry.path.hasPrefix(prefix) else { return false }
            let relativePath = String(entry.path.dropFirst(prefix.count))
            guard !relativePath.isEmpty else { return false }
            let components = relativePath.split(separator: "/").map(String.init)
            return !components.contains { skipComponents.contains($0) }
        }

        guard !files.isEmpty else {
            throw SkillMarketplaceError.emptySkillFolder
        }

        for entry in files {
            let relativePath = String(entry.path.dropFirst(prefix.count))
            let destinationURL = skillRoot.appendingPathComponent(relativePath, isDirectory: false)
            let directoryURL = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let escapedPath = entry.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.path
            let rawURL = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(escapedPath)")!
            let (data, response) = try await session.data(from: rawURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw SkillMarketplaceError.requestFailed(status)
            }
            try data.write(to: destinationURL, options: .atomic)
        }

        return SkillDownloadResult(skillRoot: skillRoot, cleanupRoot: tempRoot)
    }

    private func downloadSkillFolder(from url: URL) async throws -> SkillDownloadResult {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("codeagents-skill-\(UUID().uuidString)", isDirectory: true)
        let skillRoot = tempRoot.appendingPathComponent("skill", isDirectory: true)
        try fileManager.createDirectory(at: skillRoot, withIntermediateDirectories: true)

        let fileName = url.lastPathComponent
        guard fileName.lowercased() == "skill.md" else {
            throw SkillMarketplaceError.invalidPluginSource("URL sources must point to SKILL.md")
        }

        let text = try await fetchRawText(from: url, missingFileError: .missingSkillFile)
        let destinationURL = skillRoot.appendingPathComponent("SKILL.md", isDirectory: false)
        try text.write(to: destinationURL, atomically: true, encoding: .utf8)
        return SkillDownloadResult(skillRoot: skillRoot, cleanupRoot: tempRoot)
    }

    private func fetchGitTree(owner: String, repo: String, branch: String) async throws -> [GitTreeEntry] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/git/trees/\(branch)"
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = components.url else {
            throw SkillMarketplaceError.invalidMarketplaceDocument("Invalid tree URL")
        }

        var request = URLRequest(url: url)
        request.setValue("CodeAgentsMobile", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SkillMarketplaceError.requestFailed(-1)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SkillMarketplaceError.requestFailed(httpResponse.statusCode)
        }

        let payload = try decoder.decode(GitTreeResponse.self, from: data)
        return payload.tree
    }

    private func fetchRawText(from url: URL, missingFileError: SkillMarketplaceError? = nil) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SkillMarketplaceError.requestFailed(-1)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 404, let missingFileError {
                throw missingFileError
            }
            throw SkillMarketplaceError.requestFailed(httpResponse.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SkillMarketplaceError.invalidMarketplaceDocument("Response decoding error")
        }
        return text
    }
}
