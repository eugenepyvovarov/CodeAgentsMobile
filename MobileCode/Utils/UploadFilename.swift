//
//  UploadFilename.swift
//  CodeAgentsMobile
//
//  Purpose: Human-friendly remote filenames for uploads (avoid PHAsset IDs).
//

import Foundation

enum UploadFilename {
    /// True when a name looks like a PhotoKit local identifier / opaque asset id.
    static func isLikelyAssetIdentifier(_ raw: String) -> Bool {
        let base = (raw as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.count >= 20 else { return false }
        // Asset IDs are long hex/dash strings with no real words.
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        guard base.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return base.contains("-")
    }

    /// Build a safe, readable filename with extension.
    static func humanDisplayName(
        preferred: String?,
        fallbackStem: String,
        preferredExtension: String
    ) -> String {
        let ext = preferredExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"

        if let preferred, !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let last = (preferred as NSString).lastPathComponent
            if !isLikelyAssetIdentifier(last) {
                let base = (last as NSString).deletingPathExtension
                let cleaned = sanitizeStem(base)
                if !cleaned.isEmpty {
                    return cleaned + extSuffix
                }
            }
        }

        let stamp = timestampFormatter.string(from: Date())
        let stem = sanitizeStem(fallbackStem).isEmpty ? "File" : sanitizeStem(fallbackStem)
        return "\(stem)-\(stamp)\(extSuffix)"
    }

    static func unique(originalName: String, taken: Set<String>) -> String {
        guard taken.contains(originalName) else { return originalName }

        let nsName = originalName as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let extSuffix = ext.isEmpty ? "" : ".\(ext)"

        var suffix = 2
        while true {
            let candidate = "\(base)-\(suffix)\(extSuffix)"
            if !taken.contains(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    static func sanitizeStem(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                result.append(Character(scalar))
            } else if scalar == " " {
                result.append("-")
            } else {
                result.append("-")
            }
        }

        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
