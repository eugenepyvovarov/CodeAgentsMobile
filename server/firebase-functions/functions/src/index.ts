import * as crypto from "crypto";

import * as admin from "firebase-admin";
import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onRequest } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";

admin.initializeApp();

type JsonObject = Record<string, unknown>;

function sha256Hex(input: string): string {
  return crypto.createHash("sha256").update(input, "utf8").digest("hex");
}

function requirePost(req: any): void {
  if (req.method !== "POST") {
    const error = new Error("method_not_allowed");
    (error as any).statusCode = 405;
    throw error;
  }
}

function requireJson(req: any): JsonObject {
  if (!req.is("application/json")) {
    const error = new Error("unsupported_media_type");
    (error as any).statusCode = 415;
    throw error;
  }
  if (!req.body || typeof req.body !== "object") {
    const error = new Error("bad_request");
    (error as any).statusCode = 400;
    throw error;
  }
  return req.body as JsonObject;
}

function requireBearerSecret(req: any): string {
  const authHeader = String(req.get("Authorization") || "").trim();
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    const error = new Error("unauthorized");
    (error as any).statusCode = 401;
    throw error;
  }
  const secret = authHeader.slice("bearer ".length).trim();
  if (!secret) {
    const error = new Error("unauthorized");
    (error as any).statusCode = 401;
    throw error;
  }
  return secret;
}

function normalizeString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length ? trimmed : null;
}

function normalizePreview(value: unknown, maxLength = 240): string | null {
  const raw = normalizeString(value);
  if (!raw) {
    return null;
  }

  const condensed = raw.replace(/\s+/g, " ").trim();
  if (!condensed) {
    return null;
  }

  if (condensed.length <= maxLength) {
    return condensed;
  }

  const sliceLength = Math.max(0, maxLength - 1);
  return condensed.slice(0, sliceLength).trimEnd() + "…";
}

function normalizeInt(value: unknown): number | null {
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

function respondError(res: any, error: unknown): void {
  const statusCode = typeof (error as any)?.statusCode === "number" ? (error as any).statusCode : 500;
  const message = typeof (error as any)?.message === "string" ? (error as any).message : "internal_error";
  res.status(statusCode).json({ error: message });
}

export const registerSubscription = onRequest({ region: "us-central1", invoker: "public" }, async (req, res) => {
  try {
    requirePost(req);
    const secret = requireBearerSecret(req);
    const body = requireJson(req);

    const cwd = normalizeString(body["cwd"]);
    const installationId = normalizeString(body["installation_id"]);
    const fcmToken = normalizeString(body["fcm_token"]);
    const agentDisplayName = normalizeString(body["agent_display_name"]);
    const platform = normalizeString(body["platform"]) ?? "ios";

    if (!cwd || !installationId || !fcmToken) {
      res.status(400).json({ error: "bad_request" });
      return;
    }

    const serverKey = sha256Hex(secret);
    const agentKey = sha256Hex(cwd);

    const firestore = getFirestore();
    const now = admin.firestore.FieldValue.serverTimestamp();

    const serverRef = firestore.collection("servers").doc(serverKey);
    const agentRef = serverRef.collection("agents").doc(agentKey);
    const deviceRef = agentRef.collection("devices").doc(installationId);

    await serverRef.set(
      {
        createdAt: now,
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
});

type DeviceRegistration = { installationId: string; fcmToken: string };

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

export const triggerReplyFinished = onRequest({ region: "us-central1", invoker: "public" }, async (req, res) => {
  try {
    requirePost(req);
    const secret = requireBearerSecret(req);
    const body = requireJson(req);

    const cwd = normalizeString(body["cwd"]);
    const conversationId = normalizeString(body["conversation_id"]);
    const messagePreview = normalizePreview(body["message_preview"]);
    const renderableAssistantCount = normalizeInt(body["renderable_assistant_count"]);

    if (!cwd) {
      res.status(400).json({ error: "bad_request" });
      return;
    }

    const serverKey = sha256Hex(secret);
    const agentKey = sha256Hex(cwd);

    const firestore = getFirestore();
    const serverRef = firestore.collection("servers").doc(serverKey);
    const agentRef = serverRef.collection("agents").doc(agentKey);
    const devicesSnap = await agentRef.collection("devices").get();

    const devices: DeviceRegistration[] = [];
    for (const doc of devicesSnap.docs) {
      const data = doc.data();
      const token = typeof data.fcmToken === "string" ? data.fcmToken.trim() : "";
      if (!token) {
        continue;
      }
      devices.push({ installationId: doc.id, fcmToken: token });
    }

    const agentSnap = await agentRef.get();
    const agentDisplayName =
      agentSnap.exists && typeof agentSnap.data()?.agentDisplayName === "string"
        ? String(agentSnap.data()?.agentDisplayName)
        : null;

    const now = admin.firestore.FieldValue.serverTimestamp();
    await serverRef.set({ lastSeenAt: now }, { merge: true });
    await agentRef.set({ updatedAt: now }, { merge: true });

    if (!devices.length) {
      res.status(200).json({ ok: true, attempted: 0, sent: 0 });
      return;
    }

    const titleText = agentDisplayName ?? cwd.split("/").filter(Boolean).slice(-1)[0] ?? "Reply ready";
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

    for (const batch of chunkArray(devices, 500)) {
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
            // APNs spec: apns-collapse-id must be <= 64 bytes. agentKey is a 64-char hex string.
            "apns-collapse-id": agentKey,
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

    const responseBody: Record<string, unknown> = { ok: true, attempted, sent, pruned: invalidInstallationIds.length };
    if (Object.keys(errorCodes).length) {
      responseBody.errors = errorCodes;
    }
    res.status(200).json(responseBody);
  } catch (error) {
    logger.error("triggerReplyFinished failed", error);
    respondError(res, error);
  }
});
