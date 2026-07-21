export type InstallationIdentified = {
  installationId: string;
  fcmToken: unknown;
};

export type InstallationExclusionResult<T> = {
  included: T[];
  excluded: number;
};

export type ReplyFinishedDataPayloadInput = {
  serverKey: string;
  cwd: string;
  conversationId: string | null;
  renderableAssistantCount: number | null;
  assistantMessageCursor: number | null;
  cursorVersion: number | null;
  completionId: string | null;
};

/**
 * Exclude the source installation and every stale registration carrying its token,
 * then deduplicate the remaining tokens so one phone cannot receive two banners.
 */
export function excludeInstallation<T extends InstallationIdentified>(
  devices: T[],
  excludedInstallationId: string | null,
  excludedFCMToken: string | null = null
): InstallationExclusionResult<T> {
  const normalizedExcludedFCMToken = excludedFCMToken?.trim() ?? "";
  if (!excludedInstallationId && !normalizedExcludedFCMToken) {
    const seenTokens = new Set<string>();
    const included = devices.filter((device) => {
      const token = typeof device.fcmToken === "string" ? device.fcmToken.trim() : "";
      if (!token || seenTokens.has(token)) {
        return false;
      }
      seenTokens.add(token);
      return true;
    });
    return {included, excluded: devices.length - included.length};
  }

  const excludedTokens = new Set<string>();
  if (normalizedExcludedFCMToken) {
    excludedTokens.add(normalizedExcludedFCMToken);
  }
  if (excludedInstallationId) {
    const storedToken = devices
      .find((device) => device.installationId === excludedInstallationId)
      ?.fcmToken;
    const normalizedStoredToken = typeof storedToken === "string" ? storedToken.trim() : "";
    if (normalizedStoredToken) {
      excludedTokens.add(normalizedStoredToken);
    }
  }

  const included: T[] = [];
  const seenTokens = new Set<string>();
  let excluded = 0;
  for (const device of devices) {
    const token = typeof device.fcmToken === "string" ? device.fcmToken.trim() : "";
    if (
      device.installationId === excludedInstallationId ||
      (token && excludedTokens.has(token)) ||
      (token && seenTokens.has(token))
    ) {
      excluded += 1;
    } else {
      included.push(device);
      if (token) {
        seenTokens.add(token);
      }
    }
  }

  return {included, excluded};
}

/** Build the notification data without persisting or logging completion identity. */
export function buildReplyFinishedDataPayload(
  input: ReplyFinishedDataPayloadInput
): Record<string, string> {
  const payload: Record<string, string> = {
    type: "reply_finished",
    server_key: input.serverKey,
    cwd: input.cwd,
  };
  if (input.conversationId) {
    payload["conversation_id"] = input.conversationId;
  }
  if (input.renderableAssistantCount !== null) {
    payload["renderable_assistant_count"] = String(input.renderableAssistantCount);
  }
  if (input.assistantMessageCursor !== null) {
    payload["assistant_message_cursor"] = String(input.assistantMessageCursor);
    if (input.cursorVersion !== null) {
      payload["cursor_version"] = String(input.cursorVersion);
    }
  }
  if (input.completionId) {
    payload["completion_id"] = input.completionId;
  }
  return payload;
}
