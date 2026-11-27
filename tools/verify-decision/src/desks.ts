// A BrainChain desk's order on Robinhood Chain, held to the 0x quote it was sent on and to what the chain moved.

import { createHash } from "node:crypto";

import {
  decodeEventLog,
  decodeFunctionData,
  getAddress,
  keccak256,
  parseAbi,
  TransactionNotFoundError,
  TransactionReceiptNotFoundError,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";

import { clean, errorMessage, readSource, type Check } from "./verify.js";
import { SETTLER_REGISTRY, TAKER_SETTLER, verifyQuote, type Settlers, type ZeroxKey } from "./zerox.js";

export const DESK_CHAIN = 4663;
export const DESK_RPC = "https://rpc.mainnet.chain.robinhood.com";
/** DeskMandateV2, which holds the desks' money and sends their orders. Its source is verified on Sourcify. */
export const DESK_MANDATE: Address = "0x1CEb9aeeEab74eEf65A3E5DED14b59BecfBCfc16";
/** The desks' log: each round's decisions, and for an order its transaction and the quote record it was sent on. */
export const DESK_LOG = "https://brain.usebrainchain.com/desks";
const USDG: Address = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";

// The log is worked out per request and takes 10 to 25 seconds to start answering.
const DESK_LOG_MS = 60_000;
const MAX_DESK_LOG_BYTES = 4 * 1024 * 1024;
const MAX_QUOTE_BYTES = 256 * 1024;
// Public RPCs cap how many blocks one log query spans; this many has been served on Robinhood Chain.
const LOG_SPAN = 5_000_000n;

const mandateAbi = parseAbi([
  "function trade(uint8 desk, address token, bool buy, uint256 amountIn, uint256 minOut, bytes32 reasoning, bytes32 quote, bytes swap) returns (uint256)",
  "event Order(uint8 indexed desk, address indexed token, bool buy, uint256 amountIn, uint256 amountOut, uint256 feedPrice, uint256 floor, uint256 minOut, bytes32 reasoning, bytes32 indexed quote, address settler)",
]);
const tokenAbi = parseAbi(["event Transfer(address indexed from, address indexed to, uint256 value)", "function symbol() view returns (string)", "function decimals() view returns (uint8)"]);
const registryAbi = parseAbi(["event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)"]);

export interface DeskOrder {
  desk: number;
  token: Address;
  /** The token's own symbol, where it answers with one. */
  symbol?: string;
  decimals?: number;
  buy: boolean;
  /** USDG spent on a buy, or the token sold, in its smallest units. */
  amountIn: string;
  /** What the mandate received, as its Order event books it. */
  amountOut: string;
  minOut: string;
  floor: string;
  feedPrice: string;
  reasoning: Hex;
  /** The SHA-256 of 0x's signed body, which the order carries. */
  quote: Hex;
  settler: Address;
  sender: Address;
  block: number;
  /** Seconds since the epoch. */
  minedAt: number;
}

export interface DeskOrderReport {
  tx: Hex;
  mandate: Address;
  order: DeskOrder;
  /** Where the quote record was read, and whether the desk log named it. */
  record: { uri: string; listed: boolean };
  checks: Check[];
}

export interface DeskOrderOptions {
  /** The quote record, a file or a URL, in place of the one the desk log names. */
  quote?: string;
  deskLog?: string;
  /** Trusted in place of the 0x keys this package pins. */
  keys?: readonly ZeroxKey[];
}

/** A record the brain keeps of a 0x answer: the request 0x signed, and the response as it arrived. */
interface KeptAnswer {
  kind: "0x answer";
  request: { method: string; authority: string; path: string; query: string };
  status: number;
  headers: Record<string, string>;
  body: string;
  receivedAt: number;
}

const same = (a: string | undefined | null, b: string | undefined | null) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
const short = (value: string) => `${value.slice(0, 6)}…${value.slice(-4)}`;
const utc = (seconds: number): string => `${new Date(seconds * 1000).toISOString().replace("T", " ").slice(0, 19)} UTC`;

/** Throws when `hash` is no desk order that went through, or its quote record cannot be read; anything else is a check. */
export async function verifyDeskOrder(client: PublicClient, hash: Hex, options: DeskOrderOptions = {}): Promise<DeskOrderReport> {
  const [tx, receipt] = await Promise.all([client.getTransaction({ hash }), client.getTransactionReceipt({ hash })]).catch((error: unknown) => {
    if (error instanceof TransactionNotFoundError || error instanceof TransactionReceiptNotFoundError) throw new Error(`Robinhood Chain has no transaction ${hash}, or the RPC does not find it yet`);
    throw error;
  });
  if (!same(tx.to, DESK_MANDATE)) throw new Error(`Transaction ${hash} is not a desk order: it was sent to ${tx.to ?? "no contract"}, not DeskMandateV2 ${DESK_MANDATE}`);
  let call;
  try {
    call = decodeFunctionData({ abi: mandateAbi, data: tx.input });
  } catch {
    throw new Error(`Transaction ${hash} calls DeskMandateV2, but not to place an order`);
  }
  if (receipt.status !== "success") throw new Error(`Desk order ${hash} reverted: the mandate refused it, and nothing was traded`);
  const event = receipt.logs.flatMap((log) => {
    if (!same(log.address, DESK_MANDATE)) return [];
    try {
      const decoded = decodeEventLog({ abi: mandateAbi, data: log.data, topics: log.topics });
      return decoded.eventName === "Order" ? [decoded.args] : [];
    } catch {
      return [];
    }
  })[0];
  if (!event) throw new Error(`Desk order ${hash} went through without an Order event from DeskMandateV2`);
  const [desk, token, buy, amountIn, minOut, reasoning, digest, swap] = call.args;
  const [block, symbol, decimals] = await Promise.all([
    client.getBlock({ blockNumber: receipt.blockNumber }),
    // Only for display, so a token that does not answer is shown by its address.
    client.readContract({ address: token, abi: tokenAbi, functionName: "symbol" }).catch(() => undefined),
    client.readContract({ address: token, abi: tokenAbi, functionName: "decimals" }).catch(() => undefined),
  ]);
  const shown = typeof symbol === "string" && /^[\p{L}\p{N}.\-]{1,16}$/u.test(symbol) ? symbol : undefined;
  const order: DeskOrder = {
    desk,
    token: getAddress(token),
    ...(shown ? { symbol: shown } : {}),
    ...(decimals === undefined ? {} : { decimals }),
    buy,
    amountIn: amountIn.toString(),
    amountOut: event.amountOut.toString(),
    minOut: minOut.toString(),
    floor: event.floor.toString(),
    feedPrice: event.feedPrice.toString(),
    reasoning,
    quote: digest,
    settler: getAddress(event.settler),
    sender: getAddress(tx.from),
    block: Number(receipt.blockNumber),
    minedAt: Number(block.timestamp),
  };
  const named = shown ?? short(order.token);
  const [sold, bought] = buy ? [USDG, order.token] : [order.token, USDG];
  const nameOf = (address: Address) => (same(address, USDG) ? "USDG" : named);
  const checks: Check[] = [];
  const add = (name: string, status: Check["status"], message: string) => void checks.push({ name, status, message: clean(message) });

  add(
    "order",
    "ok",
    `desk ${desk} ${buy ? `bought ${named} with ${amountIn} of USDG` : `sold ${amountIn} of ${named} for USDG`} on DeskMandateV2 ${short(DESK_MANDATE)}, sent by ${short(order.sender)} and mined in block ${order.block} at ${utc(order.minedAt)}`,
  );

  let source = options.quote;
  let listed: { digest?: unknown; hash?: unknown } | undefined;
  if (source === undefined) {
    const where = options.deskLog ?? DESK_LOG;
    const log = await readSource(client, where, "desk log", MAX_DESK_LOG_BYTES, DESK_LOG_MS).catch((error: unknown) => {
      throw new Error(`${errorMessage(error)}. Pass the order's quote record with --quote <file|url>`);
    });
    const entries = parsed<{ entries?: unknown }>(log)?.entries;
    if (!Array.isArray(entries)) throw new Error(`${where} is not the desk log: it lists no entries`);
    const entry = entries.find((e: { tx?: unknown } | null) => typeof e === "object" && e !== null && same(e.tx as string, hash)) as { quote?: { uri?: unknown; digest?: unknown; hash?: unknown } } | undefined;
    // The log keeps the latest 200 entries, so an order falls out of it as the desks go on deciding.
    if (!entry) throw new Error(`The desk log's ${entries.length} latest entries do not include order ${hash}. Pass its quote record with --quote <file|url>`);
    if (typeof entry.quote?.uri !== "string") throw new Error(`The desk log lists order ${hash} without a quote record`);
    source = entry.quote.uri;
    listed = entry.quote;
  }
  const from = source;
  const report = (): DeskOrderReport => ({ tx: hash, mandate: DESK_MANDATE, order, record: { uri: clean(from), listed: listed !== undefined }, checks });
  const bytes = await readSource(client, source, "quote record", MAX_QUOTE_BYTES).catch((error: unknown) => {
    throw new Error(`The order's quote record could not be read: ${errorMessage(error)}`);
  });

  const answer = parsed<KeptAnswer>(bytes);
  const kept = keccak256(bytes);
  const name = /(0x[0-9a-fA-F]{64})\.json$/.exec(from.split(/[?#]/)[0]!)?.[1];
  const problem = !isKeptAnswer(answer)
    ? "it is not a 0x answer as the brain keeps one"
    : answer.request.method !== "GET" || answer.request.authority !== "api.0x.org" || answer.request.path !== "/swap/allowance-holder/quote"
      ? `it answers ${answer.request.method} ${answer.request.authority}${answer.request.path}, not a 0x AllowanceHolder quote`
      : name !== undefined && !same(name, kept)
        ? `its keccak256 is ${kept}, not the ${name} it is published under`
        : listed?.hash !== undefined && !same(listed.hash as string, kept)
          ? `its keccak256 is ${kept}, not the ${String(listed.hash)} the desk log gives`
          : undefined;
  if (problem || !isKeptAnswer(answer)) {
    add("quote-record", "fail", `the quote record at ${from}: ${problem}`);
    return report();
  }
  add("quote-record", "ok", `${listed ? "the desk log names the quote record" : "read the quote record from"} ${from}${name ? ", which hashes to the name it is published under" : ""}`);

  const body = new TextEncoder().encode(answer.body);
  const sha256 = `0x${createHash("sha256").update(body).digest("hex")}`;
  const digestOk = same(sha256, digest) && same(sha256, event.quote) && (listed?.digest === undefined || same(listed.digest as string, sha256));
  add(
    "quote-digest",
    digestOk ? "ok" : "fail",
    digestOk
      ? `the SHA-256 of the body 0x signed, ${short(sha256)}, is the digest the order sent and its Order event carries`
      : `the SHA-256 of the body 0x signed is ${sha256}, but the order carries ${digest}: this is not the quote the order was sent on`,
  );

  const slippage = new URLSearchParams(answer.request.query).get("slippageBps");
  const intent = {
    chainId: DESK_CHAIN,
    taker: DESK_MANDATE,
    txOrigin: order.sender,
    sellToken: sold,
    buyToken: bought,
    sellAmount: amountIn,
    minBuyAmount: minOut,
    // It sets only 0x's own minimum: the order's minOut and the mandate's floor bound the fill regardless.
    ...(slippage !== null && /^\d{1,5}$/.test(slippage) ? { slippageBps: Number(slippage) } : {}),
  };
  let unread: unknown;
  const quoted = await verifyQuote({ status: answer.status, headers: answer.headers, body }, `https://${answer.request.authority}${answer.request.path}${answer.request.query}`, intent, {
    settlers: () =>
      settlersAt(client, receipt.blockNumber).catch((error: unknown) => {
        unread = error;
        throw error;
      }),
    now: () => order.minedAt * 1000,
    ...(options.keys ? { keys: options.keys } : {}),
  });
  const empty = quoted.decoded !== undefined && same(quoted.decoded.recipient, zeroAddress) && same(quoted.decoded.buyToken, zeroAddress) && quoted.decoded.minAmountOut === 0n;
  const created = quoted.signature.created;
  for (const c of quoted.checks) {
    if (c.name === "zerox-fresh" && created !== undefined) {
      const age = order.minedAt - created;
      const when = age >= 0 ? `${age} seconds before the order was mined` : `${-age} seconds after the order was mined`;
      add(c.name, c.status, c.status === "ok" ? `0x signed at ${utc(created)}, ${when}, within 60` : `0x signed at ${utc(created)}, ${when}, outside the 60 seconds a signature is good for`);
    } else if (c.name === "quote-settler") {
      add(c.name, unread !== undefined ? "error" : c.status, unread !== undefined ? `0x's registry ${SETTLER_REGISTRY} could not be read up to block ${order.block}: ${errorMessage(unread)}` : `${c.message}, as of the order's block`);
    } else if (empty && EMPTY_TERMS[c.name]) {
      // The mandate takes such a route only because it measures what it receives, which received checks.
      add(c.name, "skip", `the Settler's own terms are empty on this route, so the calldata ${EMPTY_TERMS[c.name]}`);
    } else {
      add(c.name, c.status, c.message);
    }
  }
  if (!quoted.quote || !quoted.decoded) return report();

  const { quote, decoded } = quoted;
  const sameData = same(quote.transaction.data, swap);
  const sameSettler = same(event.settler, decoded.settler);
  add(
    "calldata",
    sameData && sameSettler ? "ok" : "fail",
    !sameData
      ? `the order handed AllowanceHolder ${(swap.length - 2) / 2} bytes that are not the quote's transaction data, so it did not trade on this quote`
      : !sameSettler
        ? `the order's Order event names Settler ${order.settler}, but the quote's calldata runs ${decoded.settler}`
        : `the order handed AllowanceHolder the quote's transaction data byte for byte, ${(swap.length - 2) / 2} bytes, and its Order event names the Settler that runs it, ${short(order.settler)}`,
  );

  const moved = receipt.logs.flatMap((log) => {
    if (!same(log.address, sold) && !same(log.address, bought)) return [];
    try {
      const decoded = decodeEventLog({ abi: tokenAbi, eventName: "Transfer", data: log.data, topics: log.topics });
      return [{ token: log.address, ...decoded.args }];
    } catch {
      return [];
    }
  });
  const total = (picked: typeof moved) => picked.reduce((sum, t) => sum + t.value, 0n);
  const out = total(moved.filter((t) => same(t.token, sold) && same(t.from, DESK_MANDATE)));
  const spentOk = out === amountIn && event.amountIn === amountIn && quote.sellAmount === amountIn;
  add(
    "spent",
    spentOk ? "ok" : "fail",
    spentOk
      ? `the mandate sent exactly the ${amountIn} of ${nameOf(sold)} the quote sells`
      : `the mandate sent ${out} of ${nameOf(sold)} and its Order event books ${event.amountIn}, where the quote sells ${quote.sellAmount ?? "nothing"}`,
  );
  const into = total(moved.filter((t) => same(t.token, bought) && same(t.to, DESK_MANDATE)));
  const least = quote.minBuyAmount ?? 0n;
  const receivedOk = into > 0n && into === event.amountOut && into >= event.floor && into >= least;
  add(
    "received",
    receivedOk ? "ok" : "fail",
    receivedOk
      ? `the mandate received ${into} of ${nameOf(bought)}, the amount its Order event books, at or above the quote's minimum of ${least} and the mandate's floor of ${event.floor}; 0x expected ${quote.buyAmount}`
      : into !== event.amountOut
        ? `${into} of ${nameOf(bought)} reached the mandate, but its Order event books ${event.amountOut}`
        : `the mandate received ${into} of ${nameOf(bought)}, under ${into < least ? `the quote's minimum of ${least}` : `the mandate's floor of ${event.floor}`}`,
  );
  return report();
}

const EMPTY_TERMS: Readonly<Record<string, string>> = {
  "quote-recipient": "names no recipient. received shows where the bought token went",
  "quote-buy-token": "names no token bought. received shows which token arrived",
  "quote-min-out": "sets no minimum. The mandate refuses less than its floor and the order's minOut, and received holds the fill to both",
};

// Public RPCs keep old logs but not old state, and the registry moves its token to each new Settler from the one `prev` then names.
export async function settlersAt(client: Pick<PublicClient, "getLogs">, block: bigint): Promise<Settlers> {
  let span = LOG_SPAN;
  for (let end = block; ; ) {
    const start = end >= span ? end - span + 1n : 0n;
    let logs;
    try {
      logs = await client.getLogs({ address: SETTLER_REGISTRY, event: registryAbi[0], args: { tokenId: TAKER_SETTLER }, fromBlock: start, toBlock: end, strict: true });
    } catch (error) {
      if (span <= 50_000n) throw error;
      span /= 10n;
      continue;
    }
    const last = logs.at(-1);
    if (last) return { current: getAddress(last.args.to), ...(same(last.args.from, zeroAddress) ? {} : { previous: getAddress(last.args.from) }) };
    if (start === 0n) return {};
    end = start - 1n;
  }
}

function parsed<T>(bytes: Uint8Array): T | undefined {
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as T;
  } catch {
    return undefined;
  }
}

function isKeptAnswer(value: unknown): value is KeptAnswer {
  const v = value as Partial<KeptAnswer> | undefined;
  const request = v?.request as Partial<KeptAnswer["request"]> | undefined;
  return (
    typeof v === "object" &&
    v !== null &&
    v.kind === "0x answer" &&
    typeof v.body === "string" &&
    Number.isSafeInteger(v.status) &&
    Number.isSafeInteger(v.receivedAt) &&
    typeof v.headers === "object" &&
    v.headers !== null &&
    Object.values(v.headers).every((h) => typeof h === "string") &&
    typeof request?.method === "string" &&
    typeof request.authority === "string" &&
    typeof request.path === "string" &&
    typeof request.query === "string"
  );
}
