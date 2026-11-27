#!/usr/bin/env node
import { createRequire } from "node:module";

import { createPublicClient, type Hex, type PublicClient } from "viem";

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
  responsesHeld,
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

type Option = "--set" | "--epoch" | "--service" | "--rpc" | "--registry-rpc" | "--payment-rpc" | "--offline";

interface Mode {
  /** The option that names the mode. A decision id names its own. */
  flag?: string;
  shape: string;
  /** What the mode takes besides --json, in the order the usage lists it. */
  options: Option[];
}

// The usage and the parser both read this table, so the options the usage lists for a mode are the ones it takes.
const MODES: Mode[] = [
  { shape: "<mainnet|testnet|chainId> <decisionId>", options: ["--set", "--rpc", "--payment-rpc", "--offline"] },
  { flag: "--task", shape: "<mainnet|testnet|chainId> --task <taskId>", options: ["--set", "--rpc", "--payment-rpc", "--offline"] },
  { flag: "--receipt", shape: "<mainnet|testnet|chainId> [<decisionId>] --receipt <file|url>", options: ["--set", "--rpc", "--payment-rpc", "--offline"] },
  { flag: "--entry", shape: "mainnet --entry <agentId>:[<writer>:]<feedbackIndex>", options: ["--rpc", "--registry-rpc", "--payment-rpc"] },
  { flag: "--agent", shape: "mainnet --agent <agentId>", options: ["--rpc", "--registry-rpc", "--payment-rpc"] },
  { flag: "--record", shape: "<mainnet|testnet|chainId> --record <agentId>", options: ["--epoch", "--service", "--rpc", "--registry-rpc", "--payment-rpc"] },
  { flag: "--licence", shape: "<mainnet|testnet|chainId> --licence <agentId>", options: ["--service", "--rpc", "--registry-rpc"] },
  { flag: "--papers", shape: "<mainnet|testnet|chainId> --papers <agentId>", options: ["--service", "--rpc", "--registry-rpc"] },
  { flag: "--item", shape: "<mainnet|testnet|chainId> --item <itemId>", options: ["--service", "--rpc"] },
];
const VALUES: Partial<Record<Option, string>> = { "--set": "<TaskBoard>", "--service": "<url>", "--rpc": "<url>", "--registry-rpc": "<url>", "--payment-rpc": "<url>" };
const list = (items: string[], last = "and"): string => (items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} ${last} ${items.at(-1)}`);
const usageLine = (m: Mode): string => `  brainchain-verify ${m.shape} ${m.options.map((o) => `[${VALUES[o] ? `${o} ${VALUES[o]}` : o}]`).join(" ")} [--json]`;

const USAGE = `Usage:
${MODES.map(usageLine).join("\n")}

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
                 another brain host for --record, --licence, --papers and
                 --item; one on a private address is read only when --rpc is on
                 one too
  --offline      fetch no receipt from the brain host and no attestation from
                 the judges' gateway
  --set <board>  a retired contract set from 3.0.0 on, by TaskBoard address, by
                 its key on the site (v3-1) or by release (3.1.0), in any case;
                 without it, the active set, or for an id it does not hold yet,
                 the newest set that does
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

Exit status: 0 when every check that could run passed, 1 on a FAIL or ERROR
line, on stale papers or licences, or when what was asked for cannot be read,
2 on bad arguments or an RPC that serves another chain.`;

const TRUST_MODEL = "https://docs.usebrainchain.com/trust-model";
// A record that keeps each judge's response, held to its receipt, leaves only Jev's answer on BrainChain's word.
const notChecked = (held: boolean): string =>
  held
    ? "That Jev produced the answer. BrainChain records Jev's answers, and the contracts bound what a recorded answer can do."
    : "That Jev produced the answer, or that a judge's probabilities are the ones in the response its gateway hashed. BrainChain records Jev's answers and the judges' probabilities, and the contracts bound what a recorded answer can do.";
const notCheckedLine = (held: boolean): string =>
  `Not checked: that Jev produced the answer${held ? "" : ", or that a judge's probabilities are the ones in the response its gateway hashed"}. See ${TRUST_MODEL}`;
// Sets before 3.0.0 named tasks by id alone, which the subject check does not model, so the package carries none.
const BEFORE_3 = /^(v2(-|$)|2\.|0x83b31d99fa31a9e5257955a737ef34c40f1c57bf$)/i;
// The brain host answers 400 for any other spelling of an id, so the tool refuses it with the same rule.
const AGENT_ID = "An agent id is a whole number from 0 to 2^256 - 1, written without leading zeros";
// As agentIdOf in epoch.ts: one spelling for each id, within uint256.
const isAgentId = (text: string): boolean => /^(0|[1-9]\d{0,77})$/.test(text) && BigInt(text) >> 256n === 0n;
// The contracts count decisions and tasks from 1 in a uint256.
const isId = (text: string): boolean => text !== "0" && isAgentId(text);

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
  const foundNetwork = Object.hasOwn(NETWORKS, networkArg.toLowerCase())
    ? NETWORKS[networkArg.toLowerCase() as keyof typeof NETWORKS]
    : Object.values(NETWORKS).find((n) => String(n.chainId) === networkArg);
  if (!foundNetwork) fail(`Unknown network "${networkArg}": use mainnet, testnet, 274663 or 274630`, 2);
  const network = foundNetwork;
  if (extra.length > 0) usage("Too many arguments");
  if (taskArg !== undefined && receiptArg !== undefined) usage("A receipt is for one decision: name it, not a task");
  const flagged: Record<string, string | undefined> = { "--task": taskArg, "--receipt": receiptArg, "--entry": entryArg, "--agent": agentArg, "--record": recordArg, "--licence": licenceArg, "--papers": papersArg, "--item": itemArg };
  // A decision id is a mode alone, and with --receipt it names the decision the receipt is held to.
  const asked = MODES.filter((m) => (m.flag === undefined ? idArg !== undefined && receiptArg === undefined : flagged[m.flag] !== undefined));
  const modes = list(MODES.map((m) => m.flag ?? "a decision id"), "or");
  if (asked.length === 0) usage(`Name what to check: ${modes}`);
  if (asked.length > 1) usage(`Check one thing at a time: ${modes}`);
  const mode = asked[0]!;
  const options: Record<Option, boolean> = {
    "--set": setArg !== undefined,
    "--epoch": epoch,
    "--service": serviceArg !== undefined,
    "--rpc": rpcArg !== undefined,
    "--registry-rpc": registryRpcArg !== undefined,
    "--payment-rpc": paymentRpcArg !== undefined,
    "--offline": offline,
  };
  const stray = (Object.keys(options) as Option[]).find((o) => options[o] && !mode.options.includes(o));
  if (stray) usage(`${mode.flag ?? "A decision id"} takes only ${list([...mode.options, "--json"])}, not ${stray}`);
  if (paymentRpcArg !== undefined && offline && receiptArg === undefined) usage("With --offline, --payment-rpc is read only with --receipt");
  // The usage lists --registry-rpc for --record, so leaving out --epoch is not a command line of the wrong shape.
  if (registryRpcArg !== undefined && recordArg !== undefined && !epoch) fail("With --record, --registry-rpc is read only with --epoch", 2);
  const reputation = mode.flag === "--entry" || mode.flag === "--agent";
  const hosted = mode.flag === "--record" || mode.flag === "--licence" || mode.flag === "--papers" || mode.flag === "--item";
  // The registry says which epoch an id is in now: a licence's state and the papers turn on it, and a record reads it only when asked.
  const readsRegistry = licenceArg !== undefined || papersArg !== undefined || (recordArg !== undefined && epoch);
  const given = taskArg ?? idArg;
  if (given !== undefined && !isId(given)) fail(`${taskArg === undefined ? "A decision" : "A task"} id is a whole number from 1 to 2^256 - 1, written without leading zeros`, 2);

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
  if (target === undefined || !isId(target)) fail("The receipt names no decision; give the decision's id", 2);
  // A receipt names its log, so it opens a retired set on its own.
  const receiptSet = named && network.sets.find((s) => s.log.toLowerCase() === named.decisionLog.toLowerCase());

  const foundSet =
    setArg === undefined
      ? (receiptSet ?? network.sets[0])
      : network.sets.find((s) => [s.board, s.key, s.release, ...(s.aliases ?? [])].some((name) => name.toLowerCase() === setArg.toLowerCase()));
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
        ...(r.shape ? { shape: r.shape } : {}),
        ...(r.panel ? { panel: r.panel } : {}),
        ...(r.evidence ? { evidence: r.evidence } : {}),
        ...(r.receipt ? { receipt: r.receipt } : {}),
        ...(r.responses ? { responses: r.responses } : {}),
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
        notChecked: notChecked(responsesHeld(reports)),
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
    console.log(notCheckedLine(responsesHeld(reports)));
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
        notChecked: notChecked(responsesHeld(reports.flatMap((r) => (r.decision ? [r.decision] : [])))),
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
    console.log(notCheckedLine(responsesHeld(reports.flatMap((r) => (r.decision ? [r.decision] : [])))));
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
      const parts = /^(\d+):(?:(0x[0-9a-fA-F]{40}):)?(\d+)$/.exec(entryArg);
      if (!parts) fail("An entry is <agentId>:<feedbackIndex>, or <agentId>:<writer>:<feedbackIndex> for one BrainChain wrote from an earlier address", 2);
      if (!isAgentId(parts[1]!)) fail(AGENT_ID, 2);
      if (/^0+$/.test(parts[3]!)) fail(`An entry's index counts from 1 for each agent and writer, so the first is ${entryArg.replace(/\d+$/, "1")}`, 2);
      if (!/^[1-9]\d*$/.test(parts[3]!)) fail("An entry's index is a whole number from 1, written without leading zeros", 2);
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
    if (!isAgentId(agentArg!)) fail(AGENT_ID, 2);
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
    // Stale says that all else held, which a check that could not run leaves unknown.
    const overall = stale ? (errors > 0 ? "unverified" : "stale") : outcomeOf([{ checks, withheld: withheld.length > 0 }]);
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
    const given = serviceArg ?? known.url;
    // An index, not /\/+$/: that regex backtracks on a long run of slashes.
    let end = given.length;
    while (end > 0 && given[end - 1] === "/") end--;
    const url = given.slice(0, end);
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
    if (!isAgentId(asked)) fail(AGENT_ID, 2);
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
          // Skips are shown beside failures, since a verdict that points to the skip lines must find them here.
          const shown = receipt.checks.filter((c) => c.status !== "ok");
          if (shown.length === 0) continue;
          lines.push("", `Entry ${receipt.seq}'s receipt, ${receipt.path}${receipt.decision ? `, with decision ${receipt.decision.id} in set ${receipt.decision.set}` : ""}`, ...shown.map(line));
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
        // A reply that lists no licence has none to check, whatever its epoch line says.
        if (r.licences.length === 0 && r.checks.every((c) => c.status === "ok" || c.name === "licences-epoch")) fail(`The brain host lists no licence for agent ${agentId} at ${r.url}`);
        const lines = r.checks.map(line);
        for (const l of r.licences) lines.push("", `  ${l.class}: ${l.state ?? "not a licence"}`, ...l.checks.map(line));
        const checks = [...r.checks, ...r.licences.flatMap((l) => l.checks)];
        // Each state follows the reply, so a reply read just before the id moved is stale, as papers are, and so is each licence it gives. Any other failure still reads as a mismatch.
        const stale = r.stale === true && checks.every((c) => c.status !== "fail" || c.name === "licences-epoch");
        reportHosted({
          header: `Agent ${agentId}'s licences ${on} ${r.url}`,
          checks,
          fields: {
            service: url,
            ...r,
            licences: r.licences.map((l) => {
              const verdict = outcomeOf([l]);
              return { ...l, verdict: stale && verdict === "match" ? "stale" : verdict };
            }),
          },
          lines,
          match: "Each licence is signed by a key its DecisionLog named its brain, and the state the host gives is the one its expiry and the identity registry give.",
          notChecked: "that the exam's judgments were right, or the audits behind a suspension.",
          ...(stale
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
          ? { stale: "The papers no longer hold: the agent's id has left the epoch they state, as the FAIL line shows. The host signs papers anew at most once a minute, so run the command again in a minute." }
          : {}),
      });
    } catch (error) {
      failWith(error);
    }
  }

  /** The other sets whose boards hold a task with this id, for a task the board of `on` decided nothing on. */
  async function otherBoards(task: bigint, on: ContractSet): Promise<string> {
    const others = network.sets.filter((s) => s !== on);
    // Only a hint, so a board the RPC cannot read is left out of it.
    const counts = await Promise.allSettled(others.map((s) => client.readContract({ address: s.board, abi: taskBoardAbi, functionName: "count" })));
    const holding = others.filter((_, i) => {
      const count = counts[i]!;
      return count.status === "fulfilled" && count.value >= task;
    });
    return holding.length > 0 ? ` Each set numbers its own tasks; try --set ${holding.map((s) => s.key).join(" or ")}.` : "";
  }

  /**
   * The set that holds decision or task `id`: the one named, by --set or by the receipt, or else the active set. The active
   * set numbers its decisions and tasks from 1 again, so a bare id it does not hold yet is read from the newest set that does.
   */
  async function holding(what: "decision" | "task", id: bigint): Promise<ContractSet> {
    const count = (s: ContractSet): Promise<bigint> =>
      what === "task"
        ? client.readContract({ address: s.board, abi: taskBoardAbi, functionName: "count" })
        : client.readContract({ address: s.log, abi: decisionLogAbi, functionName: "count" });
    const held = await count(set);
    if (id <= held) return set;
    const others = network.sets.filter((s) => s !== set);
    const counts = await Promise.allSettled(others.map(count));
    const holds = (i: number): boolean => {
      const read = counts[i]!;
      return read.status === "fulfilled" && read.value >= id;
    };
    if (setArg !== undefined || receiptSet) {
      // Only a hint, so a contract the RPC cannot read is left out of it.
      const sets = others.filter((_, i) => holds(i)).map((s) => s.key);
      const where = what === "task" ? `TaskBoard ${set.board}` : `DecisionLog ${set.log}`;
      const has = held === 0n ? `Set ${set.key} holds no ${what}s yet.` : `${where} (set ${set.key}) holds ${what}s 1 to ${held}.`;
      fail(`${has}${sets.length > 0 ? ` Each set numbers its own ${what}s; try --set ${sets.join(" or ")}.` : ""}`);
    }
    // The sets run newest first, so an older set is chosen only once each newer one is known to stop short of the id.
    const at = counts.findIndex((read, i) => read.status === "rejected" || holds(i));
    if (at < 0) {
      let most = { key: set.key, held };
      for (const [i, read] of counts.entries()) if (read.status === "fulfilled" && read.value > most.held) most = { key: others[i]!.key, held: read.value };
      fail(most.held === 0n ? `No set holds any ${what}s yet.` : `No set holds ${what} ${id}; set ${most.key} holds 1 to ${most.held}.`);
    }
    const read = counts[at]!;
    if (read.status === "rejected") throw read.reason;
    console.error(`${what === "task" ? "Task" : "Decision"} ${id} is not on set ${set.key} yet; reading set ${others[at]!.key}.`);
    return others[at]!;
  }

  try {
    await sameChain();

    if (taskArg !== undefined) {
      const task = BigInt(taskArg);
      const on = await holding("task", task);
      const context = on === set ? ctx : { ...ctx, set: on };
      const where = `on ${network.name}, contract set ${on.key}`;
      const ids = await decisionsOf(context, task);
      if (ids.length === 0) fail(`Task ${task} has no decisions ${where}.${await otherBoards(task, on)}`);
      const reports: DecisionReport[] = [];
      for (const id of ids) reports.push(await verifyDecision(context, id).catch((error: unknown) => ({ id: Number(id), checks: [unread(`decision ${id}`, error)] })));
      const title = reports.find((r) => r.title)?.title;
      report(reports, `Task ${task} ${where} (TaskBoard ${on.board}): decision${ids.length === 1 ? "" : "s"} ${ids.join(", ")}${title ? `\nBrief: ${title}` : ""}`, on, Number(task));
    }

    const id = BigInt(target);
    const on = await holding("decision", id);
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
