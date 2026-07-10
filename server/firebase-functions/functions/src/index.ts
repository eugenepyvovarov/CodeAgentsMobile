import * as crypto from "crypto";

import * as admin from "firebase-admin";
import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";

import { cleanupStalePushData } from "./cleanup";
import {
  LIMITS,
  normalizeBool,
  normalizeBoundedString,
  normalizeInt,
  statusError,
  validatePushSecret,
} from "./limits";
import { sanitizeNotificationPreview } from "./notificationPreview";
import { enforceNewServerNamespaceLimit, enforceRequestRateLimits } from "./rateLimit";

admin.initializeApp();

type JsonObject = Record<string, unknown>;

type DeviceRegistration = { installationId: string; fcmToken: string };

function sha256Hex(input: string): string {
  return crypto.createHash("sha256").update(input, "utf8").digest("hex");
}

function requirePost(req: any): void {
  if (req.method !== "POST") {
    throw statusError(405, "method_not_allowed");
  }
}

function requireBoundedBody(req: any): void {
  const raw = req.get("content-length");
  if (!raw) {
    return;
  }
  const length = Number.parseInt(String(raw), 10);
  if (Number.isFinite(length) && length > LIMITS.maxBodyBytes) {
    throw statusError(413, "payload_too_large");
  }
}

function requireJson(req: any): JsonObject {
  if (!req.is("application/json")) {
    throw statusError(415, "unsupported_media_type");
  }
  if (!req.body || typeof req.body !== "object") {
    throw statusError(400, "bad_request");
  }
  return req.body as JsonObject;
}

/**
 * Require a high-entropy Bearer secret (CODEAGENTS_PUSH_SECRET).
 * Any non-empty string is no longer accepted.
 */
function requireBearerSecret(req: any): string {
  const authHeader = String(req.get("Authorization") || "").trim();
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    throw statusError(401, "unauthorized");
  }
  const secret = authHeader.slice("bearer ".length).trim();
  validatePushSecret(secret);
  return secret;
}

function clientIp(req: any): string | null {
  const forwarded = String(req.get("x-forwarded-for") || "")
    .split(",")[0]
    ?.trim();
  if (forwarded) {
    return forwarded.slice(0, 64);
  }
  const ip = typeof req.ip === "string" ? req.ip.trim() : "";
  return ip ? ip.slice(0, 64) : null;
}

function respondError(res: any, error: unknown): void {
  const statusCode =
    typeof (error as { statusCode?: unknown })?.statusCode === "number"
      ? (error as { statusCode: number }).statusCode
      : 500;
  const message =
    typeof (error as { message?: unknown })?.message === "string"
      ? (error as { message: string }).message
      : "internal_error";
  // Avoid leaking stack/details for auth and client errors.
  res.status(statusCode).json({ error: message });
}

function beginAuthenticatedRequest(req: any): { secret: string; serverKey: string; ip: string | null } {
  requirePost(req);
  requireBoundedBody(req);
  const secret = requireBearerSecret(req);
  const serverKey = sha256Hex(secret);
  const ip = clientIp(req);
  enforceRequestRateLimits({ secretKey: serverKey, clientIp: ip });
  return { secret, serverKey, ip };
}

function chunkArray<T>(items: T[], chunkSize: number): T[][] {
  if (chunkSize <= 0) {
    return [items];
  }
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += chunkSize) {
    chunks.push(items.slice(i, i + chunkSize));
  }
  return chunks;
}

function isInvalidTokenError(error: any): boolean {
  const code = String(error?.code || "");
  return (
    code === "messaging/registration-token-not-registered" ||
    code === "messaging/invalid-registration-token"
  );
}

export const registerSubscription = onRequest(
  { region: "us-central1", invoker: "public", maxInstances: 40 },
  async (req, res) => {
    try {
      const { serverKey, ip } = beginAuthenticatedRequest(req);
      const body = requireJson(req);

      const cwd = normalizeBoundedString(body["cwd"], LIMITS.maxCwdLength, "cwd");
      const installationId = normalizeBoundedString(
        body["installation_id"],
        LIMITS.maxInstallationIdLength,
        "installation_id"
      );
      const fcmToken = normalizeBoundedString(
        body["fcm_token"],
        LIMITS.maxFcmTokenLength,
        "fcm_token"
      );
      const agentDisplayName = normalizeBoundedString(
        body["agent_display_name"],
        LIMITS.maxAgentDisplayNameLength,
        "agent_display_name"
      );
      const platform =
        normalizeBoundedString(body["platform"], LIMITS.maxPlatformLength, "platform") ?? "ios";

      if (!cwd || !installationId || !fcmToken) {
        res.status(400).json({ error: "bad_request" });
        return;
      }

      const agentKey = sha256Hex(cwd);
      const firestore = getFirestore();
      const now = admin.firestore.FieldValue.serverTimestamp();

      const serverRef = firestore.collection("servers").doc(serverKey);
      const agentRef = serverRef.collection("agents").doc(agentKey);
      const deviceRef = agentRef.collection("devices").doc(installationId);

      const serverSnap = await serverRef.get();
      if (!serverSnap.exists) {
        enforceNewServerNamespaceLimit(ip);
      }

      await serverRef.set(
        {
          createdAt: serverSnap.exists ? serverSnap.data()?.createdAt ?? now : now,
          lastSeenAt: now,
        },
        { merge: true }
      );

      await agentRef.set(
        {
          cwd,
          agentDisplayName: agentDisplayName ?? admin.firestore.FieldValue.delete(),
          updatedAt: now,
        },
        { merge: true }
      );

      await deviceRef.set(
        {
          fcmToken,
          platform,
          updatedAt: now,
        },
        { merge: true }
      );

      res.status(200).json({ ok: true, server_key: serverKey, agent_key: agentKey });
    } catch (error) {
      logger.error("registerSubscription failed", error);
      respondError(res, error);
    }
  }
);

/**
 * Remove a device registration (and optionally only for one agent cwd).
 * Called by the app when a project/server is deleted or push is torn down.
 */
export const unregisterSubscription = onRequest(
  { region: "us-central1", invoker: "public", maxInstances: 20 },
  async (req, res) => {
    try {
      const { serverKey } = beginAuthenticatedRequest(req);
      const body = requireJson(req);

      const installationId = normalizeBoundedString(
        body["installation_id"],
        LIMITS.maxInstallationIdLength,
        "installation_id"
      );
      const cwd = normalizeBoundedString(body["cwd"], LIMITS.maxCwdLength, "cwd");

      if (!installationId) {
        res.status(400).json({ error: "bad_request" });
        return;
      }

      const firestore = getFirestore();
      const serverRef = firestore.collection("servers").doc(serverKey);
      let deleted = 0;

      if (cwd) {
        const agentKey = sha256Hex(cwd);
        const deviceRef = serverRef.collection("agents").doc(agentKey).collection("devices").doc(installationId);
        const snap = await deviceRef.get();
        if (snap.exists) {
          await deviceRef.delete();
          deleted = 1;
        }
      } else {
        const agentsSnap = await serverRef.collection("agents").limit(500).get();
        const batch = firestore.batch();
        for (const agentDoc of agentsSnap.docs) {
          const deviceRef = agentDoc.ref.collection("devices").doc(installationId);
          batch.delete(deviceRef);
          deleted += 1;
        }
        if (deleted > 0) {
          await batch.commit();
        }
      }

      res.status(200).json({ ok: true, deleted });
    } catch (error) {
      logger.error("unregisterSubscription failed", error);
      respondError(res, error);
    }
  }
);

export const triggerReplyFinished = onRequest(
  { region: "us-central1", invoker: "public", maxInstances: 40 },
  async (req, res) => {
    try {
      const { serverKey } = beginAuthenticatedRequest(req);
      const body = requireJson(req);

      const cwd = normalizeBoundedString(body["cwd"], LIMITS.maxCwdLength, "cwd");
      const conversationId = normalizeBoundedString(
        body["conversation_id"],
        LIMITS.maxConversationIdLength,
        "conversation_id"
      );
      const includePreview = normalizeBool(body["include_preview"]);
      // Default-safe lock-screen body: only surface message_preview when explicitly opted in.
      const messagePreview = includePreview
        ? sanitizeNotificationPreview(body["message_preview"], 240)
        : null;
      const renderableAssistantCount = normalizeInt(body["renderable_assistant_count"]);

      if (!cwd) {
        res.status(400).json({ error: "bad_request" });
        return;
      }

      const agentKey = sha256Hex(cwd);
      const firestore = getFirestore();
      const serverRef = firestore.collection("servers").doc(serverKey);
      const agentRef = serverRef.collection("agents").doc(agentKey);

      // Do not create server/agent namespaces from trigger alone (abuse surface).
      const serverSnap = await serverRef.get();
      if (!serverSnap.exists) {
        res.status(200).json({ ok: true, attempted: 0, sent: 0, reason: "unknown_server" });
        return;
      }

      const devicesSnap = await agentRef.collection("devices").get();
      const devices: DeviceRegistration[] = [];
      for (const doc of devicesSnap.docs) {
        const data = doc.data();
        const token = typeof data.fcmToken === "string" ? data.fcmToken.trim() : "";
        if (!token || token.length > LIMITS.maxFcmTokenLength) {
          continue;
        }
        devices.push({ installationId: doc.id, fcmToken: token });
      }

      const agentSnap = await agentRef.get();
      const agentDisplayName =
        agentSnap.exists && typeof agentSnap.data()?.agentDisplayName === "string"
          ? String(agentSnap.data()?.agentDisplayName).slice(0, LIMITS.maxAgentDisplayNameLength)
          : null;

      const now = admin.firestore.FieldValue.serverTimestamp();
      await serverRef.set({ lastSeenAt: now }, { merge: true });
      if (agentSnap.exists) {
        await agentRef.set({ updatedAt: now }, { merge: true });
      }

      if (!devices.length) {
        res.status(200).json({ ok: true, attempted: 0, sent: 0 });
        return;
      }

      // Never put cwd path fragments on the lock screen.
      const titleText = agentDisplayName || "CodeAgents";
      const bodyText = messagePreview ?? "Reply ready";
      const dataPayload: Record<string, string> = {
        type: "reply_finished",
        server_key: serverKey,
        cwd,
      };
      if (conversationId) {
        dataPayload["conversation_id"] = conversationId;
      }
      if (renderableAssistantCount !== null) {
        dataPayload["renderable_assistant_count"] = String(renderableAssistantCount);
      }

      const messaging = getMessaging();

      let attempted = 0;
      let sent = 0;
      const errorCodes: Record<string, number> = {};
      const invalidInstallationIds: string[] = [];

      for (const batch of chunkArray(devices, LIMITS.fcmMulticastBatchSize)) {
        attempted += batch.length;
        const tokens = batch.map((device) => device.fcmToken);
        const response = await messaging.sendEachForMulticast({
          tokens,
          notification: {
            title: titleText,
            body: bodyText,
          },
          data: dataPayload,
          apns: {
            headers: {
              "apns-push-type": "alert",
              "apns-priority": "10",
              // APNs spec: apns-collapse-id must be <= 64 bytes. agentKey is a 64-char hex string.
              "apns-collapse-id": agentKey,
            },
            payload: {
              aps: {
                alert: {
                  title: titleText,
                  body: bodyText,
                },
                sound: "default",
                threadId: agentKey,
                contentAvailable: true,
              },
            },
          },
        });

        sent += response.successCount;

        response.responses.forEach((r, index) => {
          if (r.success) {
            return;
          }
          const code = typeof r.error?.code === "string" ? r.error.code : "unknown_error";
          errorCodes[code] = (errorCodes[code] ?? 0) + 1;
          if (isInvalidTokenError(r.error)) {
            invalidInstallationIds.push(batch[index].installationId);
          }
        });
      }

      if (invalidInstallationIds.length) {
        const batch = firestore.batch();
        for (const installationId of invalidInstallationIds) {
          batch.delete(agentRef.collection("devices").doc(installationId));
        }
        await batch.commit();
      }

      const responseBody: Record<string, unknown> = {
        ok: true,
        attempted,
        sent,
        pruned: invalidInstallationIds.length,
        preview_included: includePreview && Boolean(messagePreview),
      };
      if (Object.keys(errorCodes).length) {
        responseBody.errors = errorCodes;
      }
      res.status(200).json(responseBody);
    } catch (error) {
      logger.error("triggerReplyFinished failed", error);
      respondError(res, error);
    }
  }
);

/** Daily TTL sweep for stale push registrations (90 days). */
export const cleanupStalePushRegistrations = onSchedule(
  {
    schedule: "every 24 hours",
    region: "us-central1",
    timeoutSeconds: 540,
    memory: "512MiB",
  },
  async () => {
    const firestore = getFirestore();
    const stats = await cleanupStalePushData(firestore);
    logger.info("cleanupStalePushRegistrations complete", stats);
  }
);
