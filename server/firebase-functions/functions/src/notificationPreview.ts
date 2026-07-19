function normalizeString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length ? trimmed : null;
}

function removeCodeAgentsUIBlocks(input: string): string {
  // Match the marker rather than a complete line. Current clients preserve
  // newlines, but older clients flattened the whole reply before sending it,
  // producing inline fences such as "summary ```codeagents-ui {...} ```".
  const openingFencePattern = /```[ \t]*(?:codeagents-ui|codeagents_ui)\b/gim;
  const closingFencePattern = /```/gm;

  let result = "";
  let cursor = 0;

  while (cursor < input.length) {
    openingFencePattern.lastIndex = cursor;
    const openingMatch = openingFencePattern.exec(input);

    if (!openingMatch) {
      result += input.slice(cursor);
      break;
    }

    result += input.slice(cursor, openingMatch.index);

    closingFencePattern.lastIndex = openingFencePattern.lastIndex;
    const closingMatch = closingFencePattern.exec(input);
    if (!closingMatch) {
      break;
    }

    cursor = closingFencePattern.lastIndex;
  }

  return result;
}

export function sanitizeNotificationPreview(value: unknown, maxLength = 240): string | null {
  const raw = normalizeString(value);
  if (!raw) {
    return null;
  }

  const withoutUIBlocks = removeCodeAgentsUIBlocks(raw);
  const condensed = withoutUIBlocks.replace(/\s+/g, " ").trim();
  if (!condensed) {
    return null;
  }

  if (condensed.length <= maxLength) {
    return condensed;
  }

  const sliceLength = Math.max(0, maxLength - 1);
  return condensed.slice(0, sliceLength).trimEnd() + "…";
}
