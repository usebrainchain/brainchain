#!/usr/bin/env node
// How long BrainChain tasks take, step by step, read from the TaskBoard events of
// every contract set on the chain, retired sets included.
//
//   node tools/latency.mjs                    mainnet
//   node tools/latency.mjs --network testnet  testnet
//
// Times come from block timestamps and are given in minutes. "All" counts every
// task that reached both ends of a step; "paid" counts only the tasks whose
// bounty was paid. Settled means paid or refunded, whichever path got there:
// finalize after the dispute window, a ruling, or a refund at the deadline.
//
// No dependencies: plain fetch and JSON-RPC, one request at a time, with retries
// and paged log queries.

const NETWORKS = {
  mainnet: {
    name: "BrainChain mainnet",
    rpc: "https://rpc.usebrainchain.com",
    chainId: 274663,
    // Every set's board, oldest first, as in the site's addresses.json.
    boards: [
      ["2", "0x83b31D99Fa31a9e5257955A737eF34c40f1c57bf", 1],
      ["3.0.0", "0x33825Bc40E43cC7f8A301D6b7aC79eDCDb92ACa7", 101],
      ["3.1.0", "0x6fBF25F036F18C7AE3b1B7343ED8d16Dc695f6e0", 282],
      ["3.3.0", "0x72C890AA996bF7efcA88e3F5063B626560215160", 425],
    ],
  },
  testnet: {
    name: "BrainChain testnet",
    rpc: "https://rpc.testnet.usebrainchain.com",
    chainId: 274630,
    boards: [
      ["first", "0x66d0a539115fbEa6A90A3BF964b306e5a25f584F", 0],
      ["2", "0x686633c82F81b99B1Ae9bAAE458Aa8280F158367", 0],
      ["3.0.0 at a 70% hire bar", "0x4E5E2eee7c1CBe1484f3E8218151a567f9144f4F", 0],
      ["3.0.0", "0x53b4eB2de26E4f3d4172c4F963Bb00D0b8035eeA", 352],
      ["3.1.0", "0xC74564F100e70F95346A6e399ebf1Ce14309C8B6", 898],
    ],
  },
};

// Version 2 boards paid and refunded with shorter events; both forms are read.
const TOPICS = {
  "0x7c1c491e8c1a7f70f8859b23eac675ac153697f160a98688e35aecdea187174f": "posted", // Posted(uint256,address,uint128,uint64,bytes32,string)
  "0x7f7a82d4575241f009e05a1e1f78161e77964fe144f4a97535e78e8d253e4d06": "hired", // WorkerHired(uint256,bytes32,uint256)
  "0x87a7eafd4c28cbdbcbe48b79f9a77fcb753a71b21ca435c2724d7d767216ae89": "delivered", // WorkSubmitted(uint256,bytes32,bytes32,string)
  "0x1459acc5585bcb7eddfd1078fae5187de2a517f53e8dfdfd44bec913c6ca8280": "graded", // WorkGraded(uint256,uint256,bool)
  "0x57f4a57e16c2fbdacaa6cde8b489009fccc2eb26f17a4575009518349ca080d9": "paid", // BountyPaid(uint256,bytes32,address,uint128,uint128)
  "0x5ff93981be13b0af36462df9283414325147257202b154e770cac5d3d299faa9": "paid", // BountyPaid(uint256,bytes32,address,uint128)
  "0x9ec89eb93e58f08b12aa171f67e14befc803eacf239f3e5592af898989ae3804": "refunded", // BountyRefunded(uint256,address,uint128,uint8)
  "0x61f37109266a588e06aa3d1b5fe61e86faca164cd159dbf0edf928a301525880": "refunded", // BountyRefunded(uint256,address,uint128)
};

const STEPS = [
  ["posted → hired", "posted", "hired"],
  ["hired → delivered", "hired", "delivered"],
  ["delivered → graded", "delivered", "graded"],
  ["graded → paid or refunded", "graded", "settled"],
  ["posted → settled", "posted", "settled"],
];

const LOG_PAGE = 10_000;
const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36";

const flag = process.argv.indexOf("--network");
const networkName = flag === -1 ? "mainnet" : process.argv[flag + 1];
const network = NETWORKS[networkName];
if (!network) {
  console.error(`Unknown network ${networkName ?? "(none)"}: use mainnet or testnet.`);
  process.exit(1);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The node answered with a JSON-RPC error rather than failing to answer. */
class RpcError extends Error {}

async function rpc(method, params = [], { retries = 4 } = {}) {
  let last;
  for (let attempt = 0; attempt <= retries; attempt++) {
    if (attempt > 0) await sleep(1000 * 2 ** (attempt - 1));
    try {
      const response = await fetch(network.rpc, {
        method: "POST",
        headers: { "content-type": "application/json", "user-agent": UA },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
        signal: AbortSignal.timeout(20_000),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const body = await response.json();
      if (body.error) throw new RpcError(body.error.message ?? JSON.stringify(body.error));
      return body.result;
    } catch (error) {
      if (error instanceof RpcError) throw error;
      last = error;
    }
  }
  throw new Error(`${method} failed: ${last?.message ?? last}`);
}

const hex = (n) => `0x${n.toString(16)}`;

/** Logs in [from, to], a page at a time; a page the node refuses is split in half. */
async function logs(address, topics, from, to) {
  const out = [];
  let start = from;
  let span = LOG_PAGE;
  while (start <= to) {
    const end = Math.min(start + span - 1, to);
    try {
      out.push(...(await rpc("eth_getLogs", [{ address, topics, fromBlock: hex(start), toBlock: hex(end) }])));
      start = end + 1;
      span = LOG_PAGE;
    } catch (error) {
      if (!(error instanceof RpcError) || span === 1) throw error;
      span = Math.ceil(span / 2);
    }
  }
  return out;
}

const blockTimes = new Map();
async function timestamp(log) {
  if (log.blockTimestamp) return Number(log.blockTimestamp);
  const number = Number(log.blockNumber);
  if (!blockTimes.has(number)) {
    const block = await rpc("eth_getBlockByNumber", [hex(number), false]);
    blockTimes.set(number, Number(block.timestamp));
  }
  return blockTimes.get(number);
}

/** Linear interpolation between the closest ranks. */
function percentile(sorted, p) {
  const rank = (p / 100) * (sorted.length - 1);
  const low = Math.floor(rank);
  const high = Math.ceil(rank);
  return sorted[low] + (sorted[high] - sorted[low]) * (rank - low);
}

const chainId = Number(await rpc("eth_chainId"));
if (chainId !== network.chainId) {
  console.error(`${network.rpc} is chain ${chainId}, expected ${network.chainId}.`);
  process.exit(1);
}
const head = await rpc("eth_getBlockByNumber", ["latest", false]);
const headNumber = Number(head.number);

const tasks = [];
const perBoard = [];
for (const [label, address, fromBlock] of network.boards) {
  const byId = new Map();
  for (const log of await logs(address, [Object.keys(TOPICS)], fromBlock, headNumber)) {
    const kind = TOPICS[log.topics[0]];
    const id = BigInt(log.topics[1]);
    if (!byId.has(id)) byId.set(id, {});
    const task = byId.get(id);
    task[kind] ??= await timestamp(log);
  }
  const boardTasks = [...byId.values()].filter((t) => t.posted !== undefined);
  for (const t of boardTasks) t.settled = t.paid ?? t.refunded;
  tasks.push(...boardTasks);
  perBoard.push({ label, address, posted: boardTasks.length, settled: boardTasks.filter((t) => t.settled).length });
}

const paid = tasks.filter((t) => t.paid !== undefined);
const refunded = tasks.filter((t) => t.paid === undefined && t.refunded !== undefined);
const open = tasks.length - paid.length - refunded.length;

function stats(sample, from, to) {
  const minutes = sample
    .filter((t) => t[from] !== undefined && t[to] !== undefined)
    .map((t) => (t[to] - t[from]) / 60)
    .sort((a, b) => a - b);
  if (minutes.length === 0) return [0, "-", "-"];
  const fmt = (m) => (m < 10 ? m.toFixed(1) : Math.round(m).toString());
  return [minutes.length, fmt(percentile(minutes, 50)), fmt(percentile(minutes, 90))];
}

const at = new Date(Number(head.timestamp) * 1000).toISOString().replace(/:\d\d\.\d+Z$/, "Z");
console.log(`${network.name}, chain ${chainId}, block ${headNumber} (${at})`);
for (const b of perBoard) {
  console.log(`  ${b.label.padEnd(24)} ${b.address}  ${b.posted} posted, ${b.settled} settled`);
}
console.log(`Tasks: ${tasks.length} posted, ${paid.length + refunded.length} settled (${paid.length} paid, ${refunded.length} refunded), ${open} open\n`);

const rows = STEPS.map(([name, from, to]) => [name, ...stats(tasks, from, to), ...stats(paid, from, to)]);
const header = ["Minutes", "all n", "p50", "p90", "paid n", "p50", "p90"];
const widths = header.map((h, i) => Math.max(h.length, ...rows.map((r) => String(r[i]).length)));
const line = (cells) => cells.map((c, i) => (i === 0 ? String(c).padEnd(widths[i]) : String(c).padStart(widths[i]))).join("  ");
console.log(line(header));
for (const row of rows) console.log(line(row));
