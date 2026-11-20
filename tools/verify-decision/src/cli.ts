#!/usr/bin/env node
import { createRequire } from "node:module";

import { createPublicClient, isAddress, type Hex, type PublicClient } from "viem";

import { decisionLogAbi, taskBoardAbi } from "./abi.js";
import { NETWORKS, type ContractSet } from "./deployments.js";
import {
  balancesFrom,
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
  PAYMENT_RPCS,
  readReceipt,
  receiptDecision,
  REPUTATION,
  rpcTransport,
  SERVICES,
  verifyDecision,
  verifyEntry,
  verifyItem,
  verifyLicences,
  verifyPapers,
  verifyRecord,
  withheldNotChecked,
  type Check,
  type Context,
  type DecisionReport,
  type EntryOutcome,
  type EntryReport,
  type EpochCount,
  type Registry,
  type Service,
  type Status,
} from "./verify.js";

const USAGE = `Usage:
  brainchain-verify <mainnet|testnet|chainId> <decisionId> [--set <TaskBoard>] [--rpc <url>] [--payment-rpc <url>] [--offline] [--json]
  brainchain-verify <mainnet|testnet|chainId> --task <taskId> [--set <TaskBoard>] [--rpc <url>] [--payment-rpc <url>] [--offline] [--json]
  brainchain-verify <mainnet|testnet|chainId> [<decisionId>] --receipt <file|url> [--set <TaskBoard>] [--rpc <url>] [--payment-rpc <url>] [--json]
  brainchain-verify mainnet --entry <agentId>:[<writer>:]<feedbackIndex> [--rpc <url>] [--registry-rpc <url>] [--payment-rpc <url>] [--json]
  brainchain-verify mainnet --agent <agentId> [--rpc <url>] [--registry-rpc <url>] [--payment-rpc <url>] [--json]
  brainchain-verify <mainnet|testnet|chainId> --record <agentId> [--epoch] [--service <url>] [--rpc <url>] [--registry-rpc <url>] [--payment-rpc <url>] [--json]
  brainchain-verify <mainnet|testnet|chainId> --licence <agentId> [--service <url>] [--rpc <url>] [--registry-rpc <url>] [--json]
  brainchain-verify <mainnet|testnet|chainId> --papers <agentId> [--service <url>] [--rpc <url>] [--registry-rpc <url>] [--json]
  brainchain-verify <mainnet|testnet|chainId> --item <itemId> [--service <url>] [--rpc <url>] [--json]

Checks a BrainChain decision against the chain: reads it from the DecisionLog,
fetches the published record, recomputes its hashes and confidence, and applies
the task's thresholds as the contracts do. Checks what the brain host signs
about an agent the same way: its record, licences and papers. Needs no keys.

  --task <id>    check every decision about one task
  --receipt <r>  check the receipt for a paid job, from a file or a URL, against
                 the decision it names, or the one given
  --entry <e>    check one ERC-8004 reputation entry BrainChain wrote: the entry,
                 its receipt, the decision and payment the receipt names, and the
                 task, value and worker on the board. The writer is needed only
                 for an entry from an address BrainChain no longer writes from
  --agent <id>   check every entry BrainChain wrote for one agent
  --record <id>  check an agent's numbered record on the brain host: every entry
                 from the first, chained by hash to a fresh signed head, each
                 signed by a key the DecisionLog named its brain, and each
                 receipt an entry names
  --epoch        with --record: read the identity registry for the epoch the
                 agent's id is in now, and say which entries belong to it
  --licence <id> check an agent's licences: each one's signature and key, its
                 expiry, and the state the host gives against the registry
  --papers <id>  check an agent's papers: the signed text, its key, its age, the
                 epoch they state against the registry and the record head they
                 name
  --item <id>    check a retired exam item against the commitment it was known
                 by while it was in use
  --service <url>
                 another brain host for --record, --licence, --papers and --item
  --offline      fetch no receipt from the brain host
  --set <board>  a retired contract set from 3.0.0 on, by TaskBoard address, by
                 its key on the site (v3-1) or by release (3.1.0); without it, the
                 active set, or for a decision id the active set does not hold
                 yet, the newest set that holds it
  --rpc <url>    another RPC for the same chain; records and briefs on private
                 addresses are read only when this is on one too
  --registry-rpc <url>
                 another RPC for Robinhood Chain, where the registries are; with
                 --record it is read only with --epoch
  --payment-rpc <url>
                 another RPC for Robinhood Chain, or its testnet on testnet, where
                 a receipt's payment is read; without it, the public RPC
  --json         one JSON object on stdout
  --version      print the version

Exit status: 0 when every check that could run matches, 1 on a mismatch, on
stale papers or licences or when a decision or its record cannot be read, 2 on
bad arguments.`;

const TRUST_MODEL = "https://docs.usebrainchain.com/trust-model";
const NOT_CHECKED = "That Jev produced the answer. BrainChain records Jev's answers, and the contracts bound what a recorded answer can do.";
// Sets before 3.0.0 named tasks by id alone, which the subject check does not model, so the package carries none.
const BEFORE_3 = /^(v2(-|$)|2\.|0x83b31d99fa31a9e5257955a737ef34c40f1c57bf$)/i;
// The brain host answers 400 for any other spelling of an id, so the tool refuses it with the same rule.
const AGENT_ID = "An agent id is a whole number written without leading zeros";

/** Thrown once the run is over, so that nothing after the call that ended it runs while its output drains. */
class Ended {}

/** Ends the run once stdout and stderr have taken what was written: process.exit alone drops what a pipe has not read yet. */
function exit(status: number): never {
  let open = 2;
  for (const stream of [process.stdout, process.stderr]) {
    // A reader that has gone away, as `| head` leaves one, is no reason to hold the exit back.
    stream.on("error", () => {});
    stream.write("", () => {
      if (--open === 0) process.exit(status);
    });
  }
  throw new Ended();
}

async function main(): Promise<void> {
  // Only a command line of the wrong shape gets the usage. A value that names nothing the tool can read gets a message that says what would.
  function usage(message: string): never {
    if (json) fail(message, 2);
    console.error(`${message}\n\n${USAGE}`);
    exit(2);
  }

  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) {
    console.log(USAGE);
    exit(0);
  }
  if (args.includes("--version") || args.includes("-v")) {
    console.log((createRequire(import.meta.url)("../package.json") as { version: string }).version);
    exit(0);
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
  const paymentRpcArg = flag("--payment-rpc");
  const recordArg = flag("--record");
  const licenceArg = flag("--licence");
  const papersArg = flag("--papers");
  const itemArg = flag("--item");
  const serviceArg = flag("--service");
  const epoch = toggle("--epoch");
  // -1 is a bad id, not an option; the id check below says so.
  const unknown = args.find((arg) => arg.startsWith("-") && !/^-\d/.test(arg));
  if (unknown) usage(`Unknown option ${unknown}`);
  const web = (url: string): boolean => URL.canParse(url) && ["http:", "https:"].includes(new URL(url).protocol);
  if (rpcArg !== undefined && !web(rpcArg)) fail("--rpc needs an http or https URL", 2);
  if (registryRpcArg !== undefined && !web(registryRpcArg)) fail("--registry-rpc needs an http or https URL", 2);
  if (paymentRpcArg !== undefined && !web(paymentRpcArg)) fail("--payment-rpc needs an http or https URL", 2);
  if (serviceArg !== undefined && !web(serviceArg)) fail("--service needs an http or https URL", 2);

  const [networkArg, idArg, ...extra] = args;
  if (networkArg === undefined) usage("Name a network: mainnet, testnet or a chain id");
  if (extra.length > 0 || (taskArg !== undefined && idArg !== undefined)) usage("Too many arguments");
  if (taskArg !== undefined && receiptArg !== undefined) usage("A receipt is for one decision: name it, not a task");
  const reputation = entryArg !== undefined || agentArg !== undefined;
  if (reputation && (idArg !== undefined || taskArg !== undefined || receiptArg !== undefined || setArg !== undefined || offline)) {
    usage("An entry names its own task, decision and receipt, so --entry and --agent take only --rpc, --registry-rpc, --payment-rpc and --json");
  }
  const hostedArgs = [recordArg, licenceArg, papersArg, itemArg].filter((arg) => arg !== undefined);
  const hosted = hostedArgs.length > 0;
  if (hostedArgs.length > 1) usage("Name one of --record, --licence, --papers and --item");
  if (hosted && (reputation || idArg !== undefined || taskArg !== undefined || receiptArg !== undefined || setArg !== undefined || offline)) {
    usage("--record, --licence, --papers and --item read the brain host, so they take only --service, --rpc, --registry-rpc, --payment-rpc and --json");
  }
  if (paymentRpcArg !== undefined && (licenceArg ?? papersArg ?? itemArg) !== undefined) usage("--payment-rpc is for decisions, --receipt, --entry, --agent and --record, which check a receipt's payment");
  if (paymentRpcArg !== undefined && offline && receiptArg === undefined) usage("With --offline, --payment-rpc is read only with --receipt");
  if (!hosted && serviceArg !== undefined) usage("--service is for --record, --licence, --papers and --item");
  if (epoch && recordArg === undefined) usage("--epoch is for --record");
  // The registry says which epoch an id is in now: a licence's state and the papers turn on it, and a record reads it only when asked.
  const readsRegistry = licenceArg !== undefined || papersArg !== undefined || (recordArg !== undefined && epoch);
  // The usage lists --registry-rpc for --record, so leaving out --epoch is not a command line of the wrong shape.
  if (registryRpcArg !== undefined && recordArg !== undefined && !epoch) fail("With --record, --registry-rpc is read only with --epoch", 2);
  if (registryRpcArg !== undefined && !reputation && !readsRegistry) usage("--registry-rpc is for --entry, --agent, --licence, --papers and --record with --epoch");
  if (entryArg !== undefined && agentArg !== undefined) usage("Name one entry with --entry, or an agent with --agent");
  if (!reputation && !hosted && taskArg === undefined && idArg === undefined && receiptArg === undefined) usage("Name a decision id, a task with --task, or an entry with --entry");
  const given = taskArg ?? idArg;
  if (given !== undefined && !/^[1-9]\d*$/.test(given)) fail(`${taskArg === undefined ? "A decision" : "A task"} id is a whole number from 1, written without leading zeros`, 2);

  const foundNetwork = Object.hasOwn(NETWORKS, networkArg)
    ? NETWORKS[networkArg as keyof typeof NETWORKS]
    : Object.values(NETWORKS).find((n) => String(n.chainId) === networkArg);
  if (!foundNetwork) fail(`Unknown network "${networkArg}": use mainnet, testnet, 274663 or 274630`, 2);
  const network = foundNetwork;
  const client = createPublicClient({ transport: rpcTransport("BrainChain", rpcArg ?? network.rpc) });
  // BrainChain settles on the chain its registries are on, so a receipt's own network is that one: Robinhood Chain, or its testnet.
  const { name: paymentChain, chainId: paymentChainId } = SERVICES[network.chainId]!.identity;
  const payment = paymentRpcArg === undefined ? undefined : { client: createPublicClient({ transport: rpcTransport(paymentChain, paymentRpcArg) }), chainId: paymentChainId };
  const balances = paymentRpcArg === undefined ? undefined : balancesFrom({ ...PAYMENT_RPCS, [`eip155:${paymentChainId}`]: paymentRpcArg });
  const TAGS = { ok: "ok", fail: "FAIL", skip: "skip", error: "ERROR" } as const;
  const tally = (checks: Check[], status: Status): number => checks.filter((c) => c.status === status).length;
  // With --task or --agent, one decision or entry the RPC cannot read is an error line of its own, and the rest still run.
  const unread = (what: string, error: unknown): Check => ({ name: "rpc", status: "error", message: `could not check ${what}: ${errorMessage(error)}` });
  const ENTRY_TAGS: Record<EntryOutcome, string> = { match: "match", "no-receipt": "no receipt", withheld: "withheld", mismatch: "MISMATCH", unverified: "UNVERIFIED" };
  const line = (c: Check): string => `  ${TAGS[c.status].padEnd(5)} ${c.message}`;
  const short = (value: string): string => `${value.slice(0, 6)}…${value.slice(-4)}`;
  const utc = (seconds: number): string => `${new Date(seconds * 1000).toISOString().replace("T", " ").slice(0, 19)} UTC`;
  if (reputation) await checkEntries();
  if (hosted) await checkHosted();

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

  const ctx: Context = { client, network, set, briefs: new Map(), offline, balances };

  function fail(message: string, status = 1): never {
    if (json) console.log(JSON.stringify({ error: clean(message) }, null, 2));
    else console.error(clean(message));
    exit(status);
  }

  /** For a catch around steps that can end the run themselves: a run that has ended stays ended, and any other error is its last word. */
  function failWith(error: unknown): never {
    if (error instanceof Ended) throw error;
    fail(errorMessage(error));
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

  function report(reports: DecisionReport[], header: string, on: ContractSet, task?: number): never {
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
        set: on,
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
      exit(failed + errors > 0 ? 1 : 0);
    }
    console.log(header);
    for (const r of reports) {
      console.log(task === undefined ? "" : `\nDecision ${r.id}`);
      for (const c of r.checks) console.log(`  ${TAGS[c.status].padEnd(5)} ${c.message}`);
    }
    console.log(`\n${verdict(reports)}`);
    console.log(`Not checked: that Jev produced the answer. See ${TRUST_MODEL}`);
    exit(failed + errors > 0 ? 1 : 0);
  }

  async function sameChain(registry?: { client: PublicClient; chainId: number }, name = "Robinhood Chain"): Promise<void> {
    const chainId = await client.getChainId();
    if (chainId !== network.chainId) fail(`The RPC serves chain ${chainId}, not ${network.name} (${network.chainId})`, 2);
    const registryChain = await registry?.client.getChainId();
    if (registry && registryChain !== registry.chainId) fail(`The registry RPC serves chain ${registryChain}, not ${name} (${registry.chainId})`, 2);
    const paying = await payment?.client.getChainId();
    if (payment && paying !== payment.chainId) fail(`The payment RPC serves chain ${paying}, not ${paymentChain} (${payment.chainId})`, 2);
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
        if (!r.record) return "Verdict: match. The entry, its receipt, the decision and payment the receipt names, and the task on the board agree with the chain.";
        return r.record.receipt
          ? "Verdict: match. The entry, the record entry it points at, that entry's receipt, the decision and payment the receipt names, and the task on the board agree with the chain."
          : "Verdict: match. The entry agrees with the record entry it points at, which the brain key signed. That entry names no receipt, so no decision or payment was checked.";
    }
  }

  /** What an entry is about, on its line in an agent's list. */
  function about(r: EntryReport): string {
    const task = r.task === undefined ? `endpoint ${r.endpoint}` : `task ${r.task}${r.set ? ` in set ${r.set}` : r.board ? ` on board ${r.board}` : ""}`;
    return `value ${r.value}, ${task}${r.record ? `, record entry ${r.record.seq}` : ""}${r.decision ? `, decision ${r.decision.id}` : ""}`;
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
      exit(status);
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
    exit(status);
  }

  /** --entry and --agent: BrainChain's entries in the ERC-8004 reputation registry, each checked through its receipt to the chain. */
  async function checkEntries(): Promise<never> {
    if (network.chainId !== REPUTATION.network) fail("BrainChain writes reputation entries for mainnet tasks only, so --entry and --agent read mainnet", 2);
    const registry: Registry = { ...REPUTATION, client: createPublicClient({ transport: rpcTransport("Robinhood Chain", registryRpcArg ?? REPUTATION.rpc) }) };
    const [current, ...earlier] = registry.writers;
    const where = `in the ERC-8004 reputation registry on Robinhood Chain (${registry.address})`;
    const ctx: Context = { client, network, set: network.sets[0]!, briefs: new Map(), balances };
    if (entryArg !== undefined) {
      const parts = /^(0|[1-9]\d{0,77}):(?:(0x[0-9a-fA-F]{40}):)?([1-9]\d{0,19})$/.exec(entryArg);
      if (!parts) fail("An entry is <agentId>:<feedbackIndex>, or <agentId>:<writer>:<feedbackIndex> for one BrainChain wrote from an earlier address, with each number written without leading zeros", 2);
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
        failWith(error);
      }
    }
    if (!/^(0|[1-9]\d{0,77})$/.test(agentArg!)) fail(AGENT_ID, 2);
    const agentId = BigInt(agentArg!);
    try {
      await sameChain(registry);
      const found = await entriesOf(registry, agentId);
      if (found.length === 0) fail(`BrainChain has written no entry for agent ${agentId} ${where}`);
      const reports: EntryReport[] = [];
      for (const f of found) reports.push(await verifyEntry(ctx, registry, f).catch((error: unknown) => entryReport(registry, f, [unread(`entry ${entryName(registry, f)}`, error)])));
      reportEntries(reports, `Agent ${agentId} ${where}: ${found.length} entr${found.length === 1 ? "y" : "ies"} BrainChain wrote`, agentId.toString());
    } catch (error) {
      failWith(error);
    }
  }

  interface Hosted {
    header: string;
    /** Every check, for the tally and the verdict. */
    checks: Check[];
    /** Decisions whose records were served without the work. */
    withheld?: DecisionReport[];
    /** The report, as the JSON object carries it. */
    fields: Record<string, unknown>;
    /** The text between the header and the verdict. */
    lines: string[];
    /** What a match shows, and what no check here can. */
    match: string;
    notChecked: string;
    /** Papers or licence states the registry no longer bears out: what the verdict says, in place of a mismatch. */
    stale?: string;
  }

  function reportHosted({ header, checks, withheld = [], fields, lines, match, notChecked, stale }: Hosted): never {
    const failed = tally(checks, "fail");
    const errors = tally(checks, "error");
    const skipped = tally(checks, "skip");
    const overall = stale ? "stale" : outcomeOf([{ checks, withheld: withheld.length > 0 }]);
    const status = failed + errors > 0 ? 1 : 0;
    if (json) {
      const out = {
        network: network.name,
        chainId: network.chainId,
        verdict: overall,
        failed,
        errors,
        skipped,
        ...fields,
        ...(overall === "withheld" ? { withheldNotChecked: withheldNotChecked(withheld) } : {}),
        notChecked: `${notChecked[0]!.toUpperCase()}${notChecked.slice(1)}`,
        trustModel: TRUST_MODEL,
      };
      console.log(JSON.stringify(out, null, 2));
      exit(status);
    }
    console.log(`${header}\n`);
    for (const text of lines) console.log(text);
    const verdict =
      overall === "stale"
        ? `STALE. ${stale}`
        : overall === "mismatch"
          ? `MISMATCH. ${failed} check${failed === 1 ? "" : "s"} failed; see the FAIL lines.`
          : overall === "unverified"
            ? "UNVERIFIED. Some checks could not run; the ERROR lines say what could not be read."
            : overall === "withheld"
              ? `withheld, not a full match. ${withheldNotChecked(withheld)}`
              : skipped > 0
                ? "match. Every check that could run passed; the skip lines say what could not be checked."
                : `match. ${match}`;
    console.log(`\nVerdict: ${verdict}`);
    console.log(`Not checked: ${notChecked} See ${TRUST_MODEL}`);
    exit(status);
  }

  function epochLine(e: EpochCount): string {
    const kinds = ["task", "exam", "audit"].flatMap((kind) => {
      const outcomes = ["accepted", "rejected", "undelivered"].flatMap((outcome) => {
        const n = e.counts[`${kind}:${outcome}` as keyof EpochCount["counts"]];
        return n ? [`${n} ${outcome}`] : [];
      });
      return outcomes.length > 0 ? [`${kind} ${outcomes.join(", ")}`] : [];
    });
    return `  epoch ${short(e.id)}, controller ${short(e.controller)}, ${e.build === "" ? "no build" : `build "${e.build}"`}, since entry ${e.from} (${utc(e.since)}): ${kinds.join("; ")}`;
  }

  /** --record, --licence, --papers and --item: what the brain host signs about an agent, held to the DecisionLog's brain keys and the identity registry. */
  async function checkHosted(): Promise<never> {
    const known = SERVICES[network.chainId]!;
    const url = (serviceArg ?? known.url).replace(/\/+$/, "");
    const ctx: Context = { client, network, set: network.sets[0]!, briefs: new Map(), balances };
    if (itemArg !== undefined) {
      if (!/^0x[0-9a-fA-F]{64}$/.test(itemArg)) fail("An item id is 0x and 64 hex digits", 2);
      const r = await verifyItem(ctx, { url }, itemArg as Hex).catch((error: unknown) => fail(errorMessage(error)));
      const { checks, ...fields } = r;
      reportHosted({
        header: `Exam item ${r.id} on ${network.name}, read from ${r.url}${r.title ? `\n${r.title}${r.template ? ` (template ${r.template})` : ""}` : ""}`,
        checks,
        fields: { service: url, ...fields, checks },
        lines: checks.map(line),
        match: "The published item is the one its id committed to.",
        notChecked: "that the commitment was published before the item was used, or which sittings drew it.",
      });
    }

    const asked = (recordArg ?? licenceArg ?? papersArg)!;
    if (!/^(0|[1-9]\d{0,77})$/.test(asked)) fail(AGENT_ID, 2);
    const agentId = BigInt(asked);
    const { name, rpc, ...identity } = known.identity;
    const registry = readsRegistry ? { client: createPublicClient({ transport: rpcTransport(name, registryRpcArg ?? rpc) }), chainId: identity.chainId } : undefined;
    const service: Service = { url, identity: { ...identity, ...(registry ? { client: registry.client } : {}) } };
    const on = `on ${network.name}, read from`;
    try {
      await sameChain(registry, name);
      if (recordArg !== undefined) {
        const r = await verifyRecord(ctx, service, agentId, { epoch });
        const { checks, receipts, ...fields } = r;
        const lines = checks.map(line);
        for (const receipt of receipts) {
          const wrong = receipt.checks.filter((c) => c.status === "fail" || c.status === "error");
          if (wrong.length === 0) continue;
          lines.push("", `Entry ${receipt.seq}'s receipt, ${receipt.path}${receipt.decision ? `, with decision ${receipt.decision.id} in set ${receipt.decision.set}` : ""}`, ...wrong.map(line));
        }
        if (r.epochs.length > 0) lines.push("", "Epochs in the record", ...r.epochs.map((e) => `${epochLine(e)}${r.current?.id === e.id.toLowerCase() ? ". The agent's id is in this epoch now" : ""}`));
        reportHosted({
          header: `Agent ${agentId}'s record ${on} ${r.url}`,
          checks,
          withheld: receipts.flatMap((receipt) => (receipt.withheld && receipt.decision ? [receipt.decision] : [])),
          fields: {
            service: url,
            ...fields,
            receipts: receipts.map(({ decision, checks: own, ...receipt }) => ({
              ...receipt,
              ...(decision ? { decision: { id: decision.id, set: decision.set, kind: decision.kind, ...(decision.task === undefined ? {} : { task: decision.task }) } } : {}),
              verdict: outcomeOf([{ checks: own, withheld: receipt.withheld }]),
              checks: own,
            })),
            checks,
          },
          lines,
          match: `The record is whole: ${r.entries} entr${r.entries === 1 ? "y" : "ies"}, chained from the first to a head the brain key signed at ${r.head?.signedAt}, each signed by a key its DecisionLog named its brain.`,
          notChecked: "that an entry without a receipt states what the board did, or that the agent runs the build its entries name.",
        });
      }
      if (licenceArg !== undefined) {
        const r = await verifyLicences(ctx, service, agentId);
        if (r.licences.length === 0 && r.checks.every((c) => c.status === "ok")) fail(`The brain host lists no licence for agent ${agentId} at ${r.url}`);
        const lines = r.checks.map(line);
        for (const l of r.licences) lines.push("", `  ${l.class}: ${l.state ?? "not a licence"}`, ...l.checks.map(line));
        const checks = [...r.checks, ...r.licences.flatMap((l) => l.checks)];
        reportHosted({
          header: `Agent ${agentId}'s licences ${on} ${r.url}`,
          checks,
          fields: { service: url, ...r, licences: r.licences.map((l) => ({ ...l, verdict: outcomeOf([l]) })) },
          lines,
          match: "Each licence is signed by a key its DecisionLog named its brain, and the state the host gives is the one its expiry and the identity registry give.",
          notChecked: "that the exam's judgments were right, or the audits behind a suspension.",
          // Each state follows the reply, so a reply read just before the id moved is stale, as papers are. Any other failure still reads as a mismatch.
          ...(r.stale && checks.every((c) => c.status !== "fail" || c.name === "licences-epoch")
            ? { stale: "The states the host gives no longer hold: the agent's id has changed epoch since the host read the registry for its reply, as the FAIL line shows. The host reads it at most a minute before it answers, so run the command again in a minute." }
            : {}),
        });
      }
      const r = await verifyPapers(ctx, service, agentId);
      const lines = r.checks.map(line);
      // What the papers say is shown only once the checks show the brain key said it, stale or not.
      if (r.epoch && r.checks.every((c) => c.status === "ok" || c.name === "papers-epoch")) {
        lines.push(
          "",
          `The papers state, signed ${r.signedAt}:`,
          `  epoch ${r.epoch.number} (${short(r.epoch.id)}): controller ${short(r.epoch.controller)}, ${r.epoch.build === "" ? "no build" : `build "${r.epoch.build}"`}`,
          `  record: ${r.record ? `${r.record.entries} entr${r.record.entries === 1 ? "y" : "ies"}, head ${short(r.record.head)}` : "none"}`,
          `  licences: ${r.licences?.length ? r.licences.map((l) => `${l.class} ${l.state}`).join(", ") : "none"}`,
        );
      }
      reportHosted({
        header: `Agent ${agentId}'s papers ${on} ${r.url}`,
        checks: r.checks,
        fields: { service: url, ...r },
        lines,
        match: "The brain key of the active DecisionLog signed these papers, the identity registry gives the id the epoch they state, and the record head they name is the record's.",
        notChecked: "the licences, counts and ceiling the papers list, which --licence and --record check at their source, or the file's fields outside brainchain, which nothing signs.",
        // Papers the brain key signed before the id left their epoch are stale, not forged. Any other failure still reads as a mismatch.
        ...(r.stale && r.checks.every((c) => c.status !== "fail" || c.name === "papers-epoch")
          ? { stale: "The papers no longer hold: the agent's id has left the epoch they state, as the epoch line shows. The host signs papers anew at most once a minute, so run the command again in a minute." }
          : {}),
      });
    } catch (error) {
      failWith(error);
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

  /**
   * The set that holds decision `id`: the one named, by --set or by the receipt, or else the active set. The active set
   * numbers its decisions from 1 again, so a bare id it does not hold yet is read from the newest set that does.
   */
  async function holding(id: bigint): Promise<ContractSet> {
    const count = (s: ContractSet): Promise<bigint> => client.readContract({ address: s.log, abi: decisionLogAbi, functionName: "count" });
    const decisions = await count(set);
    if (id <= decisions) return set;
    const others = network.sets.filter((s) => s !== set);
    const counts = await Promise.allSettled(others.map(count));
    const holds = (i: number): boolean => {
      const read = counts[i]!;
      return read.status === "fulfilled" && read.value >= id;
    };
    const range = `DecisionLog ${set.log} (set ${set.key}) holds decisions 1 to ${decisions}.`;
    if (setArg !== undefined || receiptSet) {
      // Only a hint, so a log the RPC cannot read is left out of it.
      const sets = others.filter((_, i) => holds(i)).map((s) => s.key);
      fail(`${range}${sets.length > 0 ? ` Each set numbers its own decisions; try --set ${sets.join(" or ")}.` : ""}`);
    }
    // The sets run newest first, so an older set is chosen only once each newer one is known to stop short of the id.
    const at = counts.findIndex((read, i) => read.status === "rejected" || holds(i));
    if (at < 0) fail(range);
    const read = counts[at]!;
    if (read.status === "rejected") throw read.reason;
    console.error(`Decision ${id} is not on set ${set.key} yet; reading set ${others[at]!.key}.`);
    return others[at]!;
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
      report(reports, `Task ${task} ${where} (TaskBoard ${set.board}): decision${ids.length === 1 ? "" : "s"} ${ids.join(", ")}${title ? `\nBrief: ${title}` : ""}`, set, Number(task));
    }

    const id = BigInt(target);
    const on = await holding(id);
    const checked = await verifyDecision(on === set ? ctx : { ...ctx, set: on }, id, receipt);
    // What the task is about, so a decision read from the wrong set does not pass for the one meant.
    report([checked], `Decision ${id} on ${network.name}, contract set ${on.key} (DecisionLog ${on.log})${checked.title ? `\nTask ${checked.task}: ${checked.title}` : ""}`, on);
  } catch (error) {
    failWith(error);
  }
}

try {
  await main();
} catch (error) {
  if (!(error instanceof Ended)) throw error;
}
