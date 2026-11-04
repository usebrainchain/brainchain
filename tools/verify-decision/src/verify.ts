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
  passFrom?: number;
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
const display = (uri: string): string => (uri.length > 120 ? `${uri.slice(0, 117)}…` : uri);
export function errorMessage(error: unknown): string {
  if (error instanceof BaseError) return error.details ? `${error.shortMessage} (${error.details})` : error.shortMessage;
  return error instanceof Error ? error.message : String(error);
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

/** Base and Base Sepolia, where ACP evaluations come from. */
const ACP_CHAINS = [8453n, 84532n];

/** Whether a grade's subject is the one the service derives for work delivered elsewhere: a paid grade by its id, or an ACP evaluation by its job. */
function outsideGrade(recorded: string, subject: Hex): boolean {
  if (!/^\d+$/.test(recorded)) return false;
  const id = BigInt(recorded);
  if (id >> 256n !== 0n) return false;
  const paid = keccak256(encodeAbiParameters([{ type: "string" }, { type: "bytes32" }], ["x402-grade", toHex(id, { size: 32 })]));
  if (paid === subject) return true;
  return ACP_CHAINS.some((chain) => keccak256(encodeAbiParameters([{ type: "string" }, { type: "uint256" }, { type: "uint256" }], ["acp-evaluation", chain, id])) === subject);
}

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

// A records host answers 5xx while it restarts, so those get two more tries.
async function get(url: URL): Promise<Response> {
  for (let attempt = 1; ; attempt++) {
    try {
      // The brain reads without following redirects, so the location on chain is the one read here too.
      const response = await fetch(url, { redirect: "error", signal: AbortSignal.timeout(15_000) });
      const transient = response.status === 408 || response.status === 429 || response.status >= 500;
      if (!transient || attempt === 3) return response;
    } catch (error) {
      if (attempt === 3) throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, attempt * 1_000));
  }
}

async function fetchBytes(uri: string): Promise<{ bytes: Uint8Array; withheld: boolean }> {
  if (uri.startsWith("data:")) {
    const comma = uri.indexOf(",");
    if (comma < 0 || !uri.slice(0, comma).endsWith(";base64")) throw new Error("only base64 data URIs are supported");
    return { bytes: Uint8Array.from(Buffer.from(uri.slice(comma + 1), "base64")), withheld: false };
  }
  const url = new URL(uri);
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error(`${url.protocol} URIs are not supported`);
  const response = await get(url);
  if (response.status === 404) throw new Error(`${display(uri)} answered with status 404: the host no longer has this record, so trying again will not help`);
  if (!response.ok) throw new Error(`${display(uri)} answered with status ${response.status}`);
  return {
    bytes: new Uint8Array(await response.arrayBuffer()),
    withheld: response.headers.get("x-brainchain-withheld") === "result",
  };
}

class Checks {
  public readonly list: Check[] = [];

  public add(name: string, status: Status, message: string): void {
    this.list.push({ name, status, message });
  }

  public check(name: string, pass: boolean, ok: string, otherwise: string): void {
    this.add(name, pass ? "ok" : "fail", pass ? ok : otherwise);
  }
}

function readDecision({ client, set }: Context, id: bigint) {
  return client.readContract({ address: set.log, abi: decisionLogAbi, functionName: "get", args: [id] });
}

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
  const { bytes } = await fetchBytes(posted.args.briefURI);
  if (keccak256(bytes) !== posted.args.briefHash.toLowerCase()) throw new Error(`task ${task}'s brief does not match its briefHash`);
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
  report.payloadURI = e.payloadURI;
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

  let fetched: Awaited<ReturnType<typeof fetchBytes>>;
  try {
    fetched = await fetchBytes(e.payloadURI);
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
  c.add(
    "fetch",
    "ok",
    `fetched the record from ${display(e.payloadURI)}${fetched.withheld ? ", served without the work Jev did not accept" : ""}`,
  );

  if (fetched.withheld) {
    c.add("record-hash", "skip", "record hash: the work was not accepted, so the record is served without it and cannot match payloadHash");
    c.add("input-hash", "skip", "request hash: the request quotes the withheld work, so it cannot match inputHash");
  } else {
    const hash = keccak256(fetched.bytes);
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

  const outside = decision.kind === Kind.Grade && outsideGrade(record.subject, decision.subject);
  const task = !outside && decision.kind !== Kind.Change && /^\d+$/.test(record.subject) ? BigInt(record.subject) : undefined;
  if (task !== undefined) report.task = Number(task);
  if (outside) report.outside = true;
  if (decision.kind === Kind.Change) {
    c.check(
      "subject",
      record.subject.toLowerCase() === decision.subject,
      `subject: ${short(decision.subject)}, the exact call this change names`,
      "the record's subject differs from the one on chain",
    );
  } else if (outside) {
    c.add("subject", "ok", "subject: a grade of work delivered outside BrainChain, so no task on this board");
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
    checkOutsideGrade(c, record);
    c.add("threshold", "skip", "threshold: no task on this chain, so no board applied this grade; the caller received the verdict");
  }
  if (decision.kind === Kind.Change) await checkChange(ctx, c, id, decision, record, state);
  return report;
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
    c.add("brief", "skip", `brief: ${errorMessage(error)}`);
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

// No brief on chain to compare with: the levels and the pass level are in the record, which inputHash commits to.
function checkOutsideGrade(c: Checks, record: Published): void {
  const levels = record.request.questions.decision.criteria;
  if (!Array.isArray(levels) || record.passFrom === undefined) {
    c.add("confidence-recomputed", "skip", "grade confidence: the record does not name its pass level");
    return;
  }
  checkGradeConfidence(c, record, levels.map((_, i) => String(i)).slice(record.passFrom));
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

// Applies each threshold the way TaskBoard.hire, grade and rule do, to the
// terms fixed when the task was posted, then compares with what the board did.
async function checkTaskThreshold(ctx: Context, c: Checks, id: bigint, task: bigint, decision: Decision, record: Published): Promise<void> {
  const { client, set } = ctx;
  const terms = await client.readContract({ address: set.board, abi: taskBoardAbi, functionName: "get", args: [task] });
  const filter = { address: set.board, abi: taskBoardAbi, args: { id: task, decisionId: id }, fromBlock: BigInt(set.fromBlock), strict: true } as const;
  const bps = decision.confidenceBps;
  const rule = (threshold: number, name: string): string =>
    `threshold: ${named(record.answer)} at ${percent(bps)} is ${bps >= threshold ? "at or above" : "below"} the ${percent(threshold)} ${name} threshold fixed when task ${task} was posted`;

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
