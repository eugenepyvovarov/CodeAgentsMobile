# Chat Widgets Spec + Plan (codeagents_ui)

## spec.md

### Overview
Add support for render-only “mini app” widgets in chat messages using a structured JSON payload embedded in assistant text.

Claude (and Claude Code skills) will emit one or more fenced blocks:

```codeagents-ui
{ "type": "codeagents_ui", "version": 1, "elements": [ ... ] }
```

The iOS app parses and renders these blocks as native SwiftUI elements (cards, images, galleries, videos, tables, charts). No MCP/tools required.

### Goals
- Support `codeagents_ui` blocks in assistant messages (multiple blocks, ordered).
- Render both:
  1) normal assistant markdown text and
  2) any `codeagents_ui` blocks
  in the same message, preserving order.
- Media sources supported:
  - `https` URLs
  - remote files in the connected server’s project folder (project-root-relative paths only)
  - base64 inline images (for generated images)
- Charts support (v1): bar, line, pie, heatmap (GitHub-style activity grid).
- Robustness:
  - streaming-safe parsing (only render closed fences)
  - strict validation/whitelisting
  - skip invalid blocks/elements/media silently (no noisy UX)
- Temporary caching only (no persistence across launches).

### Non-goals (v1)
- Interactive widgets (forms/buttons that send events back to the model).
- Arbitrary HTML/JS app embedding (MCP Apps-style UI).
- HTTP URLs (https only).
- Base64 video.
- User-visible error widgets for invalid blocks/media (skip instead).

---

## UX / Rendering Behavior

### Message rendering rules
- If an assistant message contains any valid `codeagents_ui` block(s), the bubble renders:
  - markdown text segments (normal assistant text), and
  - rendered UI segments (from `codeagents_ui`)
  in the same order they appear in the message text.
- Only assistant messages are eligible for `codeagents_ui` rendering; ignore any blocks in user messages.

### Multiple UI blocks
- Multiple `codeagents_ui` blocks per message are allowed.
- Each block is parsed/validated independently; invalid blocks are ignored.

### Failure handling (skip)
- Invalid JSON / invalid schema → skip that block.
- Unsupported/invalid element → skip that element only.
- Media load failure / missing file / too large / blocked path → skip that element only.

### Media interactions
- Images and gallery thumbnails render inline in chat.
- Tap an image to open a full-screen preview.
- Tap a gallery image to open a full-screen gallery viewer starting at that image.
- Tap a video to open a full-screen preview.
- If preview assets can’t be prepared, taps are a no-op (no error UI).

### Streaming tolerance
- Do not attempt to render a `codeagents_ui` block until:
  - the closing fence (```) is present, and
  - JSON parses and validates.

---

## Transport Format (no tools / no MCP)

### Fence label
- The assistant embeds JSON in a fenced code block whose info string is exactly: `codeagents-ui`.
- The JSON inside the fence must be a single JSON object (not an array).
Note: fence label uses a dash (`codeagents-ui`), while JSON `type` uses an underscore (`codeagents_ui`). Both must match exactly.

Example:
```codeagents-ui
{
  "type": "codeagents_ui",
  "version": 1,
  "title": "Build Summary",
  "elements": [
    { "type": "card", "id": "c1", "title": "Summary", "content": [
      { "type": "markdown", "id": "m1", "text": "All tests passed." }
    ]}
  ]
}
```

---

## `codeagents_ui` v1 Data Contract

### Envelope
Required fields:
- `type`: `"codeagents_ui"`
- `version`: `1`
- `elements`: `[UIElement]`

Optional:
- `title`: string

Unknown fields are ignored.

### Common element fields
All elements require:
- `type`: string
- `id`: string (stable identifier)

Unknown element `type`s are ignored.

---

## Supported Elements (whitelist)

### `card`
Container for grouping elements.

Fields:
- `type`: `"card"`
- `id`: string
- `title`: string? (optional)
- `subtitle`: string? (optional)
- `content`: `[UIElement]`? (optional; default `[]`)

### `markdown`
Markdown text rendered with existing markdown renderer.

Fields:
- `type`: `"markdown"`
- `id`: string
- `text`: string

### `image`
Image rendered from a `MediaSource`.

Fields:
- `type`: `"image"`
- `id`: string
- `source`: `MediaSource`
- `alt`: string? (optional)
- `caption`: string? (optional)
- `aspectRatio`: number? (optional)

### `gallery`
Horizontal gallery of images.

Fields:
- `type`: `"gallery"`
- `id`: string
- `images`: `[ImageElement]` (each must be an `image` element)
- `caption`: string? (optional)

### `video`
Video player rendered from a `MediaSource`.

Fields:
- `type`: `"video"`
- `id`: string
- `source`: `MediaSource` (https or project_file only; no base64 video)
- `poster`: `MediaSource`? (optional; image-only)
- `caption`: string? (optional)

### `table`
Table rendered with markdown cells.

Fields:
- `type`: `"table"`
- `id`: string
- `columns`: `[string]`
- `rows`: `[[string]]` (cells are interpreted as markdown)
- `caption`: string? (optional)

Normalization rules:
- If a row has fewer cells than `columns.count`, pad with empty strings.
- If a row has more cells than `columns.count`, truncate.

### `chart`
Charts rendered with Swift Charts (iOS 18+) except heatmap (custom SwiftUI grid).

Fields (common):
- `type`: `"chart"`
- `id`: string
- `chartType`: `"bar" | "line" | "pie" | "heatmap"`
- `title`: string? (optional)
- `subtitle`: string? (optional)

#### Bar / Line
Fields:
- `x`: `[string]` (x-axis labels; strings only in v1)
- `series`: `[ChartSeries]` (multi-series supported)

`ChartSeries`:
- `name`: string? (optional; legend label)
- `values`: `[number | null]` (null indicates a gap/missing value)
- `color`: string? (optional; `#RRGGBB`)

Normalization rules:
- If `values.count != x.count`, truncate to the shorter length.

#### Pie
Fields:
- `slices`: `[PieSlice]`
- `valueDisplay`: `"none" | "value" | "percent" | "both"` (default: `"percent"`)

`PieSlice`:
- `label`: string
- `value`: number
- `color`: string? (optional; `#RRGGBB`)

#### Heatmap (GitHub-style)
Fields:
- `days`: `[HeatmapDay]`
- `maxValue`: number? (optional; used for auto-bucketing values)
- `levels`: number? (optional; default: `5`, range `2..9`)
- `palette`: `[string]`? (optional; hex colors, length >= levels)
- `weekStart`: `"sun" | "mon"` (default: `"mon"`)

`HeatmapDay`:
- `date`: `"YYYY-MM-DD"` (required)
- `value`: number? (optional)
- `level`: number? (optional, `0..levels-1`)

Rules:
- If both `level` and `value` are provided, `level` wins.
- If only `value` is provided, it is bucketed into `levels` using `maxValue` (or max of provided values).
- Missing dates render as level `0`.

---

## MediaSource v1

### `project_file` (connected server)
Remote file in the connected server’s project folder.

```json
{ "kind": "project_file", "path": "relative/to/project/root.png" }
```

Rules:
- Strictly project-root-relative (no leading `/`).
- Disallow path traversal: reject any segment `..`.
- Disallow `~`.
- Normalize separators to `/`.

Resolution:
- `remotePath = "\(project.path)/\(path)"`

Size check:
- Perform a remote size check before download (e.g., `stat` via SSH). If size exceeds limits, skip.

### `url` (https only)
```json
{ "kind": "url", "url": "https://example.com/image.png" }
```

Rules:
- HTTPS only.

### `base64` (images only)
```json
{ "kind": "base64", "mediaType": "image/png", "data": "<base64>" }
```

Rules:
- `mediaType` must be `image/*`.
- Decode size limits apply (see Limits).

---

## Supported File Types (v1)

### Images
- `png`, `jpg/jpeg`, `webp`, `gif`, `heic`

### Video
- `mp4`, `mov`

Notes:
- For base64: images only.
- For `url`: https only.

---

## Limits (v1)
- `project_file` images: max **25 MB** per file.
- `project_file` videos: max **200 MB** per file.
- base64 images: max **1 MB decoded bytes** per image (to avoid inflating chat storage).

If any limit is exceeded, skip the element.

### Client caps (v1 hard limits)
To avoid UI/perf blowups even if the model misbehaves:
- Max UI blocks per message: **3**
- Max elements per block: **40**
- Max gallery images: **12**
- Max table cells: **400** (rows * columns)
- Max chart points per series: **200**
- Max chart series: **6**
- Max heatmap days: **400**

---

## System Prompt Injection (Option A)
We instruct “all future skills / future chats” by injecting a stable system prompt into proxy requests.

Rationale:
- No per-skill updates required.
- Works for normal chat + skills uniformly.
- Keeps the contract centralized in the app.

Implementation:
- `ClaudeCodeService.sendMessageViaProxy` builds `ProxyStreamRequest(systemPrompt: ...)` (currently `nil`).
- Provide a concise contract prompt that:
  - explains when to use `codeagents_ui`,
  - provides minimal schema + examples,
  - enforces https-only URLs and project-root-relative `project_file.path`,
  - instructs strict JSON inside the fenced block (no comments/trailing commas),
  - encourages small base64 payloads and using project files when possible.

### Injected `system_prompt` (v1 draft)

```text
You are replying in CodeAgents Mobile. The app can render UI widgets embedded in assistant messages.

FORCE-WIDGETS:
Whenever you present any of the following, you MUST also emit one or more UI blocks:
- images (1+), galleries (2+ images), videos
- tables / structured rows+columns
- charts (bar/line/pie/heatmap) for numeric data

Do NOT duplicate full tables/chart datasets in markdown. In markdown, write a short explanation and refer to the widget(s).

UI BLOCK FORMAT (required):
- Emit UI blocks as fenced code blocks with info string exactly: codeagents-ui
- Inside the fence: strict JSON only (no comments, no trailing commas, no prose).
- You may emit multiple codeagents-ui blocks in one message.
- If you output a codeagents-ui block, do not also output another markdown code block containing the same JSON elsewhere.
- codeagents-ui is NOT a tool. Never call tools named codeagents-ui or codeagents_ui.

ENVELOPE (v1):
{ "type":"codeagents_ui", "version":1, "title":"optional", "elements":[ ... ] }

ELEMENTS (v1 whitelist):
card, markdown, image, gallery, video, table, chart
- Every element MUST have a unique "id" (unique within that UI block).

MEDIA SOURCES (v1):
- HTTPS URL only:
  { "kind":"url", "url":"https://..." }   (never http)

- Remote project file on the connected server, STRICTLY relative to project root:
  { "kind":"project_file", "path":"relative/path.png" }
  Never use absolute paths, "~", or ".." segments.
  Only reference project_file paths that exist (or that you created earlier). No guessing.

- Base64 image only if you truly have real bytes (never fabricate):
  { "kind":"base64", "mediaType":"image/png", "data":"<base64>" }

AUTO-WIDGET HEURISTICS:
- 1 image -> image
- 2+ images -> gallery
- structured rows/columns -> table (cells are markdown strings)
- numeric series over x labels -> bar/line chart
- category shares -> pie chart
- activity tracking over dates -> heatmap chart (GitHub-style)

TABLE:
{ "type":"table","id":"t1","columns":[...],"rows":[[...],[...]],"caption":"optional" }

CHART:
- bar/line:
  { "type":"chart","id":"ch1","chartType":"line","x":[...],
    "series":[{ "name":"optional","values":[number|null,...],"color":"#RRGGBB" }] }
  Use null for gaps. x labels are strings.
- pie:
  { "type":"chart","id":"ch2","chartType":"pie",
    "slices":[{"label":"A","value":12.5,"color":"#RRGGBB"}],
    "valueDisplay":"none|value|percent|both" }  (default percent)
- heatmap:
  { "type":"chart","id":"ch3","chartType":"heatmap",
    "days":[{"date":"YYYY-MM-DD","value":3},{"date":"YYYY-MM-DD","level":2}],
    "maxValue":10,"levels":5,"palette":["#ebedf0","#9be9a8","#40c463","#30a14e","#216e39"],
    "weekStart":"mon" }

FAIL-SAFE:
If you are not confident the JSON is valid, omit the UI block and respond in normal markdown.
Never output invalid JSON inside a codeagents-ui fence.
```

---

## Test Plan (v1)

### Unit tests
- Extractor:
  - finds multiple `codeagents-ui` fences in-order
  - ignores unclosed fences (streaming)
  - ignores invalid JSON blocks
- Validation:
  - rejects wrong `type` / wrong `version`
  - rejects/ignores unknown element types
  - enforces `https` only
  - enforces strict relative paths (no `..`, `/`, `~`)
  - enforces media limits
- Charts:
  - supports multi-series bar/line
  - supports `null` gaps
  - pie `valueDisplay` default behavior
- Tables:
  - pads/truncates row length to columns
  - cells rendered as markdown

### Manual tests
- Assistant message with text + 2 UI blocks renders both in-order.
- `project_file` image loads via SSH download, shows, and is cleaned up on view dismiss.
- Missing `project_file` is skipped silently.
- base64 image renders.
- https image renders.
- video renders from `project_file` and from `https`.
- bar/line/pie/heatmap charts display and scroll smoothly inside chat.

---

## plan.md

### Progress: 0%

### Confirmed decisions
- Transport: embedded ```codeagents-ui``` fenced blocks; no tools/MCP.
- Rendering: render both assistant markdown text and UI blocks (in-order).
- Multiple UI blocks per message: yes.
- `project_file.path`: strictly relative to project root only.
- URLs: https only.
- Media sources: https url | project_file | base64 (images only).
- Cache: temp only.
- Missing/invalid: skip (no user-visible error UI).
- Tables: cells rendered as markdown.
- Charts: bar + line + pie; multi-series for bar/line; `null` allowed as gaps; `x` labels are strings only.
- Pie schema: accepted; `valueDisplay` default is `percent`.
- File types: images (png/jpg/webp/gif/heic), videos (mp4/mov).
- Limits: project_file image 25MB, video 200MB, base64 decoded 1MB.

### Tasks
🟥 To Do ☐ Define `codeagents_ui` models + strict validation (envelope, elements, media sources, charts)  
🟥 To Do ☐ Implement `codeagents-ui` fenced block extractor (multiple blocks; ordered segments; streaming-safe)  
🟥 To Do ☐ Implement project-relative path sanitizer for `project_file.path` (reject traversal/absolute/~)  
🟥 To Do ☐ Add temp media loader:
  - `project_file` download via SSH into temp dir
  - base64 decode into temp file
  - enforce size limits + file type allowlist
  - clean up temp files on view lifecycle end  
🟥 To Do ☐ Add SwiftUI renderer for elements:
  - card
  - markdown
  - image
  - gallery
  - video
  - table (markdown cells)
  - chart (bar/line/pie/heatmap)  
🟥 To Do ☐ Integrate renderer into chat:
  - assistant text blocks (structured + plain message bubbles)
  - preserve non-UI markdown text segments while stripping UI JSON from visible text  
🟥 To Do ☐ Inject global system prompt into proxy requests (`system_prompt`) describing the `codeagents_ui` contract + examples  
🟥 To Do ☐ Add unit tests for extractor/validator/path sanitizer/limits/chart normalization  
🟥 To Do ☐ Manual QA on simulator/device for large chats, galleries, and video playback performance

### File-level changes

#### Add
- `MobileCode/Models/CodeAgentsUI.swift` (models + validation)
- `MobileCode/Utils/CodeAgentsUIBlockExtractor.swift` (fence parsing + segment output)
- `MobileCode/Utils/ProjectRelativePathSanitizer.swift` (safe relative path rules)
- `MobileCode/Services/Chat/ChatMediaLoader.swift` (download/decode + temp cache)
- `MobileCode/Views/Chat/CodeAgentsUIRendererView.swift` (top-level renderer)
- `MobileCode/Views/Chat/Elements/*` (element subviews as needed)
- `MobileCodeTests/CodeAgentsUIBlockExtractorTests.swift`
- `MobileCodeTests/CodeAgentsUIValidationTests.swift`

#### Modify
- `MobileCode/Services/ClaudeCodeService.swift` (set proxy `systemPrompt` to the injected contract string)
- `MobileCode/Views/Components/TextBlockView.swift` (segment rendering: markdown + UI blocks)
- `MobileCode/Views/Chat/ChatView.swift` (ensure plain assistant messages use the segmented renderer as well)

#### Keep
- Tool rendering: `ToolUseView`, `ToolResultView`, `ContentBlockView` (no behavior changes required for v1).

### System prompt (content outline)
- “If you have renderable structured output (tables/charts/media), include one or more `codeagents_ui` blocks.”
- Schema summary + short examples (image/gallery/table/chart).
- Enforce:
  - https only for URLs
  - `project_file.path` relative to project root
  - base64 images only, keep small
  - strict JSON inside the fence (no comments / no trailing commas)
