import { lookup as dnsLookup, promises as dns, type LookupAddress } from "node:dns";
import { Agent as HttpAgent, request as httpRequest } from "node:http";
import { Agent as HttpsAgent, request as httpsRequest } from "node:https";
import { BlockList, isIP } from "node:net";
import { setTimeout as sleep } from "node:timers/promises";

import {
  BaseError,
  decodeFunctionData,
  encodeAbiParameters,
  keccak256,
  pad,
  toBytes,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
  toHex,
} from "viem";

import { decisionExecutorAbi, decisionLogAbi, modelRegistryAbi, taskBoardAbi } from "./abi.js";
import { canonicalStringify } from "./canonical.js";
import type { ContractSet, Network } from "./deployments.js";

/** `error` is a check that could not complete, such as a record host that did not answer. */
export type Status = "ok" | "fail" | "skip" | "error";

export interface Check {
  /** Stable across releases, so a script can pick out one check. */
  name: string;
  status: Status;
  message: string;
}

export interface DecisionReport {
  id: number;
  kind?: string;
  task?: number;
  /** A grade of work delivered outside BrainChain, so no task here. */
  outside?: boolean;
  /** Served without the work, as the chain shows it may be, so its hashes could not be checked. */
  withheld?: boolean;
  block?: number;
  recordedAt?: string;
  confidenceBps?: number;
  payloadURI?: string;
  checks: Check[];
}

export interface Context {
  client: PublicClient;
  network: Network;
  set: ContractSet;
  briefs: Map<bigint, Promise<Brief>>;
}

interface Brief {
  title: string;
  brief: string;
  /** Best first. */
  levels: string[];
  /** Index into `levels` of the lowest level that still gets paid. */
  passIndex: number;
}

interface Published {
  kind: string;
  subject: string;
  request: { state: string; questions: { decision: { type: string; criteria: Record<string, string> | string[] } } };
  answer: string;
  confidence: number;
  /** Grades recorded since the chain gates on the paid levels; older grades recorded this as their confidence. */
  scoreConfidence?: number;
  probabilities: Record<string, number>;
  /** Grades and rulings graded twice: the second grader's answer, and the probability of paying from each. */
  jevPaid?: number;
  /** The lowest level, counting from the bottom, that passes. */
  passFrom?: unknown;
  second?: { model: string; probabilities: Record<string, number>; paid: number; receipt: { id: string } | null; requestHash: string };
  /** How the brief's checks ran on the delivered code; failed checks refund at full confidence. */
  checks?: "passed" | "failed";
}

interface State {
  task?: { brief?: string; levels?: string[]; paidLevels?: string[] };
  call?: unknown;
}

type Decision = Awaited<ReturnType<typeof readDecision>>;

const Kind = { Hire: 1, Grade: 2, Ruling: 3, Change: 4 } as const;
const KINDS: Record<number, string> = { 1: "hire", 2: "grade", 3: "ruling", 4: "change" };
const Status = { Graded: 4, Disputed: 5, Paid: 6 } as const;
const STATUS = ["none", "open", "hired", "delivered", "graded", "disputed", "paid", "refunded", "ruled", "appealed"];
const YES: Hex = `0x${"0".repeat(63)}1`;
const NO: Hex = `0x${"0".repeat(64)}`;
const YES_ANSWERS = new Set(["accept", "pay", "adopt", "allow"]);
const NO_ANSWERS = new Set(["reject", "refund", "keep", "refuse"]);
// TypeSafe rounds probabilities and its own choice confidence to two decimals,
// so a hire's confidence recomputed from the probabilities can differ slightly.
const ROUNDING = 0.02;
// The brain keeps a probability of paying to four decimals.
const share = (parts: number[]): number => Math.min(1, Number(parts.reduce((sum, p) => sum + p, 0).toFixed(4)));
const twice = (record: Published): boolean => record.second !== undefined || record.checks !== undefined;

const ADDRESS = /^0x[0-9a-f]{40}$/i;
const short = (value: string): string => `${value.slice(0, 6)}…${value.slice(-4)}`;
// Staked workers answer by address, which reads better shortened.
const named = (answer: string): string => (ADDRESS.test(answer) ? short(answer) : answer);
const percent = (bps: number): string => `${(bps / 100).toFixed(bps % 100 === 0 ? 0 : 2)}%`;
const utc = (seconds: bigint): string => new Date(Number(seconds) * 1000).toISOString().replace("T", " ").slice(0, 19);
const same = (a: unknown, b: unknown): boolean =>
  a !== undefined && b !== undefined && canonicalStringify(a) === canonicalStringify(b);
// Posters write brief locations and hosts write records, and all of it reaches a terminal through these messages.
export const clean = (text: string): string => text.replace(/[\p{Cc}\p{Cf}\u2028\u2029]/gu, "?");
const display = (uri: string): string => (uri.length > 120 ? `${uri.slice(0, 117)}…` : uri);

// fetch says only "fetch failed" and keeps the reason, a refused connection or
// a redirect, in its causes. viem's own errors carry theirs in `details`.
function rootCause(error: Error): string | undefined {
  let reason: string | undefined;
  for (let next = error.cause; next instanceof Error; next = next.cause) {
    if (!(next instanceof BaseError)) reason = next.message || (next as NodeJS.ErrnoException).code || reason;
  }
  return reason;
}

export function errorMessage(error: unknown): string {
  if (!(error instanceof Error)) return clean(String(error));
  const reason = rootCause(error);
  if (error instanceof BaseError) {
    const detail = reason ?? error.details;
    return clean(detail ? `${error.shortMessage} (${detail})` : error.shortMessage);
  }
  return clean(reason ? `${error.message}: ${reason}` : error.message);
}

function parseJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function decodeText(bytes: Uint8Array): string | undefined {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return undefined;
  }
}

/** Base, Base Sepolia, Robinhood Chain and its testnet, where ACP evaluations come from. The service's ACP_CHAINS must stay within this list. */
const ACP_CHAINS = [8453n, 84532n, 4663n, 46630n];

type Outside = { rule: "x402-grade"; id: Hex } | { rule: "acp-evaluation"; chain: bigint; job: bigint };

/** What a grade's subject is, if it is the one the service derives for work delivered elsewhere: a paid grade by its id, or an ACP evaluation by its job. */
function outsideGrade(recorded: string, subject: Hex): Outside | undefined {
  if (!/^\d+$/.test(recorded)) return undefined;
  const id = BigInt(recorded);
  if (id >> 256n !== 0n) return undefined;
  const hex = toHex(id, { size: 32 });
  if (keccak256(encodeAbiParameters([{ type: "string" }, { type: "bytes32" }], ["x402-grade", hex])) === subject) return { rule: "x402-grade", id: hex };
  const chain = ACP_CHAINS.find((c) => keccak256(encodeAbiParameters([{ type: "string" }, { type: "uint256" }, { type: "uint256" }], ["acp-evaluation", c, id])) === subject);
  return chain === undefined ? undefined : { rule: "acp-evaluation", chain, job: id };
}

const outsideSubject = (outside: Outside): string =>
  outside.rule === "x402-grade"
    ? `subject: a paid grade of work delivered outside BrainChain. keccak256(abi.encode("x402-grade", ${short(outside.id)})), from the record's number, is the subject on chain, so no task on this board`
    : `subject: an evaluation of ACP job ${outside.job} on chain ${outside.chain}. keccak256(abi.encode("acp-evaluation", ${outside.chain}, ${outside.job})), from the record's number, is the subject on chain, so no task on this board`;

/** TaskBoard.subjectOf(id): the task on this board on this chain. */
function taskSubject(chainId: number, board: Address, task: bigint): Hex {
  return keccak256(
    encodeAbiParameters([{ type: "uint256" }, { type: "address" }, { type: "uint256" }], [BigInt(chainId), board, task]),
  );
}

/** DecisionExecutor.changeSubject(target, data): this exact call, through this executor, on this chain. */
function changeSubject(chainId: number, executor: Address, target: Address, data: Hex): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "uint256" }, { type: "address" }, { type: "address" }, { type: "bytes" }],
      [BigInt(chainId), executor, target, data],
    ),
  );
}

const plain = (value: unknown): unknown =>
  typeof value === "bigint"
    ? value.toString()
    : Array.isArray(value)
      ? value.map(plain)
      : typeof value === "object" && value !== null
        ? Object.fromEntries(Object.entries(value).map(([k, v]) => [k, plain(v)]))
        : value;

// Must decode exactly as the brain did when it showed Jev the call.
function decodeChange(target: Address, data: Hex): Record<string, unknown> {
  for (const abi of [taskBoardAbi, decisionExecutorAbi, modelRegistryAbi, decisionLogAbi] as readonly Abi[]) {
    try {
      const { functionName, args } = decodeFunctionData({ abi, data });
      return { target, function: functionName, args: plain(args ?? []) };
    } catch {
      // Not this contract's interface; try the next one.
    }
  }
  return { target, function: "unknown", selector: data.slice(0, 10), data };
}

function isPublished(value: unknown): value is Published {
  const r = value as Partial<Published> | null | undefined;
  return (
    typeof r === "object" &&
    r !== null &&
    typeof r.kind === "string" &&
    typeof r.subject === "string" &&
    typeof r.answer === "string" &&
    typeof r.confidence === "number" &&
    typeof r.probabilities === "object" &&
    r.probabilities !== null &&
    typeof r.request?.state === "string" &&
    typeof r.request.questions?.decision === "object" &&
    r.request.questions.decision !== null
  );
}

function parseBrief(text: string | undefined): Brief {
  const b = (text === undefined ? undefined : parseJson(text)) as Partial<Brief> | null | undefined;
  const valid =
    typeof b?.title === "string" &&
    typeof b.brief === "string" &&
    Array.isArray(b.levels) &&
    b.levels.every((level) => typeof level === "string") &&
    typeof b.passIndex === "number" &&
    Number.isInteger(b.passIndex) &&
    b.passIndex >= 0 &&
    b.passIndex < b.levels.length;
  if (!valid) throw new Error("the brief is not a title, a text, quality levels and a pass level");
  return b as Brief;
}

const ATTEMPT_MS = 15_000;
// One slow try and most of another: a host cannot hold the tool longer, however slowly it sends.
const FETCH_MS = 30_000;
// A connection that stalls is given up on soon enough for all three tries to fit in FETCH_MS.
const STALL_MS = 8_000;
// A record holds a result of up to 100,000 bytes, quoted twice over, beside its brief and the graders' answers.
const MAX_RECORD_BYTES = 4 * 1024 * 1024;
// What a worker will read of a brief.
const MAX_BRIEF_BYTES = 256 * 1024;

interface Fetched {
  bytes: Uint8Array;
  withheld: boolean;
}

/** What is being fetched: names it in messages, and caps it. */
interface Wanted {
  what: "record" | "brief";
  limit: number;
  /** The caller's RPC is on a private address, so what it names may be too. */
  allowPrivate: boolean;
}

/** A location the tool will not read. Trying again would not help. */
class Refused extends Error {}

const PRIVATE = new BlockList();
for (const [net, bits] of [["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8], ["169.254.0.0", 16], ["172.16.0.0", 12], ["192.0.0.0", 24], ["192.168.0.0", 16], ["224.0.0.0", 4], ["240.0.0.0", 4]] as const) {
  PRIVATE.addSubnet(net, bits, "ipv4");
}
for (const [net, bits] of [["::", 128], ["::1", 128], ["64:ff9b::", 96], ["2002::", 16], ["fc00::", 7], ["fe80::", 10], ["fec0::", 10], ["ff00::", 8]] as const) {
  PRIVATE.addSubnet(net, bits, "ipv6");
}
const isPrivate = (address: string): boolean => PRIVATE.check(address, isIP(address) === 6 ? "ipv6" : "ipv4");
const bareHost = (url: URL): string => url.hostname.replace(/^\[|\]$/g, "");

/** Whether the RPC this client reads from is on a private address, by address or by what its name resolves to. */
async function rpcIsPrivate(url: unknown): Promise<boolean> {
  if (typeof url !== "string" || !URL.canParse(url)) return false;
  const host = bareHost(new URL(url));
  if (isIP(host) !== 0) return isPrivate(host);
  const found = await dns.lookup(host, { all: true }).catch(() => []);
  return found.some((entry) => isPrivate(entry.address));
}
const privateRpc = new WeakMap<object, Promise<boolean>>();
function allowsPrivate(client: PublicClient): Promise<boolean> {
  let known = privateRpc.get(client);
  if (!known) {
    known = rpcIsPrivate((client.transport as { url?: unknown } | undefined)?.url);
    privateRpc.set(client, known);
  }
  return known;
}

const privateAddress = (where: string, address: string): Refused => new Refused(`${display(where)} is on the private address ${address}, so it was not fetched`);

// Checked as the socket connects, so a name cannot pass here and then resolve somewhere else.
function publicLookup(hostname: string, options: { all?: boolean }, callback: (...args: unknown[]) => void): void {
  dnsLookup(hostname, { ...options, all: true }, (error, found: LookupAddress[]) => {
    if (error) return callback(error);
    const blocked = found.find((entry) => isPrivate(entry.address));
    if (blocked) return callback(privateAddress(hostname, blocked.address));
    if (options.all) return callback(null, found);
    return callback(null, found[0]?.address, found[0]?.family);
  });
}

// Connections are reused, as fetch does: new ones to a host are what stall.
const agents = new Map<string, HttpAgent>();
function agentFor(protocol: string, allowPrivate: boolean): HttpAgent {
  const key = `${protocol}${allowPrivate}`;
  let agent = agents.get(key);
  if (!agent) {
    const options = { keepAlive: true, ...(allowPrivate ? {} : { lookup: publicLookup as never }) };
    agent = protocol === "https:" ? new HttpsAgent(options) : new HttpAgent(options);
    agents.set(key, agent);
  }
  return agent;
}

function readOnce(uri: string, url: URL, wanted: Wanted, signal: AbortSignal): Promise<Fetched & { status: number }> {
  return new Promise((resolve, reject) => {
    const send = url.protocol === "https:" ? httpsRequest : httpRequest;
    // Redirects are not followed: the brain reads without following them, so the location on chain is the one read here too.
    const request = send(url, { signal, agent: agentFor(url.protocol, wanted.allowPrivate), timeout: STALL_MS, headers: { "user-agent": "brainchain-verify" } }, (response) => {
      const chunks: Buffer[] = [];
      let size = 0;
      response.on("data", (chunk: Buffer) => {
        size += chunk.length;
        if (size > wanted.limit) request.destroy(new Refused(`${display(uri)} is larger than the ${Math.round(wanted.limit / 1024)} KB a ${wanted.what} may be, so it was not read`));
        else chunks.push(chunk);
      });
      response.on("end", () =>
        resolve({
          status: response.statusCode ?? 0,
          bytes: new Uint8Array(Buffer.concat(chunks)),
          withheld: response.headers["x-brainchain-withheld"] === "result",
        }),
      );
      response.on("error", reject);
    });
    request.on("timeout", () => request.destroy(new Error(`${display(uri)} went ${STALL_MS / 1000} seconds without answering`)));
    request.on("error", reject);
    request.end();
  });
}

// A records host answers 5xx while it restarts, so those get two more tries.
async function get(uri: string, url: URL, wanted: Wanted, deadline: AbortSignal): Promise<Fetched & { status: number }> {
  for (let attempt = 1; ; attempt++) {
    try {
      const response = await readOnce(uri, url, wanted, AbortSignal.any([deadline, AbortSignal.timeout(ATTEMPT_MS)]));
      const transient = response.status === 408 || response.status === 429 || response.status >= 500;
      if (!transient || attempt === 3) return response;
    } catch (error) {
      if (error instanceof Refused || attempt === 3) throw error;
    }
    await sleep(attempt * 1_000, undefined, { signal: deadline });
  }
}

async function readBytes(uri: string, url: URL, wanted: Wanted, deadline: AbortSignal): Promise<Fetched> {
  const response = await get(uri, url, wanted, deadline);
  if (response.status === 404) throw new Error(`${display(uri)} answered with status 404: the host no longer has this ${wanted.what}, so trying again will not help`);
  if (response.status < 200 || response.status >= 300) throw new Error(`${display(uri)} answered with status ${response.status}`);
  return { bytes: response.bytes, withheld: response.withheld };
}

async function fetchBytes(uri: string, wanted: Wanted): Promise<Fetched> {
  if (uri.startsWith("data:")) {
    const comma = uri.indexOf(",");
    if (comma < 0 || !uri.slice(0, comma).endsWith(";base64")) throw new Error("only base64 data URIs are supported");
    const bytes = Uint8Array.from(Buffer.from(uri.slice(comma + 1), "base64"));
    if (bytes.length > wanted.limit) throw new Refused(`the ${wanted.what} is larger than the ${Math.round(wanted.limit / 1024)} KB it may be, so it was not read`);
    return { bytes, withheld: false };
  }
  if (!URL.canParse(uri)) throw new Refused(`${display(uri)} is not a URL`);
  const url = new URL(uri);
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Refused(`${url.protocol} URIs are not supported`);
  // A literal address never reaches the lookup below.
  if (!wanted.allowPrivate && isIP(bareHost(url)) !== 0 && isPrivate(bareHost(url))) throw privateAddress(uri, bareHost(url));
  const started = Date.now();
  const deadline = AbortSignal.timeout(FETCH_MS);
  // Raced as well as passed down, so no stage of the transport can outlast the deadline.
  const expired = new Promise<never>((_, reject) => deadline.addEventListener("abort", () => reject(deadline.reason), { once: true }));
  try {
    return await Promise.race([readBytes(uri, url, wanted, deadline), expired]);
  } catch (error) {
    if (!(error instanceof Refused) && (deadline.aborted || ["TimeoutError", "AbortError"].includes((error as Error).name))) {
      throw new Error(`${display(uri)} did not finish answering within ${Math.round((Date.now() - started) / 1000)} seconds`);
    }
    throw error;
  }
}

class Checks {
  public readonly list: Check[] = [];

  public add(name: string, status: Status, message: string): void {
    this.list.push({ name, status, message: clean(message) });
  }

  public check(name: string, pass: boolean, ok: string, otherwise: string): void {
    this.add(name, pass ? "ok" : "fail", pass ? ok : otherwise);
  }
}

function readDecision({ client, set }: Context, id: bigint) {
  return client.readContract({ address: set.log, abi: decisionLogAbi, functionName: "get", args: [id] });
}

/** Bytes that are not what the chain committed to: a disagreement, where an unreachable host is only a check that could not run. */
class BriefMismatch extends Error {}

async function briefOf({ client, set }: Context, task: bigint): Promise<Brief> {
  const [posted] = await client.getContractEvents({
    address: set.board,
    abi: taskBoardAbi,
    eventName: "Posted",
    args: { id: task },
    fromBlock: BigInt(set.fromBlock),
    strict: true,
  });
  if (!posted) throw new Error(`task ${task} has no Posted event on board ${set.board}`);
  const { bytes } = await fetchBytes(posted.args.briefURI, { what: "brief", limit: MAX_BRIEF_BYTES, allowPrivate: await allowsPrivate(client) });
  if (keccak256(bytes) !== posted.args.briefHash.toLowerCase()) throw new BriefMismatch(`task ${task}'s brief does not match its briefHash on chain`);
  return parseBrief(decodeText(bytes));
}

/** Decision ids about one task on the set's board, oldest first. */
export async function decisionsOf({ client, network, set }: Context, task: bigint): Promise<bigint[]> {
  const events = await client.getContractEvents({
    address: set.log,
    abi: decisionLogAbi,
    eventName: "Recorded",
    args: { subject: taskSubject(network.chainId, set.board, task) },
    fromBlock: BigInt(set.fromBlock),
    strict: true,
  });
  return events.map((e) => e.args.id).sort((a, b) => (a < b ? -1 : 1));
}

export async function verifyDecision(ctx: Context, id: bigint): Promise<DecisionReport> {
  const { client, network, set } = ctx;
  const c = new Checks();
  const decision = await readDecision(ctx, id);
  const kind = KINDS[decision.kind] ?? `kind ${decision.kind}`;
  const report: DecisionReport = {
    id: Number(id),
    kind,
    recordedAt: `${utc(decision.recordedAt)} UTC`,
    confidenceBps: decision.confidenceBps,
    checks: c.list,
  };

  const [recorded] = await client.getContractEvents({
    address: set.log,
    abi: decisionLogAbi,
    eventName: "Recorded",
    args: { id },
    fromBlock: BigInt(set.fromBlock),
    strict: true,
  });
  if (!recorded) {
    c.add("read", "fail", `decision ${id} has no Recorded event on DecisionLog ${set.log}`);
    return report;
  }
  const e = recorded.args;
  report.block = Number(recorded.blockNumber);
  report.payloadURI = clean(e.payloadURI);
  c.check(
    "read",
    e.kind === decision.kind &&
      e.subject === decision.subject &&
      e.inputHash === decision.inputHash &&
      e.answer === decision.answer &&
      e.confidenceBps === decision.confidenceBps,
    `read from DecisionLog ${short(set.log)}: ${kind}, recorded ${report.recordedAt} in block ${recorded.blockNumber}, confidence ${decision.confidenceBps} bps`,
    `the Recorded event in block ${recorded.blockNumber} differs from what DecisionLog.get(${id}) returns`,
  );

  let fetched: Fetched;
  try {
    fetched = await fetchBytes(e.payloadURI, { what: "record", limit: MAX_RECORD_BYTES, allowPrivate: await allowsPrivate(client) });
  } catch (error) {
    c.add("fetch", "error", `could not fetch the record: ${errorMessage(error)}`);
    return report;
  }
  const text = decodeText(fetched.bytes);
  const record = text === undefined ? undefined : parseJson(text);
  if (!isPublished(record)) {
    c.add("fetch", "fail", `${display(e.payloadURI)} is not a decision record`);
    return report;
  }

  const outside = decision.kind === Kind.Grade ? outsideGrade(record.subject, decision.subject) : undefined;
  const task = !outside && decision.kind !== Kind.Change && /^\d+$/.test(record.subject) ? BigInt(record.subject) : undefined;
  if (task !== undefined) report.task = Number(task);
  if (outside) report.outside = true;

  const hash = keccak256(fetched.bytes);
  // The header is only the host's word. It counts when the record misses its hash and the chain shows the work may be withheld.
  const excuse = fetched.withheld && hash !== e.payloadHash ? await withholding(ctx, decision, record, task, outside, recorded.blockNumber) : undefined;
  if (excuse?.allowed) report.withheld = true;

  c.add("fetch", "ok", `fetched the record from ${display(e.payloadURI)}${excuse?.allowed ? ", served without the work" : ""}`);
  if (excuse) c.add("withheld", excuse.allowed ? "ok" : "fail", `withheld: ${excuse.why}`);

  if (excuse?.allowed) {
    c.add("record-hash", "skip", "record hash: this copy is served without the work, so it cannot match payloadHash, and nothing ties its text to the chain");
    c.add("input-hash", "skip", "request hash: the request quotes the withheld work, so it cannot match inputHash");
  } else {
    c.check(
      "record-hash",
      hash === e.payloadHash,
      `record hash matches payloadHash ${short(hash)}`,
      `record hash ${short(hash)} differs from payloadHash ${short(e.payloadHash)}`,
    );
    const input = keccak256(toBytes(canonicalStringify(record.request)));
    c.check(
      "input-hash",
      input === decision.inputHash,
      `request hash matches inputHash ${short(input)}`,
      `request hash ${short(input)} differs from inputHash ${short(decision.inputHash)}`,
    );
  }

  c.check("kind", record.kind === kind, `kind: ${record.kind}`, `the record is a ${record.kind}; the chain recorded a ${kind}`);

  if (decision.kind === Kind.Change) {
    c.check(
      "subject",
      record.subject.toLowerCase() === decision.subject,
      `subject: ${short(decision.subject)}, the exact call this change names`,
      "the record's subject differs from the one on chain",
    );
  } else if (outside) {
    c.add("subject", "ok", outsideSubject(outside));
  } else {
    c.check(
      "subject",
      task !== undefined && taskSubject(network.chainId, set.board, task) === decision.subject,
      `subject: task ${record.subject} on board ${short(set.board)}, chain ${network.chainId}`,
      `the record names task ${record.subject}, which is not the subject recorded on chain`,
    );
  }

  const question = record.request.questions.decision;
  const options = Array.isArray(question.criteria) ? question.criteria.map((_, i) => String(i)) : Object.keys(question.criteria ?? {});
  c.check(
    "options",
    same(Object.keys(record.probabilities).sort(), [...options].sort()),
    "probabilities cover exactly the options Jev was asked",
    "the probabilities do not match the options in the question",
  );

  let expectedAnswer: Hex | undefined;
  if (decision.kind === Kind.Hire) {
    // A staked worker's name is its address, and its id the address left-padded to 32 bytes.
    expectedAnswer = ADDRESS.test(record.answer) ? pad(record.answer as Hex) : keccak256(toBytes(record.answer));
  } else if (YES_ANSWERS.has(record.answer)) {
    expectedAnswer = YES;
  } else if (NO_ANSWERS.has(record.answer)) {
    expectedAnswer = NO;
  }
  c.check(
    "answer",
    expectedAnswer?.toLowerCase() === decision.answer,
    `answer: ${named(record.answer)}, recorded as ${short(decision.answer)}`,
    `the record answers "${record.answer}"; the chain recorded ${decision.answer}`,
  );
  c.check(
    "confidence",
    Math.round(record.confidence * 10_000) === decision.confidenceBps,
    `confidence: ${record.confidence} is ${decision.confidenceBps} bps, as recorded`,
    `the record's confidence ${record.confidence} is ${Math.round(record.confidence * 10_000)} bps; the chain recorded ${decision.confidenceBps}`,
  );

  const chosen = record.probabilities[record.answer];
  if (decision.kind !== Kind.Grade && !(decision.kind === Kind.Ruling && twice(record))) {
    const top = Math.max(...Object.values(record.probabilities));
    c.check(
      "top-option",
      chosen !== undefined && chosen >= top - 1e-9,
      `${named(record.answer)} is Jev's most likely option, at ${chosen}`,
      `${named(record.answer)} is not Jev's most likely option`,
    );
  }
  if (decision.kind === Kind.Hire) {
    const n = options.length;
    const p = chosen ?? 0;
    const recomputed = (p - 1 / n) / (1 - 1 / n);
    c.check(
      "confidence-recomputed",
      Math.abs(recomputed - record.confidence) <= ROUNDING,
      `confidence recomputed: (${p} - 1/${n}) / (1 - 1/${n}) = ${recomputed.toFixed(4)}, within rounding of ${record.confidence}`,
      `confidence recomputed from the probabilities is ${recomputed.toFixed(4)}, not ${record.confidence}`,
    );
  }
  if (decision.kind === Kind.Ruling && twice(record)) {
    checkPaying(c, record, { jev: record.probabilities.pay ?? 0, second: record.second?.probabilities.pay, yes: "pay", no: "refund" });
  } else if (decision.kind === Kind.Ruling || decision.kind === Kind.Change) {
    c.check(
      "confidence-recomputed",
      record.confidence === chosen,
      `confidence recomputed: the probability of ${record.answer}, ${chosen}`,
      `confidence ${record.confidence} is not the probability of ${record.answer}`,
    );
  }

  const state = (parseJson(record.request.state) ?? {}) as State;
  if (task !== undefined) {
    await checkBrief(ctx, c, task, decision, record, state);
    await checkTaskThreshold(ctx, c, id, task, decision, record);
  }
  if (outside) {
    checkOutsideGrade(c, record, report.withheld === true);
    c.add("threshold", "skip", "threshold: no task on this chain, so no board applied this grade; the caller received the verdict");
  }
  if (decision.kind === Kind.Change) await checkChange(ctx, c, id, decision, record, state);
  return report;
}

const WITHHELD = "[withheld until the work is accepted]";
const withheldField = (value: unknown): boolean => value === undefined || value === WITHHELD;

/**
 * Whether a record that misses its hash may really be the withheld form the
 * records service serves. The rules are that service's own (access and
 * resultIsPublic in the brain's records.ts), read here from the chain: only
 * grades and rulings carry work, a task's work stays private until it is
 * accepted or paid, a paid grade's until it is accepted, and an ACP
 * evaluation's delivery always.
 */
async function withholding(ctx: Context, decision: Decision, record: Published, task: bigint | undefined, outside: Outside | undefined, block: bigint): Promise<{ allowed: boolean; why: string }> {
  const { client, network, set } = ctx;
  const refuse = (why: string) => ({ allowed: false, why: `the host says this copy leaves out the work, but ${why}` });
  if (decision.kind !== Kind.Grade && decision.kind !== Kind.Ruling) return refuse(`a ${KINDS[decision.kind] ?? "decision"} record carries no work to leave out`);
  const state = (parseJson(record.request.state) ?? {}) as { result?: unknown; execution?: { output?: unknown; error?: unknown } };
  if (state.result !== WITHHELD || !withheldField(state.execution?.output) || !withheldField(state.execution?.error)) {
    return refuse("the request does not mark the work as withheld where the service does");
  }
  if (outside?.rule === "acp-evaluation") return { allowed: true, why: "the delivery in an ACP evaluation is never published" };
  if (outside) {
    if (decision.answer !== YES) return { allowed: true, why: `a paid grade is published only once accepted, and Jev answered ${named(record.answer)}` };
    const config = await client.readContract({ address: set.board, abi: taskBoardAbi, functionName: "config", blockNumber: block }).catch(() => client.readContract({ address: set.board, abi: taskBoardAbi, functionName: "config" }));
    const bar = config[1];
    if (decision.confidenceBps >= bar) return refuse(`this paid grade cleared the ${percent(bar)} bar, so its record is public`);
    return { allowed: true, why: `a paid grade is published only once accepted, and ${percent(decision.confidenceBps)} is below the ${percent(bar)} bar` };
  }
  if (task === undefined || taskSubject(network.chainId, set.board, task) !== decision.subject) return refuse("the record does not name the task on chain");
  const on = await client.readContract({ address: set.board, abi: taskBoardAbi, functionName: "get", args: [task] });
  const house = on.poster.toLowerCase() === set.executor.toLowerCase();
  const status = STATUS[on.status] ?? `status ${on.status}`;
  const open = house ? on.status >= Status.Graded : on.status === Status.Paid || ((on.status === Status.Graded || on.status === Status.Disputed) && on.accepted);
  if (open) return refuse(`task ${task} is ${status}${on.accepted ? " and accepted" : ""}, so its record is public`);
  return { allowed: true, why: `task ${task} is ${status}${on.status >= Status.Graded && !on.accepted ? " and its work was not accepted" : ""}, so its work is not public` };
}

async function checkBrief(ctx: Context, c: Checks, task: bigint, decision: Decision, record: Published, state: State): Promise<void> {
  let pending = ctx.briefs.get(task);
  if (!pending) {
    pending = briefOf(ctx, task);
    ctx.briefs.set(task, pending);
  }
  let brief: Brief;
  try {
    brief = await pending;
  } catch (error) {
    c.add("brief", error instanceof BriefMismatch ? "fail" : "skip", `brief: ${errorMessage(error)}`);
    if (decision.kind === Kind.Grade) c.add("confidence-recomputed", "skip", "grade confidence: needs the brief's pass level");
    return;
  }

  c.check(
    "brief",
    state.task?.brief === `${brief.title}\n\n${brief.brief}`,
    `the question quotes task ${task}'s brief, as committed on chain`,
    `the brief in the question is not task ${task}'s brief`,
  );
  const question = record.request.questions.decision;

  if (decision.kind === Kind.Ruling) {
    c.check(
      "levels",
      same(state.task?.levels, brief.levels) && same(state.task?.paidLevels, brief.levels.slice(0, brief.passIndex + 1)),
      "the levels and paid levels Jev was shown are the brief's",
      "the levels in the question are not the brief's",
    );
  }
  if (decision.kind !== Kind.Grade) return;

  const ascending = [...brief.levels].reverse();
  c.check(
    "levels",
    same(question.criteria, ascending),
    "the levels Jev scored against are the brief's, lowest first",
    "the levels in the question are not the brief's",
  );
  if (record.scoreConfidence === undefined) {
    c.add(
      "confidence-recomputed",
      "skip",
      "grade confidence: this grade predates the rule that gates on the paid levels, so its confidence is Jev's score confidence, which the probabilities alone do not give",
    );
    return;
  }
  checkGradeConfidence(c, record, ascending.map((_, i) => String(i)).slice(ascending.length - 1 - brief.passIndex));
}

// No brief on chain to compare with. payloadHash commits a whole record's levels and pass level, and nothing commits a withheld record's.
function checkOutsideGrade(c: Checks, record: Published, withheld: boolean): void {
  const levels = record.request.questions.decision.criteria;
  const { passFrom } = record;
  if (!Array.isArray(levels) || passFrom === undefined) {
    c.add("confidence-recomputed", "skip", "grade confidence: the record does not name its pass level");
    return;
  }
  // The lowest level never passes, or every result would.
  if (typeof passFrom !== "number" || !Number.isInteger(passFrom) || passFrom < 1 || passFrom >= levels.length) {
    c.add("levels", "fail", `levels: the record's pass level ${JSON.stringify(passFrom)} is not one of levels 1 to ${levels.length - 1} of the ${levels.length} the question lists`);
    c.add("confidence-recomputed", "skip", "grade confidence: needs a valid pass level");
    return;
  }
  c.add("levels", "skip", `levels: the record's own ${levels.length} levels, paid from level ${passFrom}. No brief on chain says what they should be${withheld ? ", and no hash commits them on this copy" : ""}`);
  checkGradeConfidence(c, record, levels.map((_, i) => String(i)).slice(passFrom));
}

function checkGradeConfidence(c: Checks, record: Published, paidKeys: string[]): void {
  const parts = paidKeys.map((key) => record.probabilities[key] ?? 0);
  const jev = share(parts);
  const how = `paid levels ${paidKeys.join(", ")} hold ${parts.join(" + ")} = ${jev.toFixed(4)}`;
  if (!twice(record)) {
    const accept = jev >= 0.5;
    const confidence = accept ? jev : 1 - jev;
    c.check(
      "confidence-recomputed",
      Math.abs(confidence - record.confidence) < 1e-6 && record.answer === (accept ? "accept" : "reject"),
      `confidence recomputed: ${how}, so ${accept ? "accept" : "reject"} at ${confidence.toFixed(4)}`,
      `recomputed from the probabilities, the grade is ${accept ? "accept" : "reject"} at ${confidence.toFixed(4)}, not ${record.answer} at ${record.confidence}`,
    );
    return;
  }
  const second = record.second ? share(paidKeys.map((key) => record.second!.probabilities[key] ?? 0)) : undefined;
  checkPaying(c, record, { jev, second, yes: "accept", no: "reject", how });
}

/**
 * The rule grades and rulings share since they are graded twice: the
 * probability of paying is the lower of Jev's and the second grader's, zero
 * when the brief's checks failed, and the answer and confidence follow it.
 */
function checkPaying(c: Checks, record: Published, p: { jev: number; second?: number; yes: string; no: string; how?: string }): void {
  const steps: string[] = [p.how ?? `Jev puts ${p.jev} on ${p.yes}`];
  let paying = p.jev;
  if (record.second) {
    c.check(
      "second-grader",
      p.second !== undefined && Math.abs(p.second - record.second.paid) < 1e-6 && Math.abs((record.jevPaid ?? p.jev) - p.jev) < 1e-6,
      `the second grader (${record.second.model}) puts ${p.second} on paying${record.second.receipt ? `, with receipt ${record.second.receipt.id}` : ", without a receipt"}`,
      `the second grader's probability of paying recomputes to ${p.second}, not the recorded ${record.second.paid}`,
    );
    if (p.second !== undefined) {
      paying = Math.min(paying, p.second);
      steps.push(`the second grader holds ${p.second.toFixed(4)}, so the lower, ${paying.toFixed(4)}, counts`);
    }
  }
  if (record.checks === "failed") {
    paying = 0;
    steps.push("the brief's checks failed on the delivered code, so the probability of paying is 0");
  } else if (record.checks === "passed") {
    steps.push("the brief's checks passed");
  }
  const yes = paying >= 0.5;
  const confidence = yes ? paying : 1 - paying;
  c.check(
    "confidence-recomputed",
    Math.abs(confidence - record.confidence) < 1e-6 && record.answer === (yes ? p.yes : p.no),
    `confidence recomputed: ${steps.join("; ")}, so ${yes ? p.yes : p.no} at ${confidence.toFixed(4)}`,
    `recomputed under the two-grader rule, the decision is ${yes ? p.yes : p.no} at ${confidence.toFixed(4)}, not ${record.answer} at ${record.confidence}`,
  );
}

// Applies each threshold the way TaskBoard.hire, grade and rule do, then
// compares with what the board did. raiseGradeBar can lift the grade and ruling
// thresholds above what was posted, but only while the task is open, and a task
// never reopens once hired, so the values read now are the ones any grade or
// ruling was applied at.
async function checkTaskThreshold(ctx: Context, c: Checks, id: bigint, task: bigint, decision: Decision, record: Published): Promise<void> {
  const { client, set } = ctx;
  const terms = await client.readContract({ address: set.board, abi: taskBoardAbi, functionName: "get", args: [task] });
  const filter = { address: set.board, abi: taskBoardAbi, args: { id: task, decisionId: id }, fromBlock: BigInt(set.fromBlock), strict: true } as const;
  const bps = decision.confidenceBps;
  const rule = (threshold: number, name: string): string =>
    `threshold: ${named(record.answer)} at ${percent(bps)} is ${bps >= threshold ? "at or above" : "below"} task ${task}'s ${percent(threshold)} ${name} threshold`;

  if (decision.kind === Kind.Hire) {
    const hires = bps >= terms.hireThresholdBps && decision.answer !== NO;
    const expected = `${rule(terms.hireThresholdBps, "hire")}, so the board ${hires ? "hires it" : "holds the hire"}`;
    const [hired] = await client.getContractEvents({ ...filter, eventName: "WorkerHired" });
    const [held] = await client.getContractEvents({ ...filter, eventName: "HireHeld" });
    if (!hired && !held) {
      c.add("threshold", "skip", `${expected}; this decision was not applied, and a later decision or the task's deadline settled the task`);
      return;
    }
    const pass = hired ? hires && hired.args.model === decision.answer : !hires;
    c.check("threshold", pass, `${expected}, and it did`, `${expected}, but it ${hired ? `hired ${short(hired.args.model)}` : "held the hire"}`);
    return;
  }

  if (decision.kind === Kind.Grade) {
    const accepts = decision.answer === YES && bps >= terms.gradeThresholdBps;
    const expected =
      decision.answer === YES
        ? `${rule(terms.gradeThresholdBps, "grade")}, so the work is ${accepts ? "accepted" : "not accepted"}`
        : `threshold: Jev answered ${record.answer}, so the work is not accepted at any confidence`;
    const [graded] = await client.getContractEvents({ ...filter, eventName: "WorkGraded" });
    if (!graded) {
      c.add("threshold", "skip", `${expected}; this decision was not applied, and a later decision or the grade window settled the task`);
      return;
    }
    c.check(
      "threshold",
      graded.args.accepted === accepts,
      `${expected}, as the board recorded`,
      `${expected}, but the board recorded it as ${graded.args.accepted ? "accepted" : "not accepted"}`,
    );
    return;
  }

  const confident = bps >= terms.ruleThresholdBps;
  const pays = decision.answer === YES;
  // A second ruling, after an appeal (set 3.5.0 and later), is applied by ruleAppeal.
  const [appealRuled] = await client.getContractEvents({ ...filter, eventName: "AppealRuled" });
  if (appealRuled) {
    const expected = `${rule(terms.ruleThresholdBps, "ruling")}, so on appeal ${confident ? `the ruling decides: ${pays ? "pay the model" : "refund the poster"}` : "the ruling under appeal stands"}`;
    const outcome = `${appealRuled.args.paid ? "the model was paid" : "the poster was refunded"}${appealRuled.args.overturned ? ", overturning the ruling under appeal" : ""}`;
    c.check(
      "threshold",
      appealRuled.args.confident === confident && (!confident || appealRuled.args.paid === pays),
      `${expected}; ${outcome}`,
      `${expected}, but the board ${appealRuled.args.confident ? "applied the ruling" : "kept the ruling under appeal"} and ${outcome}`,
    );
    return;
  }
  const expected = `${rule(terms.ruleThresholdBps, "ruling")}, so ${confident ? `the ruling decides: ${pays ? "pay the model" : "refund the poster"}` : "the grade stands"}`;
  const [ruled] = await client.getContractEvents({ ...filter, eventName: "Ruled" });
  if (!ruled) {
    c.add("threshold", "skip", `${expected}; this decision was not applied, and the ruling window closed with the grade standing`);
    return;
  }
  const outcome = ruled.args.paid ? "the ruling pays the model" : "the ruling refunds the poster";
  c.check(
    "threshold",
    ruled.args.confident === confident && (!confident || ruled.args.paid === pays),
    `${expected}; ${outcome}`,
    `${expected}, but the board ${ruled.args.confident ? "applied the ruling" : "kept the grade"} and ${outcome.replace("the ruling ", "")}`,
  );
}

async function checkChange(ctx: Context, c: Checks, id: bigint, decision: Decision, record: Published, state: State): Promise<void> {
  const { client, network, set } = ctx;
  const [queued] = await client.getContractEvents({
    address: set.executor,
    abi: decisionExecutorAbi,
    eventName: "Queued",
    args: { decisionId: id },
    fromBlock: BigInt(set.fromBlock),
    strict: true,
  });
  const at = `${record.answer} at ${percent(decision.confidenceBps)}`;

  if (queued) {
    const { target, data, changeId } = queued.args;
    c.check(
      "change-subject",
      changeSubject(network.chainId, set.executor, target, data) === decision.subject,
      "the queued call is the call this decision names",
      "the queued call does not match the decision's subject",
    );
    c.check(
      "change-call",
      same(decodeChange(target, data), state.call),
      "the queued call is the call Jev was shown",
      "the call Jev was shown differs from the queued call",
    );
    const change = await client.readContract({ address: set.executor, abi: decisionExecutorAbi, functionName: "getChange", args: [changeId] });
    const status = change.vetoed ? "vetoed by the guardian" : change.executed ? "executed" : `executable from ${utc(change.eta).slice(0, 16)} UTC`;
    c.check(
      "threshold",
      decision.answer === YES,
      `threshold: ${at} cleared the executor's change threshold, so it was queued as change ${changeId} behind the timelock, ${status}`,
      `the executor queued change ${changeId} on an answer other than yes`,
    );
    return;
  }

  const threshold = await client.readContract({ address: set.executor, abi: decisionExecutorAbi, functionName: "changeThresholdBps" });
  if (decision.answer !== YES) {
    c.add("threshold", "ok", `threshold: Jev answered ${record.answer}, so nothing is queued and the setting stays as it is`);
  } else if (decision.confidenceBps < threshold) {
    c.add("threshold", "ok", `threshold: ${at} is below today's ${percent(threshold)} change threshold, so nothing is queued`);
  } else {
    c.add("threshold", "skip", `threshold: ${at} clears today's ${percent(threshold)} change threshold; not queued yet, or a newer decision about the same call replaced it`);
  }
}

export type Outcome = "match" | "withheld" | "unverified" | "mismatch";

/** Disagreement first, then what could not be read. A withheld record never reads as a match: its hashes were not checked. */
export function outcomeOf(reports: DecisionReport[]): Outcome {
  const checks = reports.flatMap((r) => r.checks);
  if (checks.some((c) => c.status === "fail")) return "mismatch";
  if (checks.some((c) => c.status === "error")) return "unverified";
  return reports.some((r) => r.withheld) ? "withheld" : "match";
}

/** What a withheld copy leaves unchecked. A grade of outside work has no task here, so nothing on chain backs its brief or levels. */
export function withheldNotChecked(reports: DecisionReport[]): string {
  const withheld = reports.filter((r) => r.withheld);
  const outside = withheld.length > 0 && withheld.every((r) => r.outside);
  return (
    "This copy is served without the work, so its hashes could not be checked and nothing ties its text to the chain. " +
    (outside
      ? "Its answer and confidence agree with the chain. The rest of it, such as the question, its levels and the second grader, is the host's word."
      : "Its answer and confidence agree with the chain, and so do the task's brief, levels and threshold. The rest of it, such as the question and the second grader, is the host's word.")
  );
}
