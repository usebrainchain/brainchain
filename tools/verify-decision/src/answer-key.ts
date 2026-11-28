// The brain's reading of a sealed answer key (sealedKeyIn in answer-key.ts), so a brief reads the same here as there.
// A brief seals a key with a fenced block whose info string is "answer key", holding the SHA-256 of the key's text,
// how the result must match it and, for a fields match, the tolerance. The key itself never reaches the record.

export interface SealedKey {
  /** Lowercase hex SHA-256 of the key's UTF-8 bytes. */
  sha256: string;
  match: "exact" | "fields";
  tolerance?: number | Record<string, number>;
}

const FENCE = /```answer[^\S\n]+key[^\S\n]*\n([\s\S]*?)```/i;
const HEX = /^[0-9a-f]{64}$/i;

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const tolerable = (value: unknown): boolean => typeof value === "number" && Number.isFinite(value) && value >= 0;

/** The key a brief seals; a string says why its block holds no key BrainChain can check. Undefined when it seals none. */
export function sealedKeyIn(brief: string): SealedKey | string | undefined {
  const fenced = FENCE.exec(brief)?.[1];
  if (fenced === undefined) return undefined;
  let spec: unknown;
  try {
    spec = JSON.parse(fenced);
  } catch {
    return "the answer key block is not valid JSON";
  }
  if (!isRecord(spec)) return "the answer key block must be a JSON object";
  const { sha256, match, tolerance } = spec;
  if (typeof sha256 !== "string" || !HEX.test(sha256)) return "the answer key block's sha256 must be 64 hex characters";
  if (match !== "exact" && match !== "fields") return 'the answer key block\'s match must be "exact" or "fields"';
  if (tolerance !== undefined) {
    if (match === "exact") return "an exact match takes no tolerance";
    if (!tolerable(tolerance) && !(isRecord(tolerance) && Object.values(tolerance).every(tolerable))) return "tolerance must be a number of at least 0, or field names mapped to one";
  }
  const extra = Object.keys(spec).find((key) => !["sha256", "match", "tolerance"].includes(key));
  if (extra) return `the answer key block has "${extra}"; it takes sha256, match and tolerance`;
  return { sha256: sha256.toLowerCase(), match, ...(tolerance !== undefined ? { tolerance: tolerance as SealedKey["tolerance"] } : {}) };
}
