/* eslint-disable @typescript-eslint/no-var-requires */
const assert = require("node:assert/strict");
const test = require("node:test");

const {
  LIMITS,
  normalizeBool,
  normalizeBoundedString,
  validatePushSecret,
} = require("../lib/limits.js");
const {enforceRequestRateLimits, enforceNewServerNamespaceLimit, resetRateLimitsForTests} = require(
  "../lib/rateLimit.js",
);

test("validatePushSecret rejects short or low-entropy secrets", () => {
  assert.throws(() => validatePushSecret(""), (err) => err.statusCode === 401);
  assert.throws(() => validatePushSecret("short"), (err) => err.statusCode === 401);
  assert.throws(() => validatePushSecret("a".repeat(32) + "!"), (err) => err.statusCode === 401);

  const ok = "Ab1+/" + "x".repeat(30);
  assert.equal(ok.length >= LIMITS.minSecretLength, true);
  assert.doesNotThrow(() => validatePushSecret(ok));
});

test("normalizeBoundedString enforces max length", () => {
  assert.equal(normalizeBoundedString("  hi  ", 10, "cwd"), "hi");
  assert.throws(() => normalizeBoundedString("x".repeat(11), 10, "cwd"), (err) => {
    return err.statusCode === 400 && err.message === "cwd_too_long";
  });
});

test("normalizeBool accepts common truthy forms", () => {
  assert.equal(normalizeBool(true), true);
  assert.equal(normalizeBool("true"), true);
  assert.equal(normalizeBool("1"), true);
  assert.equal(normalizeBool(false), false);
  assert.equal(normalizeBool("no"), false);
  assert.equal(normalizeBool(undefined), false);
});

test("rate limits trip after the configured budget", () => {
  resetRateLimitsForTests();
  const secretKey = "rate-test-secret";
  for (let i = 0; i < LIMITS.rateLimitPerSecretPerMinute; i += 1) {
    assert.doesNotThrow(() =>
      enforceRequestRateLimits({secretKey, clientIp: "203.0.113.10"}),
    );
  }
  assert.throws(
    () => enforceRequestRateLimits({secretKey, clientIp: "203.0.113.10"}),
    (err) => err.statusCode === 429,
  );
});

test("new server namespace limit is stricter per IP", () => {
  resetRateLimitsForTests();
  const ip = "198.51.100.20";
  for (let i = 0; i < LIMITS.newServerNamespacesPerIpPerHour; i += 1) {
    assert.doesNotThrow(() => enforceNewServerNamespaceLimit(ip));
  }
  assert.throws(() => enforceNewServerNamespaceLimit(ip), (err) => err.statusCode === 429);
});
