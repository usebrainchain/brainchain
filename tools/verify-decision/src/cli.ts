#!/usr/bin/env node
import { createRequire } from "node:module";

import { createPublicClient, http, isAddress } from "viem";

import { decisionLogAbi, taskBoardAbi } from "./abi.js";
import { NETWORKS } from "./deployments.js";
import { clean, decisionsOf, errorMessage, outcomeOf, verifyDecision, withheldNotChecked, type Check, type Context, type DecisionReport, type Status } from "./verify.js";

const USAGE = `Usage:
  brainchain-verify <mainnet|testnet|chainId> <decisionId> [--set <TaskBoard>] [--rpc <url>] [--json]
  brainchain-verify <mainnet|testnet|chainId> --task <taskId> [--set <TaskBoard>] [--rpc <url>] [--json]

Checks a BrainChain decision against the chain: reads it from the DecisionLog,
fetches the published record, recomputes its hashes and confidence, and applies
the task's thresholds as the contracts do. Needs no keys.

  --task <id>    check every decision about one task
  --set <board>  a retired contract set from 3.0.0 on, by TaskBoard address, by
                 its key on the site (v3-1) or by release (3.1.0); without it, the
                 active set
  --rpc <url>    another RPC for the same chain; records and briefs on private
                 addresses are read only when this is on one too
  --json         one JSON object on stdout
  --version      print the version

Exit status: 0 when every check that could run matches, 1 on a mismatch or when
a decision or its record cannot be read, 2 on bad arguments.`;

const TRUST_MODEL = "https://docs.usebrainchain.com/trust-model";
// Sets before 3.0.0 named tasks by id alone, which the subject check does not model, so the package carries none.
const BEFORE_3 = /^(v2(-|$)|2\.|0x83b31d99fa31a9e5257955a737ef34c40f1c57bf$)/i;

function usage(message: string): never {
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
  return value;
};
const json = args.includes("--json");
if (json) args.splice(args.indexOf("--json"), 1);
const taskArg = flag("--task");
const setArg = flag("--set");
const rpcArg = flag("--rpc");
// -1 is a bad id, not an option; the id check below says so.
const unknown = args.find((arg) => arg.startsWith("-") && !/^-\d/.test(arg));
if (unknown) usage(`Unknown option ${unknown}`);
if (rpcArg !== undefined && !(URL.canParse(rpcArg) && ["http:", "https:"].includes(new URL(rpcArg).protocol))) usage("--rpc needs an http or https URL");

const [networkArg, idArg, ...extra] = args;
if (networkArg === undefined) usage("Name a network: mainnet, testnet or a chain id");
if (extra.length > 0 || (taskArg !== undefined && idArg !== undefined)) usage("Too many arguments");
const target = taskArg ?? idArg;
if (target === undefined) usage("Name a decision id, or a task with --task");
if (!/^[1-9]\d*$/.test(target)) usage(`${taskArg === undefined ? "A decision" : "A task"} id is a whole number from 1`);

const foundNetwork = Object.hasOwn(NETWORKS, networkArg)
  ? NETWORKS[networkArg as keyof typeof NETWORKS]
  : Object.values(NETWORKS).find((n) => String(n.chainId) === networkArg);
if (!foundNetwork) usage(`Unknown network "${networkArg}": use mainnet, testnet, 274663 or 274630`);
const network = foundNetwork;

const foundSet =
  setArg === undefined
    ? network.sets[0]
    : network.sets.find((s) => (isAddress(setArg) ? s.board.toLowerCase() === setArg.toLowerCase() : s.key === setArg || s.release === setArg || s.aliases?.includes(setArg)));
if (!foundSet) {
  if (setArg !== undefined && BEFORE_3.test(setArg)) usage(`Contract set ${setArg} predates release 3.0.0, which this tool does not read: those boards named tasks by id alone.`);
  const sets = network.sets.map((s, i) => `${s.key} (TaskBoard ${s.board}${i === 0 ? ", active" : ""})`);
  usage(`No contract set ${setArg} on ${network.name}. Sets: ${sets.join(", ")}`);
}
const set = foundSet;

const ctx: Context = {
  client: createPublicClient({ transport: http(rpcArg ?? network.rpc) }),
  network,
  set,
  briefs: new Map(),
};

function fail(message: string): never {
  if (json) console.log(JSON.stringify({ error: clean(message) }, null, 2));
  else console.error(clean(message));
  process.exit(1);
}

const TAGS = { ok: "ok", fail: "FAIL", skip: "skip", error: "ERROR" } as const;
const tally = (checks: Check[], status: Status): number => checks.filter((c) => c.status === status).length;

function verdict(reports: DecisionReport[]): string {
  const all = reports.flatMap((r) => r.checks);
  const failed = tally(all, "fail");
  const many = reports.length > 1;
  switch (outcomeOf(reports)) {
    case "mismatch":
      return `Verdict: MISMATCH. ${failed} check${failed === 1 ? "" : "s"} failed; see the FAIL lines.`;
    case "unverified":
      return "Verdict: UNVERIFIED. A record could not be fetched, so its checks did not run; see the ERROR lines.";
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
      ...(r.outside ? { outside: true } : {}),
      ...(r.withheld ? { withheld: true } : {}),
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
      notChecked: "That Jev produced the answer. BrainChain records Jev's answers, and the contracts bound what a recorded answer can do.",
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

try {
  const chainId = await ctx.client.getChainId();
  if (chainId !== network.chainId) usage(`The RPC serves chain ${chainId}, not ${network.name} (${network.chainId})`);
  const where = `on ${network.name}, contract set ${set.key}`;

  if (taskArg !== undefined) {
    const task = BigInt(taskArg);
    const tasks = await ctx.client.readContract({ address: set.board, abi: taskBoardAbi, functionName: "count" });
    if (task > tasks) fail(`TaskBoard ${set.board} (set ${set.key}) holds tasks 1 to ${tasks}`);
    const ids = await decisionsOf(ctx, task);
    if (ids.length === 0) fail(`Task ${task} has no decisions ${where}`);
    const reports: DecisionReport[] = [];
    for (const id of ids) reports.push(await verifyDecision(ctx, id));
    report(reports, `Task ${task} ${where} (TaskBoard ${set.board}): decision${ids.length === 1 ? "" : "s"} ${ids.join(", ")}`, Number(task));
  }

  const id = BigInt(target);
  const decisions = await ctx.client.readContract({ address: set.log, abi: decisionLogAbi, functionName: "count" });
  if (id > decisions) {
    const others = network.sets.filter((s) => s !== set).map((s) => s.key);
    const hint = others.length > 0 ? ` Each set numbers its own decisions; try --set ${others.join(" or ")}.` : "";
    fail(`DecisionLog ${set.log} (set ${set.key}) holds decisions 1 to ${decisions}.${hint}`);
  }
  report([await verifyDecision(ctx, id)], `Decision ${id} ${where} (DecisionLog ${set.log})`);
} catch (error) {
  fail(errorMessage(error));
}
