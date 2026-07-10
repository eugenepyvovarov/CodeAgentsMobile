/**
 * Request/field limits for the push gateway.
 * Keeps public HTTPS functions from accepting unbounded payloads or tiny secrets.
 */

export const LIMITS = {
  /** Max raw JSON body (bytes). */
  maxBodyBytes: 16 * 1024,
  /** CODEAGENTS_PUSH_SECRET min length (app generates 32-byte base64 ≈ 44 chars). */
  minSecretLength: 32,
  maxSecretLength: 256,
  maxCwdLength: 2048,
  maxInstallationIdLength: 128,
  maxFcmTokenLength: 4096,
  maxAgentDisplayNameLength: 120,
  maxPlatformLength: 32,
  maxConversationIdLength: 256,
  maxMessagePreviewLength: 600,
  /** Devices sent per FCM multicast batch (FCM hard limit 500). */
  fcmMulticastBatchSize: 500,
  /** In-process rate limits (best-effort across instances). */
  rateLimitPerSecretPerMinute: 60,
  rateLimitPerIpPerMinute: 120,
  /** New Firestore server namespaces per client IP per hour. */
  newServerNamespacesPerIpPerHour: 10,
  /** Stale device/agent/server TTL for scheduled cleanup. */
  staleDataTtlMs: 90 * 24 * 60 * 60 * 1000,
} as const;

export function statusError(statusCode: number, message: string): Error {
  const error = new Error(message);
  (error as Error & { statusCode: number }).statusCode = statusCode;
  return error;
}

export function normalizeString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length ? trimmed : null;
}

export function normalizeBoundedString(
  value: unknown,
  maxLength: number,
  fieldName: string
): string | null {
  const normalized = normalizeString(value);
  if (!normalized) {
    return null;
  }
  if (normalized.length > maxLength) {
    throw statusError(400, `${fieldName}_too_long`);
  }
  return normalized;
}

export function normalizeInt(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }
  const parsed = Number.parseInt(trimmed, 10);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return parsed;
}

export function normalizeBool(value: unknown): boolean {
  if (value === true || value === 1) {
    return true;
  }
  if (typeof value === "string") {
    const lower = value.trim().toLowerCase();
    return lower === "true" || lower === "1" || lower === "yes";
  }
  return false;
}

/** Accept high-entropy secrets the app ships (base64 / base64url). */
export function validatePushSecret(secret: string): void {
  if (secret.length < LIMITS.minSecretLength || secret.length > LIMITS.maxSecretLength) {
    throw statusError(401, "unauthorized");
  }
  // Reject obviously low-entropy or injection-prone values without leaking details.
  if (!/^[A-Za-z0-9+/=_-]+$/.test(secret)) {
    throw statusError(401, "unauthorized");
  }
}
