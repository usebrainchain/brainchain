import assert from "node:assert/strict";
import { execFile, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdtemp, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { createPublicClient, decodeFunctionData, encodeFunctionData, parseAbi, zeroAddress } from "viem";

import { DESK_MANDATE, settlersAt, verifyDeskOrder } from "../dist/desks.js";
import { rpcTransport } from "../dist/verify.js";

// Desk 2's order of 2026-11-26 on Robinhood Chain: 5.672886 USDG for SPY through 0x. The quote record is the brain's
// copy, byte for byte; the RPC answers and the desk log's entries around the order were recorded the next day.
const fixture = (name) => new URL(`./fixtures/desks/${name}`, import.meta.url);
const HASH = "0x4829f77f52142de55f083691099fdfb5bf13ca97bbf15e1a7dc3881b74ea869f";
const RECORD_NAME = "0xac8869a3b4bf435451c1e3db7b1b9fae6f34fa8cf6d379a6a716485c32a04582";
const RECORD_FILE = fileURLToPath(fixture(`${RECORD_NAME}.json`));
const RECORD_BYTES = readFileSync(RECORD_FILE);
const RECORD = JSON.parse(RECORD_BYTES);
const CHAIN = JSON.parse(readFileSync(fixture("order-0x4829f77f.json"), "utf8"));
const LOG = JSON.parse(readFileSync(fixture("desks.json"), "utf8"));
const STRANGER = "0x4444444444444444444444444444444444444444";
const word = (address) => `0x${address.slice(2).toLowerCase().padStart(64, "0")}`;

const tradeAbi = parseAbi(["function trade(uint8 desk, address token, bool buy, uint256 amountIn, uint256 minOut, bytes32 reasoning, bytes32 quote, bytes swap) returns (uint256)"]);
const execAbi = parseAbi(["function exec(address operator, address token, uint256 amount, address target, bytes data) payable returns (bytes)"]);
const executeAbi = parseAbi(["function execute((address recipient, address buyToken, uint256 minAmountOut) slippage, bytes[] actions, bytes32 zid) payable returns (bool)"]);

/** A JSON-RPC node that answers from `chain`, as Robinhood Chain answered for the order. */
async function node(chain = CHAIN, { chainId = chain.chainId, logs } = {}) {
  const server = createServer((request, response) => {
    let text = "";
    request.on("data", (chunk) => (text += chunk));
    request.on("end", () => {
      const { id, method, params } = JSON.parse(text);
      const answers = {
        eth_chainId: () => chainId,
        eth_getTransactionByHash: () => (params[0] === HASH ? chain.transaction : null),
        eth_getTransactionReceipt: () => (params[0] === HASH ? chain.receipt : null),
        eth_getBlockByNumber: () => chain.block,
        eth_call: () => (params[0].data === "0x95d89b41" ? chain.symbol : params[0].data === "0x313ce567" ? chain.decimals : new Error("execution reverted")),
        eth_getLogs: () => (logs ? logs(params[0]) : chain.settlerLogs.filter((l) => BigInt(l.blockNumber) >= BigInt(params[0].fromBlock) && BigInt(l.blockNumber) <= BigInt(params[0].toBlock))),
      };
      const result = answers[method] ? answers[method]() : new Error(`no ${method} here`);
      const reply = result instanceof Error ? { error: { code: -32000, message: result.message } } : { result };
      response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id, ...reply }));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return server;
}
const urlOf = (server) => `http://127.0.0.1:${server.address().port}`;
const clientOf = (server) => createPublicClient({ transport: rpcTransport("Robinhood Chain", urlOf(server)) });

// The brain's host, for the desk log and the quote record.
let host;
const pages = new Map();
before(async () => {
  host = createServer((request, response) => {
    const page = pages.get(request.url);
    if (!page) return void response.writeHead(404).end('{"error":"Not found"}');
    response.writeHead(page.status ?? 200, { "content-type": "application/json" }).end(page.body);
  });
  await new Promise((resolve) => host.listen(0, "127.0.0.1", resolve));
});
after(() => host.close());
const hosted = (path) => `${urlOf(host)}${path}`;
/** The desk log as the host serves it, with the order's quote record moved to this host. */
function serveLog(entries = LOG.entries, status = 200) {
  const moved = entries.map((e) => (e.quote ? { ...e, quote: { ...e.quote, uri: hosted(`/records/${RECORD_NAME}.json`) } } : e));
  pages.set("/desks", { status, body: JSON.stringify({ ...LOG, entries: moved }) });
  pages.set(`/records/${RECORD_NAME}.json`, { body: RECORD_BYTES });
}

async function run(options, chain, rpc) {
  const server = await node(chain, rpc);
  try {
    return await verifyDeskOrder(clientOf(server), HASH, options);
  } finally {
    server.close();
  }
}
const statuses = (report) => Object.fromEntries(report.checks.map((c) => [c.name, c.status]));
const failing = (report) => report.checks.filter((c) => c.status !== "ok").map((c) => c.name);
const ALL = [
  "order", "quote-record", "quote-digest",
  "zerox-signed", "zerox-key", "zerox-fresh", "zerox-covers", "zerox-digest", "zerox-signature",
  "quote-intent", "quote-request", "quote-response", "quote-target", "quote-spender", "quote-exec", "quote-settler", "quote-value", "quote-recipient", "quote-buy-token", "quote-min-out",
  "calldata", "spent", "received",
];
const writeTemp = async (name, contents) => {
  const file = join(await mkdtemp(join(tmpdir(), "desk-order-")), name);
  await writeFile(file, contents);
  return file;
};

describe("a desk order checked against its 0x quote", () => {
  it("passes the 26 November order on the quote record the desk log names", async () => {
    serveLog();
    const report = await run({ deskLog: hosted("/desks") });
    assert.deepEqual(failing(report), []);
    assert.deepEqual(report.checks.map((c) => c.name), ALL);
    assert.deepEqual(report.record, { uri: hosted(`/records/${RECORD_NAME}.json`), listed: true });
    assert.equal(report.mandate, DESK_MANDATE);
    assert.deepEqual(
      { desk: report.order.desk, symbol: report.order.symbol, buy: report.order.buy, amountIn: report.order.amountIn, amountOut: report.order.amountOut, settler: report.order.settler, sender: report.order.sender },
      { desk: 2, symbol: "SPY", buy: true, amountIn: "5672886", amountOut: "7840391599978831", settler: "0xE8852602f84e04e284286d8Db01a41Edd0CCEFb0", sender: "0x97D558417c3D61f1074422AD843e1Db1E565b952" },
    );
    const line = (name) => report.checks.find((c) => c.name === name).message;
    assert.match(line("zerox-fresh"), /^0x signed at 2026-11-26 20:22:22 UTC, 4 seconds before the order was mined, within 60$/);
    assert.match(line("quote-request"), /asks for this trade and nothing else/);
    assert.match(line("quote-settler"), /registry's previous Settler on chain 4663, as of the order's block$/);
    assert.match(line("quote-recipient"), /pays what is bought to 0x1CEb…fc16/);
    assert.match(line("calldata"), /the quote's transaction data byte for byte, 1636 bytes/);
    assert.match(line("spent"), /^the mandate sent exactly the 5672886 of USDG the quote sells$/);
    assert.match(line("received"), /received 7840391599978831 of SPY, the amount its Order event books, at or above the quote's minimum of 7761987683979043 and the mandate's floor of 7795974976614430/);
  });

  it("passes on a quote record given as a file, which no desk log is read for", async () => {
    pages.delete("/desks");
    const report = await run({ quote: RECORD_FILE, deskLog: hosted("/desks") });
    assert.deepEqual(failing(report), []);
    assert.deepEqual(report.record, { uri: RECORD_FILE, listed: false });
    assert.match(report.checks[1].message, /^read the quote record from .*, which hashes to the name it is published under$/);
  });

  it("fails a record that does not hash to its name, and one whose body is not what 0x signed or the order carries", async () => {
    const changed = Buffer.from(RECORD_BYTES.toString("utf8").replace('"receivedAt":1795724542', '"receivedAt":1795724543'));
    assert.notDeepEqual(changed, RECORD_BYTES);
    const renamed = await run({ quote: await writeTemp(`${RECORD_NAME}.json`, changed) });
    assert.deepEqual(failing(renamed), ["quote-record"]);
    assert.match(renamed.checks[1].message, /its keccak256 is 0x\w+, not the 0xac88\w+ it is published under/);

    const tampered = { ...RECORD, body: RECORD.body.replace('"buyAmount":"7840391599978831"', '"buyAmount":"7840391599978832"') };
    const report = await run({ quote: await writeTemp("quote.json", JSON.stringify(tampered)) });
    assert.equal(statuses(report)["quote-digest"], "fail");
    assert.equal(statuses(report)["zerox-digest"], "fail");
    assert.match(report.checks.find((c) => c.name === "quote-digest").message, /this is not the quote the order was sent on/);
  });

  it("fails an order that did not send the quote's calldata, or whose bought tokens went elsewhere", async () => {
    const call = decodeFunctionData({ abi: tradeAbi, data: CHAIN.transaction.input });
    const swap = call.args[7];
    const other = `${swap.slice(0, -2)}${swap.endsWith("00") ? "01" : "00"}`;
    const input = encodeFunctionData({ abi: tradeAbi, functionName: "trade", args: [...call.args.slice(0, 7), other] });
    const resent = await run({ quote: RECORD_FILE }, { ...CHAIN, transaction: { ...CHAIN.transaction, input } });
    assert.deepEqual(failing(resent), ["calldata"]);
    assert.match(resent.checks.find((c) => c.name === "calldata").message, /bytes that are not the quote's transaction data/);

    // The SPY the Settler paid out, sent to someone else: only the chain's own record of it shows that.
    const logs = CHAIN.receipt.logs.map((l) => (l.address === CHAIN.token && l.topics[2] === word(DESK_MANDATE) ? { ...l, topics: [l.topics[0], l.topics[1], word(STRANGER)] } : l));
    const elsewhere = await run({ quote: RECORD_FILE }, { ...CHAIN, receipt: { ...CHAIN.receipt, logs } });
    assert.deepEqual(failing(elsewhere), ["received"]);
    assert.match(elsewhere.checks.find((c) => c.name === "received").message, /^0 of SPY reached the mandate, but its Order event books 7840391599978831$/);
  });

  it("holds the query to the order: its sender as txOrigin, and the mandate as taker", async () => {
    const report = await run({ quote: RECORD_FILE }, { ...CHAIN, transaction: { ...CHAIN.transaction, from: STRANGER } });
    assert.deepEqual(failing(report), ["quote-request"]);
    assert.match(report.checks.find((c) => c.name === "quote-request").message, new RegExp(`txOrigin=0x97D558417c3D61f1074422AD843e1Db1E565b952 where ${STRANGER} was meant`));
  });

  it("is UNVERIFIED, not a mismatch, when the registry's history cannot be read", async () => {
    const report = await run({ quote: RECORD_FILE }, CHAIN, { logs: () => new Error("query exceeds max block range") });
    assert.deepEqual(failing(report), ["quote-settler"]);
    assert.equal(statuses(report)["quote-settler"], "error");
    assert.match(report.checks.find((c) => c.name === "quote-settler").message, /could not be read up to block 123730329: .*query exceeds max block range/);
  });

  it("refuses what is not a desk order that went through, and says where to find the quote the log no longer lists", async () => {
    await assert.rejects(run({}, { ...CHAIN, transaction: { ...CHAIN.transaction, to: STRANGER } }), /is not a desk order: it was sent to 0x4444/);
    await assert.rejects(run({}, { ...CHAIN, receipt: { ...CHAIN.receipt, status: "0x0" } }), /reverted: the mandate refused it, and nothing was traded/);
    await assert.rejects(run({}, { ...CHAIN, transaction: null }), /Robinhood Chain has no transaction 0x4829/);
    serveLog(LOG.entries.filter((e) => !e.tx));
    await assert.rejects(run({ deskLog: hosted("/desks") }), /The desk log's 2 latest entries do not include order 0x4829.*Pass its quote record with --quote/);
    serveLog(LOG.entries, 403);
    await assert.rejects(run({ deskLog: hosted("/desks") }), /answered with status 403.*Pass the order's quote record with --quote/);
  });
});

describe("a route on which 0x leaves the Settler's terms empty", () => {
  // The brain takes such a quote for the desks, whose mandate measures what it receives. A key of the test's own
  // signs it, since 0x's would not sign a changed body.
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const keys = [{ keyid: "test", x: publicKey.export({ format: "jwk" }).x }];

  function emptied() {
    const body = JSON.parse(RECORD.body);
    const outer = decodeFunctionData({ abi: execAbi, data: body.transaction.data });
    const inner = decodeFunctionData({ abi: executeAbi, data: outer.args[4] });
    const execute = encodeFunctionData({ abi: executeAbi, functionName: "execute", args: [{ recipient: zeroAddress, buyToken: zeroAddress, minAmountOut: 0n }, inner.args[1], inner.args[2]] });
    const data = encodeFunctionData({ abi: execAbi, functionName: "exec", args: [...outer.args.slice(0, 4), execute] });
    const text = JSON.stringify({ ...body, transaction: { ...body.transaction, data } });
    const digest = `sha-256=:${createHash("sha256").update(text).digest("base64")}:`;
    const created = Number(/created=(\d+)/.exec(RECORD.headers["signature-input"])[1]);
    const params = `("@status" "content-type" "content-digest" "@method";req "@authority";req "@path";req "@query";req);created=${created};keyid="test";alg="ed25519";tag="0x-swap-api"`;
    const base = [`"@status": 200`, `"content-type": application/json`, `"content-digest": ${digest}`, `"@method";req: GET`, `"@authority";req: api.0x.org`, `"@path";req: ${RECORD.request.path}`, `"@query";req: ${RECORD.request.query}`, `"@signature-params": ${params}`].join("\n");
    const signature = `sig=:${sign(null, Buffer.from(base), privateKey).toString("base64")}:`;
    const record = { ...RECORD, body: text, headers: { ...RECORD.headers, "content-digest": digest, "signature-input": `sig=${params}`, signature } };
    // The order as the desk would have sent it on that quote: its calldata and the SHA-256 of its body.
    const sha = `0x${createHash("sha256").update(text).digest("hex")}`;
    const call = decodeFunctionData({ abi: tradeAbi, data: CHAIN.transaction.input });
    const input = encodeFunctionData({ abi: tradeAbi, functionName: "trade", args: [...call.args.slice(0, 6), sha, data] });
    const logs = CHAIN.receipt.logs.map((l) => (l.address === DESK_MANDATE.toLowerCase() ? { ...l, topics: [...l.topics.slice(0, 3), sha] } : l));
    return { record, chain: { ...CHAIN, transaction: { ...CHAIN.transaction, input }, receipt: { ...CHAIN.receipt, logs } } };
  }

  it("skips the calldata's recipient, token and minimum, and holds what the mandate received to the order", async () => {
    const { record, chain } = emptied();
    const report = await run({ quote: await writeTemp("quote.json", JSON.stringify(record)), keys }, chain);
    assert.deepEqual(failing(report), ["quote-recipient", "quote-buy-token", "quote-min-out"]);
    for (const name of ["quote-recipient", "quote-buy-token", "quote-min-out"]) {
      assert.equal(statuses(report)[name], "skip", name);
      assert.match(report.checks.find((c) => c.name === name).message, /^the Settler's own terms are empty on this route, so the calldata/);
    }
    assert.equal(statuses(report).received, "ok");

    const logs = chain.receipt.logs.map((l) => (l.address === CHAIN.token && l.topics[2] === word(DESK_MANDATE) ? { ...l, topics: [l.topics[0], l.topics[1], word(STRANGER)] } : l));
    const elsewhere = await run({ quote: await writeTemp("quote.json", JSON.stringify(record)), keys }, { ...chain, receipt: { ...chain.receipt, logs } });
    assert.equal(statuses(elsewhere).received, "fail");
  });
});

describe("the registry's Settlers as of a block", () => {
  const log = (block, from, to) => ({ blockNumber: block, args: { from, to, tokenId: 2n } });
  const A = "0x1111111111111111111111111111111111111111";
  const B = "0x2222222222222222222222222222222222222222";

  it("takes the latest move of the registry's token at or before the block, searching further back until one is found", async () => {
    const asked = [];
    const client = {
      async getLogs({ fromBlock, toBlock }) {
        asked.push([fromBlock, toBlock]);
        return fromBlock <= 100n && 100n <= toBlock ? [log(100n, A, B)] : [];
      },
    };
    assert.deepEqual(await settlersAt(client, 12_000_000n), { current: B, previous: A });
    assert.deepEqual(asked, [[7_000_001n, 12_000_000n], [2_000_001n, 7_000_000n], [0n, 2_000_000n]]);
  });

  it("names no previous Settler for the first, none at all before it, and narrows the span an RPC refuses", async () => {
    assert.deepEqual(await settlersAt({ getLogs: async () => [log(5n, zeroAddress, A)] }, 10n), { current: A });
    assert.deepEqual(await settlersAt({ getLogs: async () => [] }, 10n), {});
    const spans = [];
    const narrow = {
      async getLogs({ fromBlock, toBlock }) {
        spans.push(toBlock - fromBlock + 1n);
        if (toBlock - fromBlock + 1n > 50_000n) throw new Error("block range too large");
        return [log(toBlock, A, B)];
      },
    };
    assert.deepEqual(await settlersAt(narrow, 9_000_000n), { current: B, previous: A });
    assert.deepEqual(spans, [5_000_000n, 500_000n, 50_000n]);
    await assert.rejects(settlersAt({ getLogs: async () => Promise.reject(new Error("down")) }, 9_000_000n), /down/);
  });
});

describe("the README's desk orders", () => {
  it("list the checks a report names: the desk's own around those of 0x quotes, but quote-gas", () => {
    const readme = readFileSync(new URL("../README.md", import.meta.url), "utf8");
    const table = (title) => [...readme.split(`\n## ${title}\n`)[1].split("\n## ")[0].matchAll(/^\| `([a-z-]+)` \|/gm)].map((m) => m[1]);
    const desk = table("Desk orders");
    const zerox = table("0x quotes").filter((name) => name !== "quote-gas");
    assert.deepEqual([...desk.slice(0, 3), ...zerox, ...desk.slice(3)], ALL);
  });
});

describe("desk-order on the command line", () => {
  const cli = fileURLToPath(new URL("../dist/cli.js", import.meta.url));
  const sync = (...args) => spawnSync(process.execPath, [cli, ...args], { encoding: "utf8" });
  // spawnSync would block the stub node this process serves.
  const spawn = (...args) => new Promise((resolve) => execFile(process.execPath, [cli, ...args], (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr })));

  it("checks an order against a quote record file and prints one line per check", async () => {
    const server = await node();
    try {
      const text = await spawn("desk-order", HASH, "--quote", RECORD_FILE, "--rpc", urlOf(server));
      assert.equal(text.code, 0, text.stderr);
      const lines = text.stdout.split("\n");
      assert.equal(lines[0], `Desk order ${HASH} on Robinhood Chain (DeskMandateV2 ${DESK_MANDATE})`);
      assert.equal(lines[1], "Desk 2 bought 0.007840391599978831 SPY for 5.672886 USDG in block 123730329, 2026-11-26 20:22:26 UTC");
      assert.equal(lines.filter((l) => /^ {2}ok {4}/.test(l)).length, ALL.length);
      assert.match(text.stdout, /\nVerdict: match\. 0x signed the quote this order was sent on, and the chain settled the order as quoted\.\n/);

      const json = await spawn("desk-order", HASH, "--quote", RECORD_FILE, "--rpc", urlOf(server), "--json");
      const out = JSON.parse(json.stdout);
      assert.equal(json.code, 0);
      assert.deepEqual([out.chainId, out.verdict, out.failed, out.errors, out.skipped, out.tx, out.mandate], [4663, "match", 0, 0, 0, HASH, DESK_MANDATE]);
      assert.deepEqual(out.checks.map((c) => c.name), ALL);
      assert.match(out.notChecked, /^Whether the order was a good trade\./);
    } finally {
      server.close();
    }
  });

  it("exits 1 with the FAIL lines when a check fails, and 2 on an RPC for another chain", async () => {
    const tampered = { ...RECORD, body: RECORD.body.replace('"buyAmount":"7840391599978831"', '"buyAmount":"7840391599978832"') };
    const server = await node();
    const base = await node(CHAIN, { chainId: "0x2105" });
    try {
      const failed = await spawn("desk-order", HASH, "--quote", await writeTemp("quote.json", JSON.stringify(tampered)), "--rpc", urlOf(server));
      assert.equal(failed.code, 1);
      assert.match(failed.stdout, /\n {2}FAIL {2}the SHA-256 of the body 0x signed is 0x/);
      assert.match(failed.stdout, /\nVerdict: MISMATCH\. \d+ checks failed; see the FAIL lines\.\n/);
      const other = await spawn("desk-order", HASH, "--rpc", urlOf(base));
      assert.equal(other.code, 2);
      assert.match(other.stderr, /^The RPC serves chain 8453, not Robinhood Chain \(4663\)/);
    } finally {
      server.close();
      base.close();
    }
  });

  it("refuses a command line of the wrong shape", () => {
    for (const [args, message] of [
      [["desk-order"], /^Name the order's transaction: desk-order <tx>\n\nUsage:/],
      [["desk-order", HASH, HASH], /^Too many arguments/],
      [["desk-order", HASH, "--set", "v3-6"], /^desk-order takes only --quote, --rpc and --json, not --set/],
      [["desk-order", HASH, "--offline"], /^desk-order takes only --quote, --rpc and --json, not --offline/],
      [["mainnet", "1", "--quote", RECORD_FILE], /^--quote goes with desk-order/],
      [["desk-order", "0x4829"], /^A transaction hash is 0x and 64 hex digits\n$/],
    ]) {
      const { status, stderr } = sync(...args);
      assert.equal(status, 2, args.join(" "));
      assert.match(stderr, message, args.join(" "));
    }
    const asJson = sync("desk-order", "nope", "--json");
    assert.equal(asJson.status, 2);
    assert.deepEqual(JSON.parse(asJson.stdout), { error: "A transaction hash is 0x and 64 hex digits" });
  });
});
