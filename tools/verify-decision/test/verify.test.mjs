import assert from "node:assert/strict";
import { execFile, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { after, before, describe, it } from "node:test";
import { fileURLToPath } from "node:url";

import { createPublicClient, encodeAbiParameters, encodeFunctionData, http, keccak256, toBytes, toHex } from "viem";

import { taskBoardAbi } from "../dist/abi.js";
import { canonicalStringify } from "../dist/canonical.js";
import { clean, outcomeOf, verifyDecision, withheldNotChecked } from "../dist/verify.js";

const YES = `0x${"0".repeat(63)}1`;
const NO = `0x${"0".repeat(64)}`;
const MARK = "[withheld until the work is accepted]";
const network = { chainId: 274663, name: "test", rpc: "http://unused", sets: [] };
const set = {
  key: "t",
  release: "3.4.0",
  fromBlock: 1,
  board: "0x1111111111111111111111111111111111111111",
  log: "0x2222222222222222222222222222222222222222",
  executor: "0x3333333333333333333333333333333333333333",
};
const STRANGER = "0x4444444444444444444444444444444444444444";
const Status = { Open: 1, Hired: 2, Delivered: 3, Graded: 4, Disputed: 5, Paid: 6, Refunded: 7, Ruled: 8, Appealed: 9 };

const LEVELS = ["Best", "Fine", "Bad"];
const taskSubject = (id) => keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "address" }, { type: "uint256" }], [BigInt(network.chainId), set.board, id]));
const paidSubject = (id) => keccak256(encodeAbiParameters([{ type: "string" }, { type: "bytes32" }], ["x402-grade", toHex(id, { size: 32 })]));
const acpSubject = (chain, job) => keccak256(encodeAbiParameters([{ type: "string" }, { type: "uint256" }, { type: "uint256" }], ["acp-evaluation", chain, job]));

const BRIEF = { title: "T", brief: "B", levels: LEVELS, passIndex: 1 };
const dataUri = (bytes) => `data:application/json;base64,${Buffer.from(bytes).toString("base64")}`;

/** A grade as the brain publishes it: accept at 0.9 from levels 1 and 2 of 3. */
function grade({ subject = "7", result = "the work", answer = "accept", confidence = 0.9, brief = "T\n\nB", extra = {}, state = {} } = {}) {
  const probabilities = answer === "accept" ? { 0: 0.1, 1: 0.5, 2: 0.4 } : { 0: 0.9, 1: 0.05, 2: 0.05 };
  return {
    answer,
    confidence,
    jevPaid: answer === "accept" ? 0.9 : 0.1,
    kind: "grade",
    model: "jev",
    passFrom: 1,
    probabilities,
    question: "How well?",
    request: { state: JSON.stringify({ result, task: { brief }, ...state }), questions: { decision: { type: "score", criteria: [...LEVELS].reverse(), instructions: "i" } } },
    scoreConfidence: 0.4,
    subject,
    ...extra,
  };
}

let server;
let base;
const pages = new Map();
const hits = [];

before(async () => {
  server = createServer((request, response) => {
    hits.push(request.url);
    const page = pages.get(request.url);
    if (!page) {
      response.writeHead(404).end("nope");
      return;
    }
    if (page.stream) {
      response.writeHead(200);
      const chunk = Buffer.alloc(1 << 20, 97);
      const pump = () => {
        for (let sent = 0; sent < page.stream; sent++) if (!response.write(chunk)) return void response.once("drain", pump);
        response.end();
      };
      response.on("error", () => {});
      pump();
      return;
    }
    response.writeHead(200, page.headers ?? {}).end(page.body);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

/**
 * One decision against a stub chain and the local host. `publish` is the original
 * record, which the chain's hashes commit; `serve` is what the host sends.
 */
async function verify({ kind = 2, subject = taskSubject(7n), answer = YES, bps = 9000, publish = grade(), serve, withheld = false, task = {}, bar = 7000, briefURI = dataUri(JSON.stringify(BRIEF)), briefHash, rpc = "http://127.0.0.1:1", graded = true, queued }) {
  const original = JSON.stringify(publish);
  const served = serve === undefined ? original : typeof serve === "string" ? serve : JSON.stringify(serve);
  const name = `/record-${pages.size}.json`;
  pages.set(name, { body: served, headers: withheld ? { "x-brainchain-withheld": "result" } : {} });
  const decision = { kind, subject, inputHash: keccak256(toBytes(canonicalStringify(publish.request))), answer, confidenceBps: bps, recordedAt: 1793000000n };
  const on = { poster: STRANGER, status: Status.Graded, accepted: false, hireThresholdBps: 5000, gradeThresholdBps: bar, ruleThresholdBps: 7000, ...task };
  const client = {
    transport: { url: rpc },
    readContract: async ({ functionName, address }) => {
      if (functionName === "config") return [5000, bar, 7000, 0n, 0n, 0n, 0n, 0n, 0n];
      if (functionName === "changeThresholdBps") return 7000;
      if (functionName === "getChange") return { eta: 1793000000n, executed: false, vetoed: false };
      if (functionName === "get") return address === set.log ? decision : on;
      throw new Error(`unexpected read ${functionName}`);
    },
    getContractEvents: async ({ eventName }) => {
      if (eventName === "Recorded") return [{ args: { id: 1n, ...decision, payloadHash: keccak256(toBytes(original)), payloadURI: `${base}${name}` }, blockNumber: 900n }];
      if (eventName === "Posted") return [{ args: { briefURI, briefHash: briefHash ?? keccak256(toBytes(JSON.stringify(BRIEF))) } }];
      if (eventName === "WorkGraded" && graded) return [{ args: { accepted: answer === YES && bps >= on.gradeThresholdBps } }];
      if (eventName === "Queued" && queued) return [{ args: { changeId: 1n, target: set.board, data: queued } }];
      return [];
    },
  };
  return verifyDecision({ client, network, set, briefs: new Map() }, 1n);
}

const check = (report, name) => report.checks.find((c) => c.name === name);
const status = (report, name) => check(report, name)?.status;
const failed = (report) => report.checks.filter((c) => c.status === "fail").map((c) => c.name);
/** What the records service sends for a record whose work is withheld. */
const redacted = (record) => {
  const state = JSON.parse(record.request.state);
  return { ...record, request: { ...record.request, state: JSON.stringify({ ...state, result: MARK }) } };
};

describe("a whole record", () => {
  it("matches, whether or not the host sends the header", async () => {
    for (const withheld of [false, true]) {
      const report = await verify({ withheld });
      assert.deepEqual(failed(report), []);
      assert.equal(status(report, "record-hash"), "ok");
      assert.equal(status(report, "input-hash"), "ok");
      assert.equal(report.withheld, undefined);
      assert.equal(outcomeOf([report]), "match");
    }
  });
});

describe("the withheld header", () => {
  const rejected = grade({ answer: "reject", confidence: 0.9 });
  const onRejected = { kind: 2, answer: NO, publish: rejected, serve: redacted(rejected), withheld: true };

  it("is honoured on a grade the board did not accept, and the verdict never reads match", async () => {
    const report = await verify(onRejected);
    assert.deepEqual(failed(report), []);
    assert.equal(report.withheld, true);
    assert.equal(status(report, "record-hash"), "skip");
    assert.equal(status(report, "input-hash"), "skip");
    assert.equal(status(report, "withheld"), "ok");
    assert.equal(outcomeOf([report]), "withheld");
    assert.equal(outcomeOf([{ checks: [], id: 2 }, report]), "withheld");
  });

  it("is honoured on a ruling while the task can still change", async () => {
    const ruling = { ...grade({ answer: "refund", confidence: 0.8 }), kind: "ruling", probabilities: { pay: 0.2, refund: 0.8 }, jevPaid: 0.2, passFrom: undefined };
    ruling.request.questions.decision = { type: "choice", criteria: { pay: "p", refund: "r" }, instructions: "i" };
    for (const task of [{ status: Status.Ruled, accepted: true }, { status: Status.Appealed, accepted: true }, { status: Status.Refunded, accepted: true }]) {
      const report = await verify({ kind: 3, answer: NO, bps: 8000, publish: ruling, serve: redacted(ruling), withheld: true, task });
      assert.equal(status(report, "withheld"), "ok", JSON.stringify(task));
      assert.equal(report.withheld, true);
    }
  });

  it("is refused on a hire or a change, which carry no work", async () => {
    for (const [kind, name] of [[1, "hire"], [4, "change"]]) {
      const report = await verify({ kind, publish: grade(), serve: { ...redacted(grade()), question: "FORGED" }, withheld: true });
      assert.equal(report.withheld, undefined);
      assert.equal(status(report, "withheld"), "fail");
      assert.match(check(report, "withheld").message, new RegExp(`a ${name} record carries no work`));
      assert.equal(status(report, "record-hash"), "fail");
      assert.equal(outcomeOf([report]), "mismatch");
    }
  });

  it("is refused where the chain shows the work is public", async () => {
    for (const task of [
      { status: Status.Paid, accepted: true },
      { status: Status.Paid, accepted: false },
      { status: Status.Graded, accepted: true },
      { status: Status.Disputed, accepted: true },
      { status: Status.Graded, accepted: false, poster: set.executor },
      { status: Status.Refunded, accepted: false, poster: set.executor },
    ]) {
      const report = await verify({ ...onRejected, task });
      assert.equal(status(report, "withheld"), "fail", JSON.stringify(task));
      assert.equal(status(report, "record-hash"), "fail");
      assert.equal(status(report, "input-hash"), "fail");
    }
  });

  it("is refused when the request does not carry the marker where the service puts it", async () => {
    for (const serve of [
      { ...rejected, question: "FORGED" },
      { ...rejected, request: { ...rejected.request, state: "not json" } },
      { ...rejected, request: { ...rejected.request, state: JSON.stringify({ task: { brief: "T\n\nB" } }) } },
      { ...rejected, request: { ...rejected.request, state: JSON.stringify({ result: "FORGED WORK", task: { brief: "T\n\nB" } }) } },
      { ...rejected, request: { ...rejected.request, state: JSON.stringify({ result: MARK, execution: { output: "leaked" }, task: { brief: "T\n\nB" } }) } },
    ]) {
      const report = await verify({ ...onRejected, serve });
      assert.equal(status(report, "withheld"), "fail");
      assert.equal(status(report, "record-hash"), "fail");
    }
  });

  it("still catches every change the chain can see on a copy it honours", async () => {
    const forged = redacted(grade({ answer: "reject", brief: "FORGED BRIEF" }));
    assert.deepEqual(failed(await verify({ ...onRejected, serve: forged })), ["brief"]);
    assert.ok(failed(await verify({ ...onRejected, serve: { ...redacted(rejected), answer: "accept" } })).includes("answer"));
    assert.ok(failed(await verify({ ...onRejected, serve: { ...redacted(rejected), confidence: 0.5 } })).includes("confidence"));
  });

  it("judges a paid grade by its answer and the bar, and an ACP evaluation as never public", async () => {
    const subject = paidSubject(7n);
    const accepted = grade({ answer: "accept", confidence: 0.64 });
    accepted.probabilities = { 0: 0.36, 1: 0.34, 2: 0.3 };
    accepted.jevPaid = 0.64;
    const low = await verify({ subject, bps: 6400, publish: accepted, serve: redacted(accepted), withheld: true });
    assert.equal(low.withheld, true);
    assert.match(check(low, "withheld").message, /64% is below the 70% bar/);
    assert.deepEqual(failed(low), []);

    const cleared = await verify({ subject, bps: 6400, bar: 6000, publish: accepted, serve: redacted(accepted), withheld: true });
    assert.equal(status(cleared, "withheld"), "fail");
    assert.equal(status(cleared, "record-hash"), "fail");

    const no = await verify({ subject, answer: NO, publish: rejected, serve: redacted(rejected), withheld: true });
    assert.equal(no.withheld, true);

    const acp = await verify({ subject: acpSubject(4663n, 7n), bps: 9000, publish: grade(), serve: redacted(grade()), withheld: true });
    assert.equal(acp.withheld, true);
    assert.match(check(acp, "withheld").message, /ACP evaluation is never published/);
  });

  it("says what it left unchecked in a task's terms only where there is a task", async () => {
    const outside = await verify({ subject: paidSubject(7n), answer: NO, publish: rejected, serve: redacted(rejected), withheld: true });
    assert.doesNotMatch(withheldNotChecked([outside]), /task|brief/);
    assert.match(withheldNotChecked([outside]), /the question, its levels and the second grader, is the host's word/);
    assert.match(withheldNotChecked([await verify(onRejected)]), /so do the task's brief, levels and threshold/);
  });
});

describe("a queued change", () => {
  const exact = encodeFunctionData({ abi: taskBoardAbi, functionName: "setWorkerAllowed", args: [STRANGER, true] });
  const decoded = { target: set.board, function: "setWorkerAllowed", args: [STRANGER, true] };
  const unknown = (data) => ({ target: set.board, function: "unknown", selector: data.slice(0, 10), data });
  const shown = (data, call) => {
    const subject = keccak256(encodeAbiParameters([{ type: "uint256" }, { type: "address" }, { type: "address" }, { type: "bytes" }], [BigInt(network.chainId), set.executor, set.board, data]));
    const publish = {
      answer: "adopt",
      confidence: 0.9,
      kind: "change",
      model: "jev",
      probabilities: { adopt: 0.9, keep: 0.1 },
      question: "Adopt?",
      request: { state: JSON.stringify({ call }), questions: { decision: { type: "choice", criteria: { adopt: "a", keep: "k" }, instructions: "i" } } },
      subject,
    };
    return verify({ kind: 4, subject, queued: data, publish });
  };

  it("compares an exact call by what it decodes to", async () => {
    const report = await shown(exact, decoded);
    assert.deepEqual(failed(report), []);
    assert.equal(status(report, "change-call"), "ok");
    assert.equal(status(await shown(exact, unknown(exact)), "change-call"), "fail");
  });

  it("compares a call that is not the exact encoding as unknown, as the brain showed Jev", async () => {
    for (const data of [`${exact}${"00".repeat(32)}`, `${exact.slice(0, 10)}${"ff".repeat(12)}${exact.slice(34)}`]) {
      const report = await shown(data, unknown(data));
      assert.deepEqual(failed(report), [], data);
      assert.equal(status(report, "change-call"), "ok", data);
      assert.equal(outcomeOf([report]), "match", data);
      assert.equal(status(await shown(data, decoded), "change-call"), "fail", data);
    }
  });
});

describe("grades of outside work", () => {
  it("reads an ACP evaluation from each of its chains as outside, and says what its subject is", async () => {
    for (const chain of [8453n, 84532n, 4663n, 46630n]) {
      const report = await verify({ subject: acpSubject(chain, 7n) });
      assert.deepEqual(failed(report), [], String(chain));
      assert.equal(report.outside, true);
      assert.ok(check(report, "subject").message.includes(`keccak256(abi.encode("acp-evaluation", ${chain}, 7))`));
    }
    assert.equal((await verify({ subject: acpSubject(1n, 7n), graded: false })).outside, undefined);
  });

  it("says what a paid grade's subject is, and that nothing on chain states its levels", async () => {
    const report = await verify({ subject: paidSubject(7n) });
    assert.match(check(report, "subject").message, /x402-grade/);
    assert.equal(status(report, "levels"), "skip");
    assert.match(check(report, "levels").message, /No brief on chain says what they should be/);
    assert.equal(status(report, "threshold"), "skip");
    assert.equal(outcomeOf([report]), "match");
  });

  it("fails a pass level that is not one of the question's levels", async () => {
    for (const passFrom of [0, 3, 99, -1, 1.5, null, "1", true, [1], {}]) {
      const publish = grade({ extra: { passFrom } });
      const report = await verify({ subject: paidSubject(7n), publish });
      assert.equal(status(report, "levels"), "fail", JSON.stringify(passFrom));
      assert.equal(status(report, "confidence-recomputed"), "skip");
      assert.equal(outcomeOf([report]), "mismatch");
    }
    assert.equal(status(await verify({ subject: paidSubject(7n), publish: grade({ extra: { passFrom: 2 } }) }), "levels"), "skip");
  });

  it("skips the recomputation where an old record names no pass level", async () => {
    const report = await verify({ subject: paidSubject(7n), publish: grade({ extra: { passFrom: undefined } }) });
    assert.equal(status(report, "levels"), undefined);
    assert.equal(status(report, "confidence-recomputed"), "skip");
  });
});

describe("briefs", () => {
  const brief = JSON.stringify(BRIEF);

  it("fail when the bytes do not match the hash on chain", async () => {
    const report = await verify({ briefURI: dataUri(JSON.stringify({ ...BRIEF, title: "FORGED" })) });
    assert.equal(status(report, "brief"), "fail");
    assert.match(check(report, "brief").message, /does not match its briefHash/);
    assert.equal(outcomeOf([report]), "mismatch");
  });

  it("skip when the host cannot be read, and say brief", async () => {
    const report = await verify({ briefURI: `${base}/no-such-brief` });
    assert.equal(status(report, "brief"), "skip");
    assert.match(check(report, "brief").message, /no longer has this brief/);
    assert.equal(outcomeOf([report]), "match");
  });

  it("are read from a private address only when the RPC is on one too", async () => {
    pages.set("/brief", { body: brief });
    hits.length = 0;
    const open = await verify({ briefURI: `${base}/brief` });
    assert.equal(status(open, "brief"), "ok");
    assert.ok(hits.includes("/brief"));

  });

  it("take the --rpc rule from a real client's transport", async () => {
    pages.set("/brief", { body: brief });
    const { client: stub } = publicRecord(`${base}/brief`);
    const real = (rpc) => Object.assign(createPublicClient({ transport: http(rpc) }), { readContract: stub.readContract, getContractEvents: stub.getContractEvents });
    assert.equal(status(await verifyDecision({ client: real("http://127.0.0.1:1"), network, set, briefs: new Map() }, 1n), "brief"), "ok");
    assert.equal(status(await verifyDecision({ client: real("http://localhost:1"), network, set, briefs: new Map() }, 1n), "brief"), "ok");
    const remote = await verifyDecision({ client: real("https://rpc.usebrainchain.invalid"), network, set, briefs: new Map() }, 1n);
    assert.equal(status(remote, "brief"), "skip");
    assert.match(check(remote, "brief").message, /private address/);
  });

  it("refuses a private brief with a public RPC, by address and by name, and never connects", async () => {
    const port = server.address().port;
    const { client, ctx } = publicRecord("");
    hits.length = 0;
    for (const host of ["127.0.0.1", "localhost", "[::1]", "[::ffff:127.0.0.1]", "2130706433", "0x7f.1", "0.0.0.0", "169.254.169.254", "10.0.0.1", "192.168.1.1", "172.16.0.1", "100.100.100.200"]) {
      client.brief = `http://${host}:${port}/brief`;
      const report = await verifyDecision({ ...ctx, briefs: new Map() }, 1n);
      assert.equal(status(report, "brief"), "skip", host);
      assert.match(check(report, "brief").message, /is on the private address/, host);
    }
    // The same guard on the https path, which would otherwise fail later on the certificate.
    client.brief = `https://localhost:${port}/brief`;
    assert.match(check(await verifyDecision({ ...ctx, briefs: new Map() }, 1n), "brief").message, /localhost is on the private address/);
    assert.ok(!hits.includes("/brief"));
    client.brief = "file:///etc/passwd";
    assert.match(check(await verifyDecision({ ...ctx, briefs: new Map() }, 1n), "brief").message, /file: URIs are not supported/);
  });

  it("stop being read at the size cap", async () => {
    pages.set("/huge", { stream: 1500 });
    const started = process.memoryUsage().rss;
    const report = await verify({ briefURI: `${base}/huge` });
    assert.equal(status(report, "brief"), "skip");
    assert.match(check(report, "brief").message, /larger than the 256 KB a brief may be/);
    assert.ok(process.memoryUsage().rss - started < 300 * 1024 * 1024);
    assert.equal(status(await verify({ briefURI: dataUri(Buffer.alloc(300 * 1024, 97)) }), "brief"), "skip");
  });

  it("carry no terminal codes into the output", async () => {
    const report = await verify({ briefURI: `${base}/gone?x=\x1b]0;PWNED\x07\x1b[31m‮` });
    const message = check(report, "brief").message;
    assert.ok(!/[\x00-\x1f\x7f-\x9f‮]/.test(message), JSON.stringify(message));
    assert.equal(clean("a\x1b[31mb‮c d…"), "a?[31mb?c?d…");
  });
});

/** A record on a data URI and a public RPC, so only the brief's location is in question. */
function publicRecord(briefURI) {
  const original = JSON.stringify(grade());
  const decision = { kind: 2, subject: taskSubject(7n), inputHash: keccak256(toBytes(canonicalStringify(grade().request))), answer: YES, confidenceBps: 9000, recordedAt: 1793000000n };
  const client = {
    brief: briefURI,
    transport: { url: "https://rpc.usebrainchain.invalid" },
    readContract: async ({ address }) => (address === set.log ? decision : { poster: STRANGER, status: Status.Graded, accepted: true, hireThresholdBps: 5000, gradeThresholdBps: 7000, ruleThresholdBps: 7000 }),
    getContractEvents: async ({ eventName }) => {
      if (eventName === "Recorded") return [{ args: { id: 1n, ...decision, payloadHash: keccak256(toBytes(original)), payloadURI: dataUri(original) }, blockNumber: 900n }];
      if (eventName === "Posted") return [{ args: { briefURI: client.brief, briefHash: keccak256(toBytes(JSON.stringify(BRIEF))) } }];
      if (eventName === "WorkGraded") return [{ args: { accepted: true } }];
      return [];
    },
  };
  return { client, ctx: { client, network, set, briefs: new Map() } };
}

describe("records", () => {
  it("are an error, not a mismatch, when the host is out of reach or too large", async () => {
    pages.set("/big-record", { stream: 8 });
    const decision = { kind: 2, subject: taskSubject(7n), inputHash: NO, answer: YES, confidenceBps: 9000, recordedAt: 1793000000n };
    for (const [uri, rpc, expected] of [
      [`${base}/big-record`, "http://127.0.0.1:1", /larger than the 4096 KB a record may be/],
      [`${base}/big-record`, "https://rpc.usebrainchain.invalid", /private address/],
    ]) {
      const client = {
        transport: { url: rpc },
        readContract: async () => decision,
        getContractEvents: async () => [{ args: { id: 1n, ...decision, payloadHash: NO, payloadURI: uri }, blockNumber: 900n }],
      };
      const report = await verifyDecision({ client, network, set, briefs: new Map() }, 1n);
      assert.equal(status(report, "fetch"), "error");
      assert.match(check(report, "fetch").message, expected);
      assert.equal(outcomeOf([report]), "unverified");
    }
  });
});

describe("the command line", () => {
  const cli = fileURLToPath(new URL("../dist/cli.js", import.meta.url));
  const run = (...args) => spawnSync(process.execPath, [cli, ...args], { encoding: "utf8" });
  // spawnSync would block the stub RPC this process serves.
  const runAsync = (...args) => new Promise((resolve) => execFile(process.execPath, [cli, ...args], (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr })));
  const MAINNET = 274663;
  const urlOf = (rpc) => `http://127.0.0.1:${rpc.address().port}`;

  /** Answers as `chainId` with an empty DecisionLog, so the CLI names the set it chose and stops. */
  async function stubRpc(chainId) {
    const rpc = createServer((request, response) => {
      let body = "";
      request.on("data", (chunk) => (body += chunk));
      request.on("end", () => {
        const { id, method } = JSON.parse(body);
        const result = method === "eth_chainId" ? toHex(chainId) : `0x${"0".repeat(64)}`;
        response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id, result }));
      });
    });
    await new Promise((resolve) => rpc.listen(0, "127.0.0.1", resolve));
    return rpc;
  }
  const onlyError = (stdout) => {
    const out = JSON.parse(stdout);
    assert.deepEqual(Object.keys(out), ["error"]);
    assert.doesNotMatch(out.error, /Usage:/);
    return out.error;
  };

  it("says a set from before 3.0.0 cannot be read", () => {
    for (const set of ["v2", "2.0.0", "0x83b31D99Fa31a9e5257955A737eF34c40f1c57bf"]) {
      const { status, stderr } = run("mainnet", "2", "--set", set);
      assert.equal(status, 2);
      assert.match(stderr, /predates release 3\.0\.0, which this tool does not read/);
    }
  });

  it("prints its version", () => {
    const { version } = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
    for (const args of [["--version"], ["-v"], ["mainnet", "1", "--version"]]) {
      const { status, stdout } = run(...args);
      assert.equal(status, 0, args.join(" "));
      assert.equal(stdout, `${version}\n`);
    }
  });

  it("opens a set by a key the site published it under before, as the site's ?set= does", async () => {
    const rpc = await stubRpc(MAINNET);
    try {
      const { code, stderr } = await runAsync("mainnet", "1", "--set", "v4", "--rpc", urlOf(rpc));
      assert.equal(code, 1);
      assert.match(stderr, /^DecisionLog 0xFdFEDb376c9632A4D6F15a1697E2b6853f12B4d7 \(set v3-4\) holds decisions 1 to 0/);
    } finally {
      rpc.close();
    }
    // The site matches names exactly, and publishes no testnet sets.
    for (const [network, name] of [["mainnet", "V4"], ["testnet", "v4"]]) {
      const { status, stderr } = run(network, "1", "--set", name);
      assert.equal(status, 2);
      assert.match(stderr, new RegExp(`^No contract set ${name} on `));
    }
  });

  it("does not take an inherited name for a network", () => {
    for (const name of ["constructor", "toString", "__proto__"]) {
      const { status, stderr } = run(name, "1");
      assert.equal(status, 2);
      assert.match(stderr, /Unknown network/);
    }
  });

  it("reports bad arguments as one JSON object with --json, and as text without it", () => {
    for (const args of [[], ["mainnet"], ["mainnet", "--task"], ["mainnet", "abc"], ["mainnet", "1", "2"], ["mainnet", "1", "--nope"], ["mainnet", "1", "--rpc", "ftp://x"], ["nowhere", "1"], ["mainnet", "1", "--set", "v2"], ["mainnet", "1", "--set", "nope"]]) {
      const asJson = run(...args, "--json");
      assert.equal(asJson.status, 2, args.join(" "));
      assert.equal(asJson.stderr, "", args.join(" "));
      onlyError(asJson.stdout);

      const asText = run(...args);
      assert.equal(asText.status, 2, args.join(" "));
      assert.equal(asText.stdout, "", args.join(" "));
      assert.match(asText.stderr, /\n\nUsage:\n/, args.join(" "));
    }
  });

  it("reports an RPC on another chain as one JSON object with --json", async () => {
    const rpc = await stubRpc(274630);
    try {
      const { code, stdout, stderr } = await runAsync("mainnet", "1", "--rpc", urlOf(rpc), "--json");
      assert.equal(code, 2);
      assert.equal(stderr, "");
      assert.match(onlyError(stdout), /^The RPC serves chain 274630, not /);
    } finally {
      rpc.close();
    }
  });

  it("reports a decision it cannot read as one JSON object with --json", async () => {
    const rpc = await stubRpc(MAINNET);
    try {
      const { code, stdout, stderr } = await runAsync("mainnet", "1", "--rpc", urlOf(rpc), "--json");
      assert.equal(code, 1);
      assert.equal(stderr, "");
      assert.match(onlyError(stdout), /holds decisions 1 to 0/);
    } finally {
      rpc.close();
    }
  });
});
