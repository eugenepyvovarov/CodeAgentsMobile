# Files Preview + Share + Editor Design

Date: 2026-01-29

## Summary

Enhance the Files section to preview images/video, share any file via the iOS share sheet, and edit text/code files with syntax highlighting. Non-text files use Quick Look. Text/code files open a CodeEditorView-based editor with save back to the remote host.

## Goals

- Preview images/video and other supported formats in Quick Look.
- Share or “download” any file using the standard iOS share sheet.
- Provide a syntax-highlighted editor for text/code files with save-to-remote.
- Keep the Files list responsive while downloads occur.

## Non-goals

- Offline caching or a persistent local downloads library.
- A custom media viewer beyond Quick Look.
- Full project-wide multi-file editing.

## UX Flow

- Tap a file:
  - Text/code extensions open the editor sheet.
  - All other files open a Quick Look preview sheet.
- Context menu on any file includes “Share…” which downloads the file to a temp URL then presents the share sheet.
- Share button is also available in the sheet toolbar for both editor and Quick Look preview.

## File Type Routing

- Allowlist by extension for text/code (e.g., swift, py, js, ts, json, md, txt, yaml, yml, toml, sh, rb, go, rs, c, h, cpp, java, kt, sql).
- Everything else is treated as non-text and routed to Quick Look.

## Architecture

- `FileBrowserView` continues to own selection; sheet content is delegated to a new `FilePreviewSheet`.
- `FileBrowserViewModel` gains:
  - `downloadFile(node:) -> URL` to download a remote file to `FileManager.default.temporaryDirectory`.
  - `saveFileContent(path:content:)` to write edited text back to the remote file.
- `FileNode` adds a computed `isTextFile` (by extension) and `fileExtension` helper.
- `ShareSheetPresenter` (or a small helper) presents `UIActivityViewController` and cleans up temp files on completion.
- Quick Look is bridged with a `QLPreviewController` representable for iOS.

## Data Flow

1. User taps a file row.
2. If text:
   - `loadFileContent` fetches the file content from SSH.
   - `CodeEditorView` displays content with syntax highlighting.
   - Save writes content back over SSH using base64 transfer and refreshes the list.
3. If non-text:
   - `downloadFile` fetches remote file to a temp URL.
   - Quick Look presents preview.
4. Share uses the temp URL; if not already present, it triggers `downloadFile` first.

## Error Handling & Edge Cases

- Read failures show a “Failed to load file” state in the editor.
- Save failures show an alert; edits remain in place for retry.
- Quick Look download failures show a retry state; share remains available if a download succeeds.
- Large files: warn before downloading if size > 250MB (optional cancel/continue).
- Temp file cleanup occurs on share completion or sheet dismissal.

## Testing

- Unit tests for `FileNode.isTextFile` allowlist.
- Manual QA:
  - Share a binary file from context menu.
  - Preview a video/image in Quick Look.
  - Edit and save a `.swift` file; verify remote contents updated.
  - Attempt a 250MB+ download and verify warning.
