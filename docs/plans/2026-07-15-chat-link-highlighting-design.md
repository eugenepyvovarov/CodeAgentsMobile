# Chat Link Highlighting Design

## Problem

Assistant answers are rendered through `FullMarkdownTextView`, whose inline
blocks ultimately use `MarkdownTextView`. SwiftUI's Markdown parser preserves
explicit Markdown links, but the renderer applies the bubble's foreground
color to the entire attributed string. That makes links visually
indistinguishable from surrounding text. Plain `https://` URLs are also not
guaranteed to receive a link attribute, leaving common assistant output
unclickable.

## Design

`MarkdownTextView` will remain the single rendering entry point for paragraphs,
headings, list items, and table cells. Its attributed-string builder will first
parse Markdown, then detect web URLs in the rendered text. Explicit Markdown
links keep their original destinations, while bare HTTP and HTTPS URLs receive
link attributes. Every link run receives the app accent color and a single
underline after the base bubble color is applied, so the distinction remains
clear in both assistant and user bubble color schemes.

The view will install a scoped `OpenURLAction`. HTTP and HTTPS taps are handed
to `UIApplication.shared.open`, which leaves the app and delegates to the
system's external URL handler. Other schemes retain SwiftUI's system behavior.
Invalid or unsupported URLs are not synthesized into links.

## Error Handling and Verification

Markdown parsing continues to fall back to plain attributed text. URL detector
creation is best-effort; a detector failure must never prevent an answer from
rendering. The detector works on the rendered string, so Markdown syntax and
code-block parsing remain unchanged.

Focused tests will verify that explicit Markdown links preserve their target,
bare web URLs become links, link runs are underlined and accent-colored, and
ordinary text remains unlinked. Validation will run those tests, the repository
CI entry point, and a simulator build. Existing unrelated worktree changes will
remain untouched.
