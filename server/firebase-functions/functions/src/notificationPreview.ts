function normalizeString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const trimmed = value.trim();
  return trimmed.length ? trimmed : null;
}

function removeCodeAgentsUIBlocks(input: string): string {
  const openingFencePattern = /^[ \t]*```[ \t]*(?:codeagents-ui|codeagents_ui)\b[^\r\n]*(?:\r?\n|$)/gim;
  const closingFencePattern = /^[ \t]*```[^\r\n]*(?:\r?\n|$)/gm;

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
