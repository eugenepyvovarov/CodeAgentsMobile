# Photo & Camera Attachments (Mobile)

## Summary
Add Photo Library selection and Camera capture as attachment sources across Chat, Regular Tasks, and File Browser uploads. Images are staged locally, downscaled, encoded to JPEG, and uploaded through existing pipelines. Chips show a photo icon with the filename (no thumbnails).

## Goals
- Multi-select Photo Library attachments.
- Single photo capture from Camera.
- Reuse existing file-attachment upload flow.
- Consistent JPEG output with max dimension 2048px and quality 0.85.
- Preserve original filenames where available; generate a timestamp name otherwise.
- Clear chat chips immediately after send.

## Scope
- Chat composer (`ChatDetailView`)
- Regular task editor (`RegularTaskEditorView`)
- File browser upload menu (`FileBrowserView`)

## Approach
### Photo Library
Use `PhotosPicker` (PhotosUI) with multi-select. For each selection:
- Load a file representation when available to read original filename.
- Convert image to JPEG, downscale, and stage to temp.
- Add to attachments or upload directly (file browser).

### Camera
Use `UIImagePickerController` with camera source to capture a single image. Stage the result via the same image pipeline.

### Staging + Upload
Shared `ImageAttachmentStager` handles normalization, resizing, JPEG encoding, and temp file creation. Upload continues via existing services:
- Chats/Tasks → `ChatAttachmentUploadService` to `.claude/attachments`
- File browser → `RemoteFileUploadService` to current directory

## Error Handling
- Partial successes allowed: successful photos are added/uploaded; the first error is surfaced to the user.
- Camera unavailable: show a user-facing error.

## Testing / QA
- Multi-select photo picker adds multiple attachments.
- Camera capture adds one attachment and uploads correctly.
- Send clears chat chips immediately.
- Task save uploads references.
- File browser uploads place images in the active directory and refresh.
