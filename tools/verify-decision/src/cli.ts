#!/usr/bin/env node
import { createRequire } from "node:module";

import { createPublicClient, isAddress } from "viem";

import { decisionLogAbi, taskBoardAbi } from "./abi.js";
import { NETWORKS } from "./deployments.js";
import {
  clean,
  decisionsOf,
  entriesOf,
  entryName,
  entryOutcome,
  entryReport,
  entrySummary,
  errorMessage,
  isReceipt,
  outcomeOf,
  readReceipt,
  receiptDecision,
  REPUTATION,
  rpcTransport,
  verifyDecision,
  verifyEntry,
  withheldNotChecked,
  type Check,
  type Context,
  type DecisionReport,
  type EntryOutcome,
  type EntryReport,
  type Registry,
  type Status,
} from "./verify.js";

const USAGE = `Usage:
  brainchain-verify <mainnet|testnet|chainId> <decisionId> [--set <TaskBoard>] [--rpc <url>] [--offline] [--json]
  brainchain-verify <mainnet|testnet|chainId> --task <taskId> [--set <TaskBoard>] [--rpc <url>] [--offline] [--json]
  brainchain-verify <mainnet|testnet|chainId> [<decisionId>] --receipt <file|url> [--set <TaskBoard>] [--rpc <url>] [--json]
  brainchain-verify mainnet --entry <agentId>:[<writer>:]<feedbackIndex> [--rpc <url>] [--registry-rpc <url>] [--json]
  brainchain-verify mainnet --agent <agentId> [--rpc <url>] [--registry-rpc <url>] [--json]

Checks a BrainChain decision against the chain: reads it from the DecisionLog,
fetches the published record, recomputes its hashes and confidence, and applies
the task's thresholds as the contracts do. Needs no keys.

  --task <id>    check every decision about one task
  --receipt <r>  check the receipt for a paid job, from a file or a URL, against
                 the decision it names, or the one given
  --entry <e>    check one ERC-8004 reputation entry BrainChain wrote: the entry,
                 its receipt, the decision and payment the receipt names, and the
                 task, value and worker on the board. The writer is needed only
                 for an entry from an address BrainChain no longer writes from
  --agent <id>   check every entry BrainChain wrote for one agent
  --offline      fetch no receipt from the brain host
  --set <board>  a retired contract set from 3.0.0 on, by TaskBoard address, by
                 its key on the site (v3-1) or by release (3.1.0); without it, the
                 active set
  --rpc <url>    another RPC for the same chain; records and briefs on private
                 addresses are read only when this is on one too
  --registry-rpc <url>
                 another RPC for Robinhood Chain, where the registries are
  --json         one JSON object on stdout
  --version      print the version

Exit status: 0 when every check that could run matches, 1 on a mismatch or when
a decision or its record cannot be read, 2 on bad arguments.`;

const TRUST_MODEL = "https://docs.usebrainchain.com/trust-model";
const NOT_CHECKED = "That Jev produced the answer. BrainChain records Jev's answers, and the contracts bound what a recorded answer can do.";
// Sets before 3.0.0 named tasks by id alone, which the subject check does not model, so the package carries none.
const BEFORE_3 = /^(v2(-|$)|2\.|0x83b31d99fa31a9e5257955a737ef34c40f1c57bf$)/i;

// Only a command line of the wrong shape gets the usage. A value that names nothing the tool can read gets a message that says what would.
function usage(message: string): never {
  if (json) fail(message, 2);
  console.error(`${message}\n\n${USAGE}`);
  process.exit(2);
}

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(USAGE);
  process.exit(0);
}
if (args.includes("--version") || args.includes("-v")) {
  console.log((createRequire(import.meta.url)("../package.json") as { version: string }).version);
  process.exit(0);
}
const flag = (name: string): string | undefined => {
  const at = args.indexOf(name);
  if (at < 0) return undefined;
  const value = args[at + 1];
  if (value === undefined || value.startsWith("--")) usage(`${name} needs a value`);
  args.splice(at, 2);
  if (args.includes(name)) usage(`${name} given twice`);
  return value;
};
// A switch given twice means the same as once.
const toggle = (name: string): boolean => {
  const given = args.length;
  for (let at = args.indexOf(name); at >= 0; at = args.indexOf(name)) args.splice(at, 1);
  return args.length < given;
};
const json = toggle("--json");
const offline = toggle("--offline");
const taskArg = flag("--task");
const setArg = flag("--set");
const rpcArg = flag("--rpc");
const receiptArg = flag("--receipt");
const entryArg = flag("--entry");
const agentArg = flag("--agent");
const registryRpcArg = flag("--registry-rpc");
// -1 is a bad id, not an option; the id check below says so.
const unknown = args.find((arg) => arg.startsWith("-") && !/^-\d/.test(arg));
if (unknown) usage(`Unknown option ${unknown}`);
const web = (url: string): boolean => URL.canParse(url) && ["http:", "https:"].includes(new URL(url).protocol);
if (rpcArg !== undefined && !web(rpcArg)) fail("--rpc needs an http or https URL", 2);
if (registryRpcArg !== undefined && !web(registryRpcArg)) fail("--registry-rpc needs an http or https URL", 2);

const [networkArg, idArg, ...extra] = args;
if (networkArg === undefined) usage("Name a network: mainnet, testnet or a chain id");
if (extra.length > 0 || (taskArg !== undefined && idArg !== undefined)) usage("Too many arguments");
if (taskArg !== undefined && receiptArg !== undefined) usage("A receipt is for one decision: name it, not a task");
const reputation = entryArg !== undefined || agentArg !== undefined;
if (reputation && (idArg !== undefined || taskArg !== undefined || receiptArg !== undefined || setArg !== undefined || offline)) {
  usage("An entry names its own task, decision and receipt, so --entry and --agent take only --rpc, --registry-rpc and --json");
}
if (!reputation && registryRpcArg !== undefined) usage("--registry-rpc is for --entry and --agent");
if (entryArg !== undefined && agentArg !== undefined) usage("Name one entry with --entry, or an agent with --agent");
if (!reputation && taskArg === undefined && idArg === undefined && receiptArg === undefined) usage("Name a decision id, a task with --task, or an entry with --entry");
const given = taskArg ?? idArg;
if (given !== undefined && !/^[1-9]\d*$/.test(given)) fail(`${taskArg === undefined ? "A decision" : "A task"} id is a whole number from 1`, 2);

const foundNetwork = Object.hasOwn(NETWORKS, networkArg)
  ? NETWORKS[networkArg as keyof typeof NETWORKS]
  : Object.values(NETWORKS).find((n) => String(n.chainId) === networkArg);
if (!foundNetwork) fail(`Unknown network "${networkArg}": use mainnet, testnet, 274663 or 274630`, 2);
const network = foundNetwork;
const client = createPublicClient({ transport: rpcTransport("BrainChain", rpcArg ?? network.rpc) });
const TAGS = { ok: "ok", fail: "FAIL", skip: "skip", error: "ERROR" } as const;
const tally = (checks: Check[], status: Status): number => checks.filter((c) => c.status === status).length;
// With --task or --agent, one decision or entry the RPC cannot read is an error line of its own, and the rest still run.
const unread = (what: string, error: unknown): Check => ({ name: "rpc", status: "error", message: `could not check ${what}: ${errorMessage(error)}` });
const ENTRY_TAGS: Record<EntryOutcome, string> = { match: "match", "no-receipt": "no receipt", withheld: "withheld", mismatch: "MISMATCH", unverified: "UNVERIFIED" };
if (reputation) await checkEntries();

const receipt = receiptArg === undefined ? undefined : await readReceipt(client, receiptArg).catch((error: unknown) => fail(errorMessage(error)));
if (receipt && !isReceipt(receipt.value)) fail(`${receipt.from} is not a receipt as BrainChain or the x402 extension signs one`);
const named = receipt && receiptDecision(receipt.value);
const target = given ?? named?.decision;
if (target === undefined || !/^[1-9]\d*$/.test(target)) fail("The receipt names no decision; give the decision's id", 2);
// A receipt names its log, so it opens a retired set on its own.
const receiptSet = named && network.sets.find((s) => s.log.toLowerCase() === named.decisionLog.toLowerCase());

const foundSet =
  setArg === undefined
    ? (receiptSet ?? network.sets[0])
    : network.sets.find((s) => (isAddress(setArg) ? s.board.toLowerCase() === setArg.toLowerCase() : s.key === setArg || s.release === setArg || s.aliases?.includes(setArg)));
if (!foundSet) {
  if (setArg !== undefined && BEFORE_3.test(setArg)) fail(`Contract set ${setArg} predates release 3.0.0, which this tool does not read: those boards named tasks by id alone.`, 2);
  const sets = network.sets.map((s, i) => `${s.key} (TaskBoard ${s.board}${i === 0 ? ", active" : ""})`);
  fail(`No contract set ${setArg} on ${network.name}. Sets: ${sets.join(", ")}`, 2);
}
const set = foundSet;

const ctx: Context = { client, network, set, briefs: new Map(), offline };

function fail(message: string, status = 1): never {
  if (json) console.log(JSON.stringify({ error: clean(message) }, null, 2));
  else console.error(clean(message));
  process.exit(status);
}

function verdict(reports: DecisionReport[]): string {
  const all = reports.flatMap((r) => r.checks);
  const failed = tally(all, "fail");
  const many = reports.length > 1;
  switch (outcomeOf(reports)) {
    case "mismatch":
      return `Verdict: MISMATCH. ${failed} check${failed === 1 ? "" : "s"} failed; see the FAIL lines.`;
    case "unverified":
      return "Verdict: UNVERIFIED. Some checks could not run; the ERROR lines say what could not be read.";
    case "withheld":
      return `Verdict: withheld, not a full match${many ? ` (decision${reports.filter((r) => r.withheld).length === 1 ? "" : "s"} ${reports.filter((r) => r.withheld).map((r) => r.id).join(", ")})` : ""}. ${withheldNotChecked(reports)}`;
    case "match":
      if (tally(all, "skip") > 0) return "Verdict: match. Every check that could run passed; the skip lines say what could not be checked.";
      return many
        ? "Verdict: match. The published records are exactly what the chain recorded, and the chain applied them as its contracts require."
        : "Verdict: match. The published record is exactly what the chain recorded, and the chain applied it as its contracts require.";
  }
}

function report(reports: DecisionReport[], header: string, task?: number): never {
  const all = reports.flatMap((r) => r.checks);
  const failed = tally(all, "fail");
  const errors = tally(all, "error");
  const skipped = tally(all, "skip");
  const overall = outcomeOf(reports);
  if (json) {
    const decisions = reports.map(({ checks, ...r }) => ({
      id: r.id,
      kind: r.kind,
      task: r.task,
      ...(r.title ? { title: r.title } : {}),
      ...(r.outside ? { outside: true } : {}),
      ...(r.withheld ? { withheld: true } : {}),
      ...(r.run ? { run: r.run } : {}),
      ...(r.panel ? { panel: r.panel } : {}),
      ...(r.evidence ? { evidence: r.evidence } : {}),
      ...(r.receipt ? { receipt: r.receipt } : {}),
      block: r.block,
      recordedAt: r.recordedAt,
      confidenceBps: r.confidenceBps,
      payloadURI: r.payloadURI,
      verdict: outcomeOf([{ ...r, checks }]),
      checks,
    }));
    const out = {
      network: network.name,
      chainId: network.chainId,
      set,
      ...(task === undefined ? {} : { task }),
      verdict: overall,
      failed,
      errors,
      skipped,
      decisions,
      ...(overall === "withheld" ? { withheldNotChecked: withheldNotChecked(reports) } : {}),
      notChecked: NOT_CHECKED,
      trustModel: TRUST_MODEL,
    };
    console.log(JSON.stringify(out, null, 2));
    process.exit(failed + errors > 0 ? 1 : 0);
  }
  console.log(header);
  for (const r of reports) {
    console.log(task === undefined ? "" : `\nDecision ${r.id}`);
    for (const c of r.checks) console.log(`  ${TAGS[c.status].padEnd(5)} ${c.message}`);
  }
  console.log(`\n${verdict(reports)}`);
  console.log(`Not checked: that Jev produced the answer. See ${TRUST_MODEL}`);
  process.exit(failed + errors > 0 ? 1 : 0);
}

async function sameChain(registry?: Registry): Promise<void> {
  const chainId = await client.getChainId();
  if (chainId !== network.chainId) fail(`The RPC serves chain ${chainId}, not ${network.name} (${network.chainId})`, 2);
  const registryChain = await registry?.client.getChainId();
  if (registry && registryChain !== registry.chainId) fail(`The registry RPC serves chain ${registryChain}, not Robinhood Chain (${registry.chainId})`, 2);
}

function entryVerdict(r: EntryReport): string {
  const failed = tally(r.checks, "fail");
  switch (entryOutcome([r])) {
    case "mismatch":
      return `Verdict: MISMATCH. ${failed} check${failed === 1 ? "" : "s"} failed; see the FAIL lines.`;
    case "unverified":
      return "Verdict: UNVERIFIED. Some checks could not run; the ERROR lines say what could not be read.";
    case "withheld":
      return `Verdict: withheld, not a full match. ${withheldNotChecked([r.decision!])}`;
    case "no-receipt":
      return "Verdict: no receipt. No signed receipt backs this entry, and the checks the chain allows without one passed.";
    case "match":
      if (tally(r.checks, "skip") > 0) return "Verdict: match. Every check that could run passed; the skip lines say what could not be checked.";
      return "Verdict: match. The entry, its receipt, the decision and payment the receipt names, and the task on the board agree with the chain.";
  }
}

/** What an entry is about, on its line in an agent's list. */
function about(r: EntryReport): string {
  const task = r.task === undefined ? `endpoint ${r.endpoint}` : `task ${r.task}${r.set ? ` in set ${r.set}` : r.board ? ` on board ${r.board}` : ""}`;
  return `value ${r.value}, ${task}${r.decision ? `, decision ${r.decision.id}` : ""}`;
}

function reportEntries(reports: EntryReport[], header: string, agentId?: string): never {
  const outcomes = reports.map((r) => entryOutcome([r]));
  const summary = entrySummary(reports);
  const all = reports.flatMap((r) => r.checks);
  const status = tally(all, "fail") + tally(all, "error") > 0 ? 1 : 0;
  if (json) {
    const entries = reports.map(({ checks, decision, ...r }, i) => ({
      ...r,
      ...(decision ? { decision: { id: decision.id, set: decision.set, kind: decision.kind, ...(decision.task === undefined ? {} : { task: decision.task }) } } : {}),
      verdict: outcomes[i],
      checks,
    }));
    const out = {
      network: network.name,
      chainId: network.chainId,
      registry: { chainId: REPUTATION.chainId, address: REPUTATION.address, writers: REPUTATION.writers },
      ...(agentId === undefined ? {} : { agentId }),
      verdict: entryOutcome(reports),
      summary,
      entries,
      notChecked: NOT_CHECKED,
      trustModel: TRUST_MODEL,
    };
    console.log(JSON.stringify(out, null, 2));
    process.exit(status);
  }
  console.log(`${header}\n`);
  const [one] = reports;
  if (agentId === undefined && one) {
    for (const c of one.checks) console.log(`  ${TAGS[c.status].padEnd(5)} ${c.message}`);
    console.log(`\n${entryVerdict(one)}`);
  } else {
    for (const [i, r] of reports.entries()) {
      console.log(`  ${ENTRY_TAGS[outcomes[i]!].padEnd(10)} ${r.entry}  ${about(r)}`);
      for (const c of r.checks) if (c.status === "fail" || c.status === "error") console.log(`             ${TAGS[c.status].padEnd(5)} ${c.message}`);
    }
    const { entries, withReceipt, verified, withheld, failed, unverified } = summary;
    console.log(`\n${entries} entr${entries === 1 ? "y" : "ies"}, ${withReceipt} with a receipt, ${verified} verified${withheld > 0 ? `, ${withheld} withheld` : ""}, ${failed} failed${unverified > 0 ? `, ${unverified} could not be checked` : ""}.`);
  }
  console.log(`Not checked: that Jev produced the answer. See ${TRUST_MODEL}`);
  process.exit(status);
}

/** --entry and --agent: BrainChain's entries in the ERC-8004 reputation registry, each checked through its receipt to the chain. */
async function checkEntries(): Promise<never> {
  if (network.chainId !== REPUTATION.network) fail("BrainChain writes reputation entries for mainnet tasks only, so --entry and --agent read mainnet", 2);
  const registry: Registry = { ...REPUTATION, client: createPublicClient({ transport: rpcTransport("Robinhood Chain", registryRpcArg ?? REPUTATION.rpc) }) };
  const [current, ...earlier] = registry.writers;
  const where = `in the ERC-8004 reputation registry on Robinhood Chain (${registry.address})`;
  const ctx: Context = { client, network, set: network.sets[0]!, briefs: new Map() };
  if (entryArg !== undefined) {
    const parts = /^(0|[1-9]\d{0,77}):(?:(0x[0-9a-fA-F]{40}):)?([1-9]\d{0,19})$/.exec(entryArg);
    if (!parts) fail("An entry is <agentId>:<feedbackIndex>, or <agentId>:<writer>:<feedbackIndex> for one BrainChain wrote from an earlier address", 2);
    const named = parts[2];
    const writer = named === undefined ? current : registry.writers.find((w) => w.toLowerCase() === named.toLowerCase());
    if (!writer) fail(`BrainChain writes its entries from ${registry.writers.join(" and ")}, not ${named}`, 2);
    const agentId = BigInt(parts[1]!);
    const index = BigInt(parts[3]!);
    try {
      await sameChain(registry);
      const found = await entriesOf(registry, agentId, [writer]);
      const entry = found.find((f) => f.feedbackIndex === index);
      if (!entry) {
        const held = found.length === 0 ? `has written no entry for agent ${agentId}` : `wrote entries 1 to ${found.at(-1)!.feedbackIndex} for agent ${agentId}`;
        const hint = named === undefined && earlier.length > 0 ? `. It wrote earlier ones from ${earlier.join(" and ")}: name one as ${agentId}:<writer>:<feedbackIndex>` : "";
        fail(`BrainChain ${held} from ${writer}${hint}`);
      }
      reportEntries([await verifyEntry(ctx, registry, entry)], `Entry ${entryName(registry, entry)} ${where}`);
    } catch (error) {
      fail(errorMessage(error));
    }
  }
  if (!/^(0|[1-9]\d{0,77})$/.test(agentArg!)) fail("An agent id is a whole number", 2);
  const agentId = BigInt(agentArg!);
  try {
    await sameChain(registry);
    const found = await entriesOf(registry, agentId);
    if (found.length === 0) fail(`BrainChain has written no entry for agent ${agentId} ${where}`);
    const reports: EntryReport[] = [];
    for (const f of found) reports.push(await verifyEntry(ctx, registry, f).catch((error: unknown) => entryReport(registry, f, [unread(`entry ${entryName(registry, f)}`, error)])));
    reportEntries(reports, `Agent ${agentId} ${where}: ${found.length} entr${found.length === 1 ? "y" : "ies"} BrainChain wrote`, agentId.toString());
  } catch (error) {
    fail(errorMessage(error));
  }
}

/** The other sets whose boards hold a task with this id, for a task this set's board does not hold or decided nothing on. */
async function otherBoards(task: bigint): Promise<string> {
  const others = network.sets.filter((s) => s !== set);
  // Only a hint, so a board the RPC cannot read is left out of it.
  const counts = await Promise.allSettled(others.map((s) => client.readContract({ address: s.board, abi: taskBoardAbi, functionName: "count" })));
  const holding = others.filter((_, i) => {
    const count = counts[i]!;
    return count.status === "fulfilled" && count.value >= task;
  });
  return holding.length > 0 ? ` Each set numbers its own tasks; try --set ${holding.map((s) => s.key).join(" or ")}.` : "";
}

try {
  await sameChain();
  const where = `on ${network.name}, contract set ${set.key}`;

  if (taskArg !== undefined) {
    const task = BigInt(taskArg);
    const tasks = await ctx.client.readContract({ address: set.board, abi: taskBoardAbi, functionName: "count" });
    if (task > tasks) fail(`TaskBoard ${set.board} (set ${set.key}) holds tasks 1 to ${tasks}.${await otherBoards(task)}`);
    const ids = await decisionsOf(ctx, task);
    if (ids.length === 0) fail(`Task ${task} has no decisions ${where}.${await otherBoards(task)}`);
    const reports: DecisionReport[] = [];
    for (const id of ids) reports.push(await verifyDecision(ctx, id).catch((error: unknown) => ({ id: Number(id), checks: [unread(`decision ${id}`, error)] })));
    const title = reports.find((r) => r.title)?.title;
    report(reports, `Task ${task} ${where} (TaskBoard ${set.board}): decision${ids.length === 1 ? "" : "s"} ${ids.join(", ")}${title ? `\nBrief: ${title}` : ""}`, Number(task));
  }

  const id = BigInt(target);
  const decisions = await ctx.client.readContract({ address: set.log, abi: decisionLogAbi, functionName: "count" });
  if (id > decisions) {
    const others = network.sets.filter((s) => s !== set).map((s) => s.key);
    const hint = others.length > 0 ? ` Each set numbers its own decisions; try --set ${others.join(" or ")}.` : "";
    fail(`DecisionLog ${set.log} (set ${set.key}) holds decisions 1 to ${decisions}.${hint}`);
  }
  const checked = await verifyDecision(ctx, id, receipt);
  // What the task is about, so a decision read from the wrong set does not pass for the one meant.
  report([checked], `Decision ${id} ${where} (DecisionLog ${set.log})${checked.title ? `\nTask ${checked.task}: ${checked.title}` : ""}`);
} catch (error) {
  fail(errorMessage(error));
}
