//
//  SystemEmojiTextField.swift
//  CodeAgentsMobile
//
//  Purpose: Present the system emoji keyboard (no public EmojiPicker API on iOS).
//

import SwiftUI
import UIKit

/// UIKit text field that prefers the system emoji keyboard input mode.
/// Apple does not ship a public `EmojiPicker` for third-party apps; this is the
/// supported-adjacent path (same keyboard Messages uses for emoji).
struct SystemEmojiTextField: UIViewRepresentable {
    @Binding var text: String
    var isFocused: Binding<Bool>?
    var onCommit: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> EmojiPreferringTextField {
        let field = EmojiPreferringTextField(frame: .zero)
        field.delegate = context.coordinator
        field.textAlignment = .center
        field.font = .systemFont(ofSize: 36)
        field.backgroundColor = .clear
        field.tintColor = UIColor.tintColor
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .done
        // Helps iOS 13+ pick the emoji input mode when available.
        field.textInputContextIdentifierValue = ""
        field.accessibilityIdentifier = "agent-avatar-emoji-field"
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ uiView: EmojiPreferringTextField, context: Context) {
        context.coordinator.parent = self
        // Don't stomp in-progress typing from SwiftUI unless the binding really changed
        // from outside (apply success / clear).
        if uiView.text != text, !uiView.isFirstResponder || text.isEmpty || uiView.text?.isEmpty == true {
            uiView.text = text
        } else if !uiView.isFirstResponder, uiView.text != text {
            uiView.text = text
        }
        DispatchQueue.main.async {
            if let isFocused, isFocused.wrappedValue, !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            } else if let isFocused, !isFocused.wrappedValue, uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SystemEmojiTextField

        init(_ parent: SystemEmojiTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ textField: UITextField) {
            // Single-emoji field: always keep only the latest grapheme.
            let normalized = AgentAvatarService.normalizeEmoji(textField.text ?? "")
            // If the user appended a second emoji, prefer the *last* grapheme.
            let latest = Self.latestEmoji(from: textField.text ?? "") ?? normalized
            apply(latest, to: textField)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused?.wrappedValue = true
            // Select existing emoji so the next keystroke replaces it cleanly.
            if let text = textField.text, !text.isEmpty {
                textField.selectedTextRange = textField.textRange(
                    from: textField.beginningOfDocument,
                    to: textField.endOfDocument
                )
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused?.wrappedValue = false
            let latest = Self.latestEmoji(from: textField.text ?? "")
                ?? AgentAvatarService.normalizeEmoji(textField.text ?? "")
            apply(latest, to: textField)
            if !latest.isEmpty {
                parent.onCommit?(latest)
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        /// Single-emoji field: each insertion **replaces** the current glyph.
        /// (Appending then taking `prefix(1)` left the first emoji stuck.)
        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string.isEmpty {
                // Deletion — clear.
                apply("", to: textField)
                return false
            }

            // Prefer the newly typed/pasted emoji (last grapheme if paste is multi).
            let incoming = Self.latestEmoji(from: string)
                ?? AgentAvatarService.normalizeEmoji(string)
            guard !incoming.isEmpty else { return false }

            apply(incoming, to: textField)
            parent.onCommit?(incoming)
            return false
        }

        private func apply(_ value: String, to textField: UITextField) {
            if textField.text != value {
                textField.text = value
            }
            if parent.text != value {
                parent.text = value
            }
        }

        /// Last extended grapheme cluster (so typing a second emoji wins).
        private static func latestEmoji(from raw: String) -> String? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let last = trimmed.last else { return nil }
            // `String.Element` is Character = extended grapheme cluster.
            return String(last)
        }
    }
}

/// Prefers the system emoji keyboard when the user has it installed.
final class EmojiPreferringTextField: UITextField {
    /// Exposed so representable can set the iOS 13+ context id workaround.
    var textInputContextIdentifierValue: String? = ""

    override var textInputContextIdentifier: String? {
        textInputContextIdentifierValue
    }

    override var textInputMode: UITextInputMode? {
        let modes = UITextInputMode.activeInputModes
        if let emoji = modes.first(where: { $0.primaryLanguage == "emoji" }) {
            return emoji
        }
        return super.textInputMode
    }
}
