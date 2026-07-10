import type {Firestore } from "firebase-admin/firestore";

import { LIMITS } from "./limits";

export type CleanupStats = {
  devicesDeleted: number;
  agentsDeleted: number;
  serversDeleted: number;
};

function isTimestampOlderThan(value: unknown, cutoffMs: number): boolean {
  if (!value || typeof value !== "object") {
    return true; // missing timestamp → treat as stale
  }
  const maybe = value as { toMillis?: () => number; seconds?: number };
  let ms: number | null = null;
  if (typeof maybe.toMillis === "function") {
    ms = maybe.toMillis();
  } else if (typeof maybe.seconds === "number") {
    ms = maybe.seconds * 1000;
  }
  if (ms === null || !Number.isFinite(ms)) {
    return true;
  }
  return ms < cutoffMs;
}

/**
 * Delete stale push registrations (devices → empty agents → empty servers).
 * Safe to call from a scheduled function.
 */
export async function cleanupStalePushData(
  firestore: Firestore,
  options?: { nowMs?: number; ttlMs?: number; maxDocs?: number }
): Promise<CleanupStats> {
  const nowMs = options?.nowMs ?? Date.now();
  const ttlMs = options?.ttlMs ?? LIMITS.staleDataTtlMs;
  const maxDocs = options?.maxDocs ?? 500;
  const cutoffMs = nowMs - ttlMs;

  const stats: CleanupStats = {
    devicesDeleted: 0,
    agentsDeleted: 0,
    serversDeleted: 0,
  };

  const serversSnap = await firestore.collection("servers").limit(maxDocs).get();

  for (const serverDoc of serversSnap.docs) {
    const agentsSnap = await serverDoc.ref.collection("agents").limit(maxDocs).get();
    let agentsRemaining = agentsSnap.size;

    for (const agentDoc of agentsSnap.docs) {
      const devicesSnap = await agentDoc.ref.collection("devices").limit(maxDocs).get();
      let devicesRemaining = devicesSnap.size;

      const staleDeviceRefs = devicesSnap.docs
        .filter((doc) => isTimestampOlderThan(doc.data().updatedAt, cutoffMs))
        .map((doc) => doc.ref);

      if (staleDeviceRefs.length) {
        // Firestore batch limit 500
        for (let i = 0; i < staleDeviceRefs.length; i += 400) {
          const batch = firestore.batch();
          for (const ref of staleDeviceRefs.slice(i, i + 400)) {
            batch.delete(ref);
          }
          await batch.commit();
        }
        stats.devicesDeleted += staleDeviceRefs.length;
        devicesRemaining -= staleDeviceRefs.length;
      }

      const agentUpdatedAt = agentDoc.data().updatedAt;
      if (devicesRemaining <= 0 && isTimestampOlderThan(agentUpdatedAt, cutoffMs)) {
        await agentDoc.ref.delete();
        stats.agentsDeleted += 1;
        agentsRemaining -= 1;
      }
    }

    const serverData = serverDoc.data();
    const lastSeen = serverData.lastSeenAt ?? serverData.createdAt;
    if (agentsRemaining <= 0 && isTimestampOlderThan(lastSeen, cutoffMs)) {
      await serverDoc.ref.delete();
      stats.serversDeleted += 1;
    }
  }

  return stats;
}
