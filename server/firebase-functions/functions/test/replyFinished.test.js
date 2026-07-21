/* eslint-disable @typescript-eslint/no-var-requires */
const assert = require("node:assert/strict");
const test = require("node:test");

const {LIMITS, normalizeBoundedString} = require("../lib/limits.js");
const {
  buildReplyFinishedDataPayload,
  excludeInstallation,
} = require("../lib/replyFinished.js");

const devices = [
  {installationId: "phone-a", fcmToken: "token-a"},
  {installationId: "phone-b", fcmToken: "token-b"},
];

test("missing exclusion preserves legacy delivery to every device", () => {
  const result = excludeInstallation(devices, null);

  assert.deepEqual(result, {included: devices, excluded: 0});
});

test("exclusion filters only the exact matching installation", () => {
  const result = excludeInstallation(devices, "phone-a");

  assert.deepEqual(result, {
    included: [{installationId: "phone-b", fcmToken: "token-b"}],
    excluded: 1,
  });
});

test("exclusion also filters stale registrations with the source token", () => {
  const duplicated = [
    {installationId: "phone-old", fcmToken: "token-a"},
    {installationId: "phone-new", fcmToken: "token-a"},
    {installationId: "tablet", fcmToken: "token-b"},
  ];

  assert.deepEqual(excludeInstallation(duplicated, "phone-new"), {
    included: [{installationId: "tablet", fcmToken: "token-b"}],
    excluded: 2,
  });
});

test("source token hint filters registrations when source installation is missing", () => {
  const staleRegistrations = [
    {installationId: "phone-old", fcmToken: "token-a"},
    {installationId: "tablet", fcmToken: "token-b"},
  ];

  assert.deepEqual(excludeInstallation(staleRegistrations, "phone-new", " token-a "), {
    included: [{installationId: "tablet", fcmToken: "token-b"}],
    excluded: 1,
  });
});

test("source token hint and stored source token are both excluded during rotation", () => {
  const rotatingRegistrations = [
    {installationId: "phone", fcmToken: "token-old"},
    {installationId: "phone-stale", fcmToken: "token-old"},
    {installationId: "phone-new", fcmToken: "token-new"},
    {installationId: "tablet", fcmToken: "token-b"},
  ];

  assert.deepEqual(excludeInstallation(rotatingRegistrations, "phone", "token-new"), {
    included: [{installationId: "tablet", fcmToken: "token-b"}],
    excluded: 3,
  });
});

test("delivery deduplicates tokens even without a source exclusion", () => {
  const duplicated = [
    {installationId: "phone-old", fcmToken: "token-a"},
    {installationId: "phone-new", fcmToken: "token-a"},
  ];

  assert.deepEqual(excludeInstallation(duplicated, null), {
    included: [{installationId: "phone-old", fcmToken: "token-a"}],
    excluded: 1,
  });
});

test("unknown or differently cased installation does not suppress a device", () => {
  assert.deepEqual(excludeInstallation(devices, "phone-c"), {
    included: devices,
    excluded: 0,
  });
  assert.deepEqual(excludeInstallation(devices, "PHONE-A"), {
    included: devices,
    excluded: 0,
  });
});

test("exclude_installation_id uses the existing installation ID limit", () => {
  assert.equal(
    normalizeBoundedString(
      "  phone-a  ",
      LIMITS.maxInstallationIdLength,
      "exclude_installation_id"
    ),
    "phone-a"
  );
  assert.throws(
    () => normalizeBoundedString(
      "x".repeat(LIMITS.maxInstallationIdLength + 1),
      LIMITS.maxInstallationIdLength,
      "exclude_installation_id"
    ),
    (error) => error.statusCode === 400 && error.message === "exclude_installation_id_too_long"
  );
});

test("exclude_fcm_token uses the existing FCM token limit", () => {
  assert.equal(
    normalizeBoundedString("  token-a  ", LIMITS.maxFcmTokenLength, "exclude_fcm_token"),
    "token-a"
  );
  assert.throws(
    () => normalizeBoundedString(
      "x".repeat(LIMITS.maxFcmTokenLength + 1),
      LIMITS.maxFcmTokenLength,
      "exclude_fcm_token"
    ),
    (error) => error.statusCode === 400 && error.message === "exclude_fcm_token_too_long"
  );
});

test("completion_id is bounded and passed through to FCM data", () => {
  const completionId = normalizeBoundedString(
    "completion-123",
    LIMITS.maxCompletionIdLength,
    "completion_id"
  );
  const payload = buildReplyFinishedDataPayload({
    serverKey: "server-key",
    cwd: "/workspace/project",
    conversationId: "session-123",
    renderableAssistantCount: 4,
    assistantMessageCursor: 3,
    cursorVersion: 2,
    completionId,
  });

  assert.deepEqual(payload, {
    type: "reply_finished",
    server_key: "server-key",
    cwd: "/workspace/project",
    conversation_id: "session-123",
    renderable_assistant_count: "4",
    assistant_message_cursor: "3",
    cursor_version: "2",
    completion_id: "completion-123",
  });
  assert.throws(
    () => normalizeBoundedString(
      "x".repeat(LIMITS.maxCompletionIdLength + 1),
      LIMITS.maxCompletionIdLength,
      "completion_id"
    ),
    (error) => error.statusCode === 400 && error.message === "completion_id_too_long"
  );
});

test("legacy count remains unchanged and cannot emit a cursor version alone", () => {
  const payload = buildReplyFinishedDataPayload({
    serverKey: "server-key",
    cwd: "/workspace/project",
    conversationId: "session-123",
    renderableAssistantCount: 7,
    assistantMessageCursor: null,
    cursorVersion: 2,
    completionId: null,
  });

  assert.deepEqual(payload, {
    type: "reply_finished",
    server_key: "server-key",
    cwd: "/workspace/project",
    conversation_id: "session-123",
    renderable_assistant_count: "7",
  });
});

test("legacy payload omits optional completion identity", () => {
  const payload = buildReplyFinishedDataPayload({
    serverKey: "server-key",
    cwd: "/workspace/project",
    conversationId: null,
    renderableAssistantCount: null,
    assistantMessageCursor: null,
    cursorVersion: null,
    completionId: null,
  });

  assert.deepEqual(payload, {
    type: "reply_finished",
    server_key: "server-key",
    cwd: "/workspace/project",
  });
});
