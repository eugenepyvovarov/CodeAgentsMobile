import { LIMITS, statusError } from "./limits";

type Bucket = {
  count: number;
  resetAt: number;
};

/** Process-local sliding windows. Best-effort under multi-instance scale-out. */
const buckets = new Map<string, Bucket>();

const MAX_BUCKETS = 20_000;

function take(key: string, limit: number, windowMs: number): void {
  const now = Date.now();
  let bucket = buckets.get(key);
  if (!bucket || now >= bucket.resetAt) {
    bucket = { count: 0, resetAt: now + windowMs };
    buckets.set(key, bucket);
  }
  bucket.count += 1;
  if (buckets.size > MAX_BUCKETS) {
    pruneExpired(now);
  }
  if (bucket.count > limit) {
    throw statusError(429, "rate_limited");
  }
}

function pruneExpired(now: number): void {
  for (const [key, bucket] of buckets) {
    if (now >= bucket.resetAt) {
      buckets.delete(key);
    }
  }
  // Hard cap: drop arbitrary oldest-ish entries if still oversized.
  if (buckets.size > MAX_BUCKETS) {
    const excess = buckets.size - Math.floor(MAX_BUCKETS / 2);
    let removed = 0;
    for (const key of buckets.keys()) {
      buckets.delete(key);
      removed += 1;
      if (removed >= excess) {
        break;
      }
    }
  }
}

export function enforceRequestRateLimits(opts: {
  secretKey: string;
  clientIp: string | null;
}): void {
  take(
    `secret:${opts.secretKey}`,
    LIMITS.rateLimitPerSecretPerMinute,
    60_000
  );
  if (opts.clientIp) {
    take(`ip:${opts.clientIp}`, LIMITS.rateLimitPerIpPerMinute, 60_000);
  }
}

/** Call only when creating a brand-new servers/{serverKey} document. */
export function enforceNewServerNamespaceLimit(clientIp: string | null): void {
  const ip = clientIp || "unknown";
  take(`new-server:${ip}`, LIMITS.newServerNamespacesPerIpPerHour, 60 * 60 * 1000);
}

/** Test seam. */
export function resetRateLimitsForTests(): void {
  buckets.clear();
}
