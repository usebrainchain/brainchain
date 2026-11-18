// The brain's schema check (schema-check.ts), so a result is checked here exactly as BrainChain checked it before
// any grader was asked. A brief carries the schema in a fenced block whose info string is "json schema".

export type Schema = Record<string, unknown>;

export interface Shape {
  outcome: "passed" | "failed";
  /** What does not match, each line naming the path. */
  problems?: string[];
}

const MAX_SCHEMA = 8_000;
const MAX_PROBLEMS = 20;
const MAX_DEPTH = 8;
const TYPES = new Set(["object", "array", "string", "integer", "number", "boolean", "null"]);
const KEYWORDS = new Set(["type", "properties", "required", "additionalProperties", "items", "enum", "minimum", "maximum", "minLength", "maxLength", "description", "title"]);
const FENCE = /```json[^\S\n]+schema[^\S\n]*\n([\s\S]*?)```/i;
const RESULT_FENCE = /^```(?:json)?[^\S\n]*\n([\s\S]*?)\n?```$/i;

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

function unsupported(schema: unknown, path = "schema", depth = 0): string | undefined {
  if (!isRecord(schema)) return `${path} must be an object`;
  if (depth > MAX_DEPTH) return `${path} nests deeper than ${MAX_DEPTH} levels`;
  for (const key of Object.keys(schema)) if (!KEYWORDS.has(key)) return `${path} uses "${key}"`;
  const { type, properties, required, additionalProperties, items, enum: allowed } = schema;
  const types = Array.isArray(type) ? type : type === undefined ? [] : [type];
  if (!types.every((t) => typeof t === "string" && TYPES.has(t))) return `${path}.type names a type outside ${[...TYPES].join(", ")}`;
  if (properties !== undefined) {
    if (!isRecord(properties)) return `${path}.properties must be an object`;
    for (const [name, sub] of Object.entries(properties)) {
      const problem = unsupported(sub, `${path}.properties.${name}`, depth + 1);
      if (problem) return problem;
    }
  }
  if (required !== undefined && !(Array.isArray(required) && required.every((r) => typeof r === "string"))) return `${path}.required must list property names`;
  if (additionalProperties !== undefined && typeof additionalProperties !== "boolean") return `${path}.additionalProperties must be true or false`;
  if (items !== undefined) return unsupported(items, `${path}.items`, depth + 1);
  if (allowed !== undefined && !(Array.isArray(allowed) && allowed.length > 0)) return `${path}.enum must list at least one value`;
  for (const bound of ["minimum", "maximum", "minLength", "maxLength"] as const) {
    if (schema[bound] !== undefined && typeof schema[bound] !== "number") return `${path}.${bound} must be a number`;
  }
  return undefined;
}

/** The schema fenced in a brief; a string says why the fence holds none BrainChain checks, and BrainChain then checks nothing. */
export function schemaIn(brief: string): Schema | string | undefined {
  const fenced = FENCE.exec(brief)?.[1];
  if (fenced === undefined) return undefined;
  if (fenced.length > MAX_SCHEMA) return `the json schema is over ${MAX_SCHEMA.toLocaleString("en-US")} characters`;
  let schema: unknown;
  try {
    schema = JSON.parse(fenced);
  } catch {
    return "the json schema is not valid JSON";
  }
  return unsupported(schema) ?? (schema as Schema);
}

const typeOf = (value: unknown): string =>
  value === null ? "null" : Array.isArray(value) ? "array" : typeof value === "number" && Number.isInteger(value) ? "integer" : typeof value;

function matches(value: unknown, schema: Schema, path: string, problems: string[]): void {
  if (problems.length >= MAX_PROBLEMS) return;
  const types = Array.isArray(schema.type) ? (schema.type as string[]) : schema.type === undefined ? [] : [schema.type as string];
  const actual = typeOf(value);
  if (types.length > 0 && !types.includes(actual) && !(actual === "integer" && types.includes("number"))) {
    problems.push(`${path} is ${actual}, the schema asks for ${types.join(" or ")}`);
    return;
  }
  if (Array.isArray(schema.enum) && !schema.enum.some((option) => JSON.stringify(option) === JSON.stringify(value))) problems.push(`${path} is not one of the allowed values`);
  if (typeof value === "string") {
    if (typeof schema.minLength === "number" && value.length < schema.minLength) problems.push(`${path} is shorter than ${schema.minLength} characters`);
    if (typeof schema.maxLength === "number" && value.length > schema.maxLength) problems.push(`${path} is longer than ${schema.maxLength} characters`);
  }
  if (typeof value === "number") {
    if (typeof schema.minimum === "number" && value < schema.minimum) problems.push(`${path} is below ${schema.minimum}`);
    if (typeof schema.maximum === "number" && value > schema.maximum) problems.push(`${path} is above ${schema.maximum}`);
  }
  if (actual === "object") {
    const object = value as Record<string, unknown>;
    const properties = (schema.properties ?? {}) as Record<string, Schema>;
    for (const name of (schema.required ?? []) as string[]) if (!Object.hasOwn(object, name)) problems.push(`${path}.${name} is missing`);
    for (const [name, field] of Object.entries(object)) {
      if (Object.hasOwn(properties, name)) matches(field, properties[name]!, `${path}.${name}`, problems);
      else if (schema.additionalProperties === false) problems.push(`${path}.${name} is not in the schema`);
    }
  }
  if (actual === "array" && isRecord(schema.items)) (value as unknown[]).forEach((item, i) => matches(item, schema.items as Schema, `${path}[${i}]`, problems));
}

/** The result checked against the schema: the result must be one JSON value, bare or in a single fenced block. */
export function checkShape(result: string, schema: Schema): Shape {
  const text = result.trim();
  const body = RESULT_FENCE.exec(text)?.[1] ?? text;
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    return { outcome: "failed", problems: ["the result is not one JSON value"] };
  }
  const problems: string[] = [];
  matches(value, schema, "result", problems);
  return problems.length === 0 ? { outcome: "passed" } : { outcome: "failed", problems: problems.slice(0, MAX_PROBLEMS) };
}
