// The brain's canonical JSON: object keys sorted recursively, no whitespace.
// Hashes on chain commit to this exact text, so it must not drift.
function serialize(value: unknown, seen: Set<object>): string {
  if (value === null || typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("Canonical JSON does not support non-finite numbers");
    return JSON.stringify(value);
  }
  if (typeof value !== "object") throw new TypeError(`Canonical JSON does not support ${typeof value}`);
  if (seen.has(value)) throw new TypeError("Canonical JSON does not support cyclic values");

  seen.add(value);
  try {
    if (Array.isArray(value)) {
      for (let i = 0; i < value.length; i++) {
        if (!Object.hasOwn(value, i)) throw new TypeError("Canonical JSON does not support sparse arrays");
      }
      return `[${value.map((item) => serialize(item, seen)).join(",")}]`;
    }
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) throw new TypeError("Canonical JSON only supports plain objects");
    const source = value as Record<string, unknown>;
    const entries = Object.keys(source)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${serialize(source[key], seen)}`);
    return `{${entries.join(",")}}`;
  } finally {
    seen.delete(value);
  }
}

export function canonicalStringify(value: unknown): string {
  return serialize(value, new Set());
}
