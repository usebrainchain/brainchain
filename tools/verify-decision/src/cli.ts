#!/usr/bin/env node
import { createPublicClient, http, isAddress } from "viem";

import { decisionLogAbi, taskBoardAbi } from "./abi.js";
import { NETWORKS } from "./deployments.js";
import { decisionsOf, errorMessage, verifyDecision, type Check, type Context, type DecisionReport, type Status } from "./verify.js";

const USAGE = `Usage:
  brainchain-verify <mainnet|testnet|chainId> <decisionId> [--set <TaskBoard>] [--rpc <url>] [--json]
  brainchain-verify <mainnet|testnet|chainId> --task <taskId> [--set <TaskBoard>] [--rpc <url>] [--json]

Checks a BrainChain decision against the chain: reads it from the DecisionLog,
fetches the published record, recomputes its hashes and confidence, and applies
the task's thresholds as the contracts do. Needs no keys.

  --task <id>    check every decision about one task
  --set <board>  a retired contract set, by TaskBoard address or by its key on
                 the site (v3-1); without it, the active set
  --rpc <url>    another RPC for the same chain
  --json         one JSON object on stdout

Exit status: 0 when every check that could run matches, 1 on a mismatch or when
a decision or its record cannot be read, 2 on bad arguments.`;

const TRUST_MODEL = "https://docs.usebrainchain.com/trust-model";

function usage(message: string): never {
  console.error(`${message}\n\n${USAGE}`);
  process.exit(2);
}

const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(USAGE);
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
const unknown = args.find((arg) => arg.startsWith("-"));
if (unknown) usage(`Unknown option ${unknown}`);

const [networkArg, idArg, ...extra] = args;
if (networkArg === undefined) usage("Name a network: mainnet, testnet or a chain id");
if (extra.length > 0 || (taskArg !== undefined && idArg !== undefined)) usage("Too many arguments");
const target = taskArg ?? idArg;
if (target === undefined) usage("Name a decision id, or a task with --task");
if (!/^[1-9]\d*$/.test(target)) usage(`${taskArg === undefined ? "A decision" : "A task"} id is a whole number from 1`);

const foundNetwork =
  NETWORKS[networkArg as keyof typeof NETWORKS] ?? Object.values(NETWORKS).find((n) => String(n.chainId) === networkArg);
if (!foundNetwork) usage(`Unknown network "${networkArg}": use mainnet, testnet, 274663 or 274630`);
const network = foundNetwork;

const foundSet =
  setArg === undefined
    ? network.sets[0]
    : network.sets.find((s) => (isAddress(setArg) ? s.board.toLowerCase() === setArg.toLowerCase() : s.key === setArg));
if (!foundSet) {
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
  if (json) console.log(JSON.stringify({ error: message }, null, 2));
  else console.error(message);
  process.exit(1);
}

const TAGS = { ok: "ok", fail: "FAIL", skip: "skip", error: "ERROR" } as const;
const tally = (checks: Check[], status: Status): number => checks.filter((c) => c.status === status).length;
const outcome = (checks: Check[]): "mismatch" | "unverified" | "match" =>
  tally(checks, "fail") > 0 ? "mismatch" : tally(checks, "error") > 0 ? "unverified" : "match";

function verdict(failed: number, errors: number, skipped: number, many: boolean): string {
  if (failed > 0) return `Verdict: MISMATCH. ${failed} check${failed === 1 ? "" : "s"} failed; see the FAIL lines.`;
  if (errors > 0) return "Verdict: UNVERIFIED. A record could not be fetched, so its checks did not run; see the ERROR lines and try again.";
  if (skipped > 0) return "Verdict: match. Every check that could run passed; the skip lines say what could not be checked.";
  return many
    ? "Verdict: match. The published records are exactly what the chain recorded, and the chain applied them as its contracts require."
    : "Verdict: match. The published record is exactly what the chain recorded, and the chain applied it as its contracts require.";
}

function report(reports: DecisionReport[], header: string, task?: number): never {
  const all = reports.flatMap((r) => r.checks);
  const failed = tally(all, "fail");
  const errors = tally(all, "error");
  const skipped = tally(all, "skip");
  if (json) {
    const decisions = reports.map(({ checks, ...r }) => ({
      id: r.id,
      kind: r.kind,
      task: r.task,
      block: r.block,
      recordedAt: r.recordedAt,
      confidenceBps: r.confidenceBps,
      payloadURI: r.payloadURI,
      verdict: outcome(checks),
      checks,
    }));
    const out = {
      network: network.name,
      chainId: network.chainId,
      set,
      ...(task === undefined ? {} : { task }),
      verdict: outcome(all),
      failed,
      errors,
      skipped,
      decisions,
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
  console.log(`\n${verdict(failed, errors, skipped, reports.length > 1)}`);
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
