const assert = require("node:assert/strict");
const {readFileSync} = require("node:fs");
const {join} = require("node:path");
const test = require("node:test");

const {sanitizeNotificationPreview} = require("../lib/notificationPreview.js");

const fixturePath = join(__dirname, "fixtures", "pushNotificationPreview.json");
const {issueShapedPreview} = JSON.parse(readFileSync(fixturePath, "utf8"));

test("keeps prose before an issue-shaped CodeAgents UI block", () => {
  assert.equal(
    sanitizeNotificationPreview(issueShapedPreview),
    "Checked all stored domains with threshold `10` days. All sites are healthy and no alerts were triggered.",
  );
});

test("removes multiple CodeAgents UI blocks and preserves prose order", () => {
  const preview = [
    "First update.",
    "```codeagents-ui compact",
    "{\"type\":\"codeagents_ui\",\"title\":\"Hidden one\"}",
    "```",
    "Second update.",
    "```codeagents_ui",
    "{\"elements\":[{\"text\":\"Hidden two\"}]}",
    "```",
    "Final update.",
  ].join("\n");

  assert.equal(sanitizeNotificationPreview(preview), "First update. Second update. Final update.");
});

test("uses an empty-preview signal when only CodeAgents UI blocks remain", () => {
  const preview = [
    "```codeagents_ui",
    "{\"type\":\"codeagents_ui\",\"title\":\"Render-only\"}",
    "```",
  ].join("\n");

  assert.equal(sanitizeNotificationPreview(preview), null);
});

test("drops an unclosed CodeAgents UI fence through the end of the preview", () => {
  const preview = [
    "Human-readable summary.",
    "```codeagents-ui",
    "{\"type\":\"codeagents_ui\",\"title\":\"Unclosed\"}",
  ].join("\n");

  assert.equal(sanitizeNotificationPreview(preview), "Human-readable summary.");
});

test("preserves non-CodeAgents fenced content", () => {
  const preview = [
    "Here is the command:",
    "```json",
    "{\"type\":\"not_codeagents_ui\"}",
    "```",
    "Done.",
  ].join("\n");

  assert.equal(
    sanitizeNotificationPreview(preview),
    "Here is the command: ```json {\"type\":\"not_codeagents_ui\"} ``` Done.",
  );
});

test("truncates after CodeAgents UI block removal", () => {
  const preview = [
    "Alpha beta gamma.",
    "```codeagents-ui",
    "{\"title\":\"This hidden block would otherwise consume the preview limit\"}",
    "```",
    "Delta epsilon zeta.",
  ].join("\n");

  assert.equal(sanitizeNotificationPreview(preview, 24), "Alpha beta gamma. Delta…");
});
