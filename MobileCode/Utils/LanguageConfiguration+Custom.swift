//
//  LanguageConfiguration+Custom.swift
//  CodeAgentsMobile
//
//  Purpose: Custom syntax highlighting configs for CodeEditorView
//

import Foundation
import LanguageSupport

extension LanguageConfiguration {
    private static func compileRegex(_ pattern: String) -> Regex<Substring>? {
        try? Regex(pattern, as: Substring.self)
    }

    static func python() -> LanguageConfiguration {
        let stringRegex = compileRegex(#"\"\"\"[\s\S]*?\"\"\"|'''[\s\S]*?'''|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)
        let numberRegex = compileRegex(#"\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#)
        let identifierRegex = compileRegex(#"[A-Za-z_][A-Za-z0-9_]*"#)
        let keywords = [
            "False", "True", "None",
            "and", "as", "assert", "async", "await",
            "break", "class", "continue",
            "def", "del",
            "elif", "else", "except",
            "finally", "for", "from",
            "global",
            "if", "import", "in", "is",
            "lambda",
            "match",
            "nonlocal", "not",
            "or",
            "pass",
            "raise", "return",
            "try",
            "while", "with",
            "yield",
            "case"
        ]

        return LanguageConfiguration(
            name: "Python",
            supportsSquareBrackets: true,
            supportsCurlyBrackets: true,
            stringRegex: stringRegex,
            characterRegex: nil,
            numberRegex: numberRegex,
            singleLineComment: "#",
            nestedComment: nil,
            identifierRegex: identifierRegex,
            operatorRegex: nil,
            reservedIdentifiers: keywords,
            reservedOperators: []
        )
    }

    static func markdown() -> LanguageConfiguration {
        let stringRegex = compileRegex(#"```[\s\S]*?```|`[^`\n]+`"#)

        return LanguageConfiguration(
            name: "Markdown",
            supportsSquareBrackets: true,
            supportsCurlyBrackets: false,
            stringRegex: stringRegex,
            characterRegex: nil,
            numberRegex: nil,
            singleLineComment: "#",
            nestedComment: nil,
            identifierRegex: nil,
            operatorRegex: nil,
            reservedIdentifiers: [],
            reservedOperators: []
        )
    }
}
