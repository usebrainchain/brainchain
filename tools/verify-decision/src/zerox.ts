// Checks for a 0x Swap API answer before anything it returns is signed: 0x's own signature on the response (RFC 9421,
// Ed25519), then the AllowanceHolder transaction it carries, decoded and held to what the caller asked for. Nothing
// here trusts the network path to 0x, so the same checks hold for an answer bought through 0x's keyless gateway.

import { createHash, createPublicKey, verify as verifyEd25519 } from "node:crypto";

import { BaseError, ContractFunctionRevertedError, decodeFunctionData, encodeFunctionData, getAddress, isAddress, parseAbi, zeroAddress, type Address, type Hex, type PublicClient } from "viem";

import type { Check } from "./verify.js";

/** A key 0x signs responses with: the JWK's `kid` and its Ed25519 `x`, base64url. */
export interface ZeroxKey {
  keyid: string;
  x: string;
}

/**
 * The only keys this package trusts, picked by keyid. 0x lists a new key on
 * its docs before it signs with it, and each one ships in a patch release;
 * nothing is read from the network.
 */
export const ZEROX_KEYS: readonly ZeroxKey[] = [{ keyid: "0x-signing-key-prod-24092026", x: "19P3C981JsyQsqwVho8Tlabx51rslvdruSH59mGuWn0" }];

/**
 * The Accept-Signature header to send. It names no key, so 0x signs with
 * whichever key is active and a rotation needs no change on the caller's side.
 */
export const ACCEPT_SIGNATURE = 'sig=("@status" "content-type" "content-digest" "@method";req "@authority";req "@path";req "@query";req);tag="0x-swap-api"';

/** 0x's advice: reject a signature made more than this long ago. */
export const MAX_AGE_SECONDS = 60;

/** AllowanceHolder, the only contract a quote's transaction may call and the only spender to approve. */
export const ALLOWANCE_HOLDER: Readonly<Record<number, Address>> = {
  1: "0x0000000000001fF3684f28c67538d4D072C22734",
  8453: "0x0000000000001fF3684f28c67538d4D072C22734",
  4663: "0x0000000000001fF3684f28c67538d4D072C22734",
};

/** 0x's Settler registry, an ERC-721 at the same address on every chain; token 2 is the Settler for taker-sent swaps. */
export const SETTLER_REGISTRY: Address = "0x00000000000004533Fe15556B1E086BB1A72cEae";
export const TAKER_SETTLER = 2n;

/** How the Swap API names the native token. */
export const NATIVE: Address = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

const API_AUTHORITY = "api.0x.org";
/** The gateway's slugs for the Swap API endpoints it forwards, and the path 0x signs for each. */
const GATEWAY_PATHS: Readonly<Record<string, string>> = {
  "swap-allowance-holder-price": "/swap/allowance-holder/price",
  "swap-allowance-holder-quote": "/swap/allowance-holder/quote",
};
const GATEWAY_CHANNELS = new Set(["x402", "x402-testnet", "mpp-tempo", "mpp-tempo-testnet"]);
const REQUIRED_COMPONENTS = ["@status", "content-digest", "@method;req", "@authority;req", "@path;req", "@query;req"];

const allowanceHolderAbi = parseAbi(["function exec(address operator, address token, uint256 amount, address target, bytes data) payable returns (bytes)"]);
const settlerAbi = parseAbi(["function execute((address recipient, address buyToken, uint256 minAmountOut) slippage, bytes[] actions, bytes32 zid) payable returns (bool)"]);
const registryAbi = parseAbi(["function ownerOf(uint256 tokenId) view returns (address)", "function prev(uint128 featureId) view returns (address)"]);

/** The request 0x signed. Through the gateway that is the Swap API request it forwards, not the gateway's own URL. */
export interface SignedRequest {
  method: string;
  authority: string;
  path: string;
  /** As sent, with its leading `?`. */
  query: string;
}

export interface SignedResponse {
  status: number;
  headers: Headers | Readonly<Record<string, string | undefined>>;
  /** The bytes 0x sent, kept before anything reads the body, such as new Uint8Array(await response.clone().arrayBuffer()). */
  body: Uint8Array;
}

/** The body as bytes; a parsed or decoded body cannot be held to 0x's digest. */
function bytesOf(body: unknown): Uint8Array {
  if (body instanceof Uint8Array) return body;
  const what = body instanceof ArrayBuffer ? "an ArrayBuffer" : body === null ? "null" : typeof body === "object" ? "an object" : `a ${typeof body}`;
  throw new TypeError(
    `the response body is ${what}: pass the raw response bytes 0x sent as a Uint8Array, such as new Uint8Array(await response.clone().arrayBuffer()), taken before the body is read`,
  );
}

/**
 * The request 0x signs for a Swap API URL: an api.0x.org URL as it is, or a
 * gateway URL (agent.api.0x.org/v1/<channel>/<slug>/) as the request the
 * gateway forwards. Throws for any other URL.
 */
export function signedRequestOf(url: string | URL, method = "GET"): SignedRequest {
  const u = new URL(url);
  const query = u.search === "" ? "?" : u.search;
  if (u.protocol !== "https:") throw new Error(`${u.origin} is not https`);
  if (u.host === API_AUTHORITY) return { method: method.toUpperCase(), authority: API_AUTHORITY, path: u.pathname, query };
  const [, version, channel, slug, ...rest] = u.pathname.split("/");
  const path = slug !== undefined && Object.hasOwn(GATEWAY_PATHS, slug) ? GATEWAY_PATHS[slug] : undefined;
  if (u.host !== "agent.api.0x.org" || version !== "v1" || !GATEWAY_CHANNELS.has(channel ?? "") || path === undefined || rest.some((part) => part !== "")) {
    throw new Error(`${u.origin}${u.pathname} is not a 0x Swap API price or quote endpoint`);
  }
  return { method: method.toUpperCase(), authority: API_AUTHORITY, path, query };
}

export interface SignatureOptions {
  /** Trusted in place of ZEROX_KEYS. */
  keys?: readonly ZeroxKey[];
  /** Milliseconds since the epoch; Date.now unless given. */
  now?: () => number;
  maxAgeSeconds?: number;
}

export interface SignatureReport {
  ok: boolean;
  checks: Check[];
  keyid?: string;
  /** When 0x signed, in seconds since the epoch. */
  created?: number;
}

/**
 * Whether 0x signed this response for this request: a key the caller trusts,
 * Ed25519, made within maxAgeSeconds of now, covering the status, the body's
 * digest and the request's method, authority, path and query. Checks run in
 * order and stop at the first that fails, since each depends on the one before.
 */
export function verifyResponse(response: SignedResponse, request: SignedRequest, options: SignatureOptions = {}): SignatureReport {
  const keys = options.keys ?? ZEROX_KEYS;
  const maxAge = options.maxAgeSeconds ?? MAX_AGE_SECONDS;
  const clock = (options.now ?? Date.now)();
  const now = Math.floor(clock / 1000);
  const checks: Check[] = [];
  const pass = (name: string, message: string) => void checks.push({ name, status: "ok", message });
  const fail = (name: string, message: string, extra: Partial<SignatureReport> = {}): SignatureReport => {
    checks.push({ name, status: "fail", message });
    return { ok: false, checks, ...extra };
  };
  const header = (name: string) => headerOf(response.headers, name);
  const body = bytesOf(response.body);

  const input = header("signature-input");
  const signatureField = header("signature");
  if (input === undefined || signatureField === undefined) {
    return fail("zerox-signed", "0x did not sign this response: it has no Signature-Input or Signature header. Ask with the Accept-Signature header");
  }
  let params: SignatureParams;
  let signature: Buffer;
  try {
    params = parseSignatureInput(input);
    signature = parseSignature(signatureField);
  } catch (error) {
    return fail("zerox-signed", `0x's signature headers could not be read: ${(error as Error).message}`);
  }
  const { keyid, created, alg, tag, expires } = params;
  if (alg !== "ed25519" || tag !== "0x-swap-api") {
    return fail("zerox-signed", `the signature is ${alg === undefined ? "of no named algorithm" : `alg ${alg}`}${tag === undefined ? " with no tag" : ` tagged ${tag}`}; 0x signs Swap API answers with alg ed25519 and tag 0x-swap-api`);
  }
  pass("zerox-signed", "signed with Ed25519 under the tag 0x-swap-api");

  if (keyid === undefined) return fail("zerox-key", "the signature names no key");
  const key = keys.find((k) => k.keyid === keyid);
  if (key === undefined) {
    const known = keys.map((k) => k.keyid).join(", ") || "none";
    return fail(
      "zerox-key",
      options.keys === undefined
        ? `signed with key ${keyid}, which this version of brainchain-verify does not carry (it trusts ${known}). 0x has a new signing key, and a newer version of brainchain-verify is needed to check it`
        : `signed with key ${keyid}, which is not among the keys given (${known})`,
      { keyid },
    );
  }
  pass("zerox-key", `key ${keyid}`);

  // NaN compares false with everything, so a clock or limit that is not a number would pass any signature as fresh.
  if (!Number.isFinite(clock) || !Number.isFinite(maxAge) || maxAge < 0) {
    return fail("zerox-fresh", `the clock reads ${clock} and the age limit is ${maxAge} seconds: both must be finite numbers, the limit at least 0`, { keyid });
  }
  if (created === undefined) return fail("zerox-fresh", "the signature has no created time", { keyid });
  const age = now - created;
  if (Math.abs(age) > maxAge || (expires !== undefined && expires < now)) {
    const when = age >= 0 ? `${age} seconds ago` : `${-age} seconds ahead of this clock`;
    return fail("zerox-fresh", `0x signed ${when}, outside the ${maxAge} seconds a signature is good for: ask 0x again rather than act on it`, { keyid, created });
  }
  pass("zerox-fresh", `signed ${Math.max(age, 0)} seconds ago, within ${maxAge}`);

  const covered = params.components.map((c) => c.name + (c.req ? ";req" : ""));
  const missing = REQUIRED_COMPONENTS.filter((name) => !covered.includes(name));
  if (missing.length > 0) return fail("zerox-covers", `the signature leaves out ${missing.join(", ")}, so it does not bind the answer to this request`, { keyid, created });
  pass("zerox-covers", `covers ${covered.join(", ")}`);

  const digest = header("content-digest");
  const sha256 = digest === undefined ? undefined : sha256Of(digest);
  const actual = createHash("sha256").update(body).digest("base64");
  if (sha256 === undefined) return fail("zerox-digest", "the response has no sha-256 Content-Digest", { keyid, created });
  if (sha256 !== actual) return fail("zerox-digest", "the body's sha-256 is not the one in Content-Digest: the body changed after 0x signed it", { keyid, created });
  pass("zerox-digest", "the body's sha-256 matches Content-Digest");

  let base: string;
  try {
    base = signatureBase(params, request, response);
  } catch (error) {
    return fail("zerox-signature", (error as Error).message, { keyid, created });
  }
  const publicKey = createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: key.x }, format: "jwk" });
  const verifies = (query: string) => verifyEd25519(null, Buffer.from(signatureBase(params, { ...request, query }, response)), publicKey, signature);
  if (!verifyEd25519(null, Buffer.from(base), publicKey, signature)) {
    if (reordered(request.query).some(verifies)) {
      return fail("zerox-signature", "0x signed the parameters in a different order: pass the exact URL you requested, not one rebuilt from its parameters", { keyid, created });
    }
    return fail(
      "zerox-signature",
      `0x's signature does not verify for ${request.method} ${request.authority}${request.path} with this query: the answer was changed, or it answers another request`,
      { keyid, created },
    );
  }
  pass("zerox-signature", `0x signed this answer to ${request.method} ${request.authority}${request.path} with this exact query`);
  return { ok: true, checks, keyid, created };
}

/**
 * The query with its parameters in every other order, for a query of up to
 * seven: a URL rebuilt from the same parameters is the common reason a true
 * answer fails, and saying so beats calling it changed.
 */
function reordered(query: string): string[] {
  const parts = query.replace(/^\?/, "").split("&");
  if (parts.length < 2 || parts.length > 7) return [];
  const orders: string[][] = [];
  const permute = (left: string[], taken: string[]) => {
    if (left.length === 0) return void orders.push(taken);
    left.forEach((part, i) => permute([...left.slice(0, i), ...left.slice(i + 1)], [...taken, part]));
  };
  permute(parts, []);
  return orders.map((order) => `?${order.join("&")}`).filter((other) => other !== query);
}

/** The Settler for taker-sent swaps on a chain, and the one before it, which 0x's API can still use for a while after a new one is deployed. */
export interface Settlers {
  /** Undefined when 0x has paused Settler there, which the registry says by reverting. */
  current?: Address;
  previous?: Address;
}

/**
 * Reads the Settlers on `chainId` from 0x's registry, through a client that
 * must be on that chain. An RPC that does not answer, or a client on another
 * chain, throws; a revert means paused.
 */
export async function readSettlers(client: Pick<PublicClient, "readContract" | "getChainId"> & { chain?: { name?: string } }, chainId: number, featureId = TAKER_SETTLER): Promise<Settlers> {
  const clientChainId = await client.getChainId();
  if (clientChainId !== chainId) throw new Error(`the client reads chain ${clientChainId}${client.chain?.name ? ` (${client.chain.name})` : ""}, not chain ${chainId}, which the quote is for`);
  const read = async (functionName: "ownerOf" | "prev"): Promise<Address | undefined> => {
    try {
      return await client.readContract({ address: SETTLER_REGISTRY, abi: registryAbi, functionName, args: [featureId] });
    } catch (error) {
      if (error instanceof BaseError && error.walk((e) => e instanceof ContractFunctionRevertedError)) return undefined;
      throw error;
    }
  };
  const [current, previous] = await Promise.all([read("ownerOf"), read("prev")]);
  return { ...(current ? { current } : {}), ...(previous && previous !== zeroAddress ? { previous } : {}) };
}

/**
 * What the caller wants from a quote: exactly one of sellAmount and buyAmount,
 * with the caller's own limit for it, since the quote's are 0x's.
 */
export interface QuoteIntent {
  chainId: number;
  /** Sends the transaction and, unless recipient says otherwise, gets what it buys. */
  taker: Address;
  /** Asked for in the query when given. */
  recipient?: Address;
  /** NATIVE for the chain's own token. */
  sellToken: Address;
  buyToken: Address;
  /** Exact in: the amount sold. */
  sellAmount?: bigint;
  /** Exact out: the amount bought. */
  buyAmount?: bigint;
  /** Exact out, required: the most the caller sells for it. */
  maxSellAmount?: bigint;
  /** Exact in, required: the least the caller takes. On exact out it may be given, and is never below buyAmount. */
  minBuyAmount?: bigint;
  /** The slippageBps the query asked 0x for; the query may carry it only when this names it. */
  slippageBps?: number;
  /** The most the quote's gas times its gasPrice may come to. */
  maxGasCost?: bigint;
  /** For a chain not in ALLOWANCE_HOLDER; on a chain in it, only that address. */
  allowanceHolder?: Address;
}

/** The parts of a quote these checks read. Amounts are in the tokens' smallest units. */
export interface Quote {
  mode: "exact-in" | "exact-out";
  sellToken: Address;
  buyToken: Address;
  /** Exact in: sold. Exact out: absent. */
  sellAmount?: bigint;
  /** Exact out: the most the swap takes. */
  maxSellAmount?: bigint;
  /** Exact out: what 0x expects the swap to take. */
  estimatedNetSellAmount?: bigint;
  buyAmount: bigint;
  /** Exact in: the least the swap gives before it reverts. */
  minBuyAmount?: bigint;
  /** 0x's estimate. The caller sends with fee fields of its own. */
  transaction: { to: Address; data: Hex; value: bigint; gas?: bigint; gasPrice?: bigint };
  /** The spender 0x asks the taker to approve, when the sold token needs an approval. */
  spender?: Address;
  /** The contract 0x names for approvals, when it names one. */
  allowanceTarget?: Address;
  zid?: string;
}

/** What the transaction does, from its calldata. */
export interface Decoded {
  settler: Address;
  /** The token AllowanceHolder lets Settler take, the zero address for the native token. */
  token: Address;
  /** The most of it Settler can take. */
  amount: bigint;
  value: bigint;
  recipient: Address;
  buyToken: Address;
  /** Settler reverts unless the recipient ends with at least this. */
  minAmountOut: bigint;
}

export interface QuoteReport {
  ok: boolean;
  checks: Check[];
  quote?: Quote;
  decoded?: Decoded;
}

const same = (a: string | undefined, b: string | undefined) => a !== undefined && b !== undefined && a.toLowerCase() === b.toLowerCase();
const short = (value: string) => `${value.slice(0, 6)}…${value.slice(-4)}`;

/**
 * Holds a quote's body and its transaction to the caller's intent. Every check
 * reads the calldata where it can, since the calldata is what gets signed:
 * the target is AllowanceHolder, and so is any spender the quote names; it
 * lets the Settler take at most the sold token and the caller's amount; the
 * Settler is the registry's current or previous one; the value pays only a
 * native sale; and Settler's own slippage check sends the bought token to the
 * caller's recipient, at least the caller's floor.
 */
export function checkQuote(body: unknown, intent: QuoteIntent, settlers: Settlers, status = 200): QuoteReport {
  const intended = intentCheck(intent);
  if (intended.status === "fail") return { ok: false, checks: [intended] };
  const report = checkBody(body, intent, settlers, status);
  return { ...report, checks: [intended, ...report.checks] };
}

/** The quote-intent check, which passes only for an intent the rest can hold a quote to. */
function intentCheck(intent: QuoteIntent): Check {
  const problem = intentProblem(intent);
  if (problem) return { name: "quote-intent", status: "fail", message: problem };
  const limit =
    intent.buyAmount !== undefined
      ? `buys exactly ${intent.buyAmount} for at most ${intent.maxSellAmount}`
      : `sells exactly ${intent.sellAmount} for at least ${intent.minBuyAmount}`;
  return { name: "quote-intent", status: "ok", message: `the intent ${limit} on chain ${intent.chainId}` };
}

/** The quote's own checks, for an intent quote-intent has passed; a Settlers read that failed fails quote-settler. */
function checkBody(body: unknown, intent: QuoteIntent, settlers: Settlers | Error, status: number): QuoteReport {
  const checks: Check[] = [];
  const add = (name: string, ok: boolean, message: string) => void checks.push({ name, status: ok ? "ok" : "fail", message });
  const done = (extra: Omit<QuoteReport, "ok" | "checks"> = {}): QuoteReport => ({ ok: checks.every((c) => c.status === "ok"), checks, ...extra });

  const record = (typeof body === "object" && body !== null ? body : {}) as Record<string, unknown>;
  if (status !== 200) {
    const name = typeof record.name === "string" ? record.name : undefined;
    const message = typeof record.message === "string" ? record.message : undefined;
    add("quote-response", false, `0x answered ${status}${name ? ` ${name}` : ""}${message ? `: ${clip(message)}` : ""}`);
    return done();
  }
  if (record.liquidityAvailable === false) {
    add("quote-response", false, "0x has no route for this trade right now (liquidityAvailable is false)");
    return done();
  }
  let quote: Quote;
  try {
    quote = readQuote(record);
  } catch (error) {
    add("quote-response", false, `the answer is not a quote with a transaction: ${(error as Error).message}`);
    return done();
  }
  const exactOut = intent.buyAmount !== undefined;
  add(
    "quote-response",
    quote.mode === (exactOut ? "exact-out" : "exact-in") && same(quote.sellToken, intent.sellToken) && same(quote.buyToken, intent.buyToken),
    quote.mode !== (exactOut ? "exact-out" : "exact-in")
      ? `0x answered an ${quote.mode} quote to an ${exactOut ? "exact-out" : "exact-in"} request`
      : !same(quote.sellToken, intent.sellToken) || !same(quote.buyToken, intent.buyToken)
        ? `the quote sells ${quote.sellToken} for ${quote.buyToken}, not ${intent.sellToken} for ${intent.buyToken}`
        : `an ${quote.mode} quote selling ${short(quote.sellToken)} for ${short(quote.buyToken)}`,
  );

  const holder = holderOf(intent)!;
  add(
    "quote-target",
    same(quote.transaction.to, holder),
    same(quote.transaction.to, holder)
      ? `the transaction calls AllowanceHolder ${short(holder)}`
      : `the transaction calls ${quote.transaction.to}, not AllowanceHolder ${holder}. Never send it, and never approve that address`,
  );
  const named = [
    ["issues.allowance.spender", quote.spender],
    ["allowanceTarget", quote.allowanceTarget],
  ].filter((entry): entry is [string, Address] => entry[1] !== undefined);
  const wrongSpender = named.find(([, address]) => !same(address, holder));
  add(
    "quote-spender",
    wrongSpender === undefined,
    wrongSpender
      ? `it names ${wrongSpender[1]} as ${wrongSpender[0]}, not AllowanceHolder ${holder}. Never approve that address`
      : quote.spender !== undefined
        ? "the approval it asks for is to AllowanceHolder"
        : named.length > 0
          ? "it names AllowanceHolder for approvals and asks for none"
          : "it asks for no approval",
  );

  let decoded: Decoded;
  try {
    decoded = decode(quote.transaction);
  } catch (error) {
    add("quote-exec", false, `the calldata is not AllowanceHolder's exec around Settler's execute: ${(error as Error).message}`);
    return done({ quote });
  }
  const native = same(intent.sellToken, NATIVE);
  const soldToken = native ? zeroAddress : intent.sellToken;
  const ceiling = exactOut ? intent.maxSellAmount! : intent.sellAmount!;
  const sells = exactOut ? `at most ${ceiling}` : `${ceiling}`;
  const execOk = same(decoded.token, soldToken) && (exactOut ? decoded.amount <= ceiling && decoded.amount === quote.maxSellAmount : decoded.amount === ceiling);
  add(
    "quote-exec",
    execOk,
    execOk
      ? `AllowanceHolder lets the Settler take ${decoded.amount} of ${native ? "the native token" : short(decoded.token)} and no more`
      : !same(decoded.token, soldToken)
        ? `the calldata lets the Settler take ${decoded.token}, not the ${native ? "native token" : `token sold, ${intent.sellToken}`}`
        : exactOut && decoded.amount !== quote.maxSellAmount
          ? `the calldata lets the Settler take ${decoded.amount}, not the ${quote.maxSellAmount} maxSellAmount the quote states`
          : `the calldata lets the Settler take ${decoded.amount}, where the caller sells ${sells}`,
  );

  if (settlers instanceof Error) {
    add("quote-settler", false, `0x's registry ${SETTLER_REGISTRY} could not be read on chain ${intent.chainId}, so Settler ${decoded.settler} was not checked: ${clip(settlers.message)}`);
  } else {
    const genuine = same(decoded.settler, settlers.current) || same(decoded.settler, settlers.previous);
    add(
      "quote-settler",
      genuine,
      genuine
        ? `Settler ${short(decoded.settler)} is the registry's ${same(decoded.settler, settlers.current) ? "current" : "previous"} Settler on chain ${intent.chainId}`
        : settlers.current === undefined
          ? `0x's registry ${SETTLER_REGISTRY} reverts for Settler ${TAKER_SETTLER} on chain ${intent.chainId}, which means 0x has paused it. Do not trade until it answers`
          : `Settler ${decoded.settler} is neither the registry's current Settler (${settlers.current}) nor the previous one${settlers.previous ? ` (${settlers.previous})` : ""} on chain ${intent.chainId}`,
    );
  }

  const value = native ? decoded.amount : 0n;
  add(
    "quote-value",
    decoded.value === value,
    decoded.value === value
      ? native
        ? `the transaction sends ${value} wei, the amount AllowanceHolder lets the Settler take`
        : "the transaction sends no ETH"
      : `the transaction sends ${decoded.value} wei, where it should send ${value}`,
  );

  const recipient = intent.recipient ?? intent.taker;
  add(
    "quote-recipient",
    same(decoded.recipient, recipient),
    same(decoded.recipient, recipient) ? `the Settler pays what is bought to ${short(recipient)}` : `the Settler pays what is bought to ${decoded.recipient}, not ${recipient}`,
  );
  add(
    "quote-buy-token",
    same(decoded.buyToken, intent.buyToken),
    same(decoded.buyToken, intent.buyToken) ? `it buys ${short(intent.buyToken)}` : `the Settler checks the amount of ${decoded.buyToken} bought, not of ${intent.buyToken}`,
  );
  const floor = maxOf(intent.minBuyAmount ?? 0n, intent.buyAmount ?? 0n);
  const stated = exactOut ? quote.buyAmount : quote.minBuyAmount;
  const minOk = decoded.minAmountOut >= floor && (stated === undefined || decoded.minAmountOut >= stated);
  add(
    "quote-min-out",
    minOk,
    minOk
      ? `the Settler reverts unless at least ${decoded.minAmountOut} is bought${floor > 0n ? `, at or above the ${floor} asked for` : ""}`
      : decoded.minAmountOut < floor
        ? `the Settler accepts as little as ${decoded.minAmountOut}, under the ${floor} asked for`
        : `the Settler accepts as little as ${decoded.minAmountOut}, under the ${stated} the quote states`,
  );
  if (intent.maxGasCost !== undefined) {
    const { gas, gasPrice } = quote.transaction;
    const cost = gas !== undefined && gasPrice !== undefined ? gas * gasPrice : undefined;
    add(
      "quote-gas",
      cost !== undefined && cost <= intent.maxGasCost,
      cost === undefined
        ? `the quote states no ${gas === undefined ? "gas" : "gasPrice"}, so its gas cost cannot be held to the ${intent.maxGasCost} wei asked for`
        : cost <= intent.maxGasCost
          ? `its gas, ${gas} at ${gasPrice} wei, comes to ${cost} wei, within the ${intent.maxGasCost} asked for`
          : `its gas, ${gas} at ${gasPrice} wei, comes to ${cost} wei, over the ${intent.maxGasCost} asked for`,
    );
  }
  return done({ quote, decoded });
}

export interface VerifyQuoteOptions extends SignatureOptions {
  /**
   * The chain's Settlers, or a reader for them, such as () => readSettlers(client, 4663).
   * A reader that throws fails quote-settler with its error.
   */
  settlers: Settlers | (() => Promise<Settlers>);
}

/**
 * A quote's signature, then the quote itself: the answer 0x gave to `url`
 * (an api.0x.org or gateway URL), as received. The quote is checked only once
 * the signature holds, since an unsigned body is anyone's word.
 */
export async function verifyQuote(response: SignedResponse, url: string | URL, intent: QuoteIntent, options: VerifyQuoteOptions): Promise<QuoteReport & { signature: SignatureReport }> {
  if (typeof options !== "object" || options === null || options.settlers === undefined) {
    throw new TypeError("verifyQuote needs options with settlers: the chain's Settlers, or a function that reads them, such as () => readSettlers(client, intent.chainId)");
  }
  const request = signedRequestOf(url);
  const signature = verifyResponse(response, request, options);
  const refuse = (...more: Check[]) => ({ ok: false, checks: [...signature.checks, ...more], signature });
  if (!signature.ok) return refuse();
  if (request.path !== GATEWAY_PATHS["swap-allowance-holder-quote"]) {
    return refuse({ name: "quote-response", status: "fail", message: `${request.path} gives a price, which carries no transaction; ask ${GATEWAY_PATHS["swap-allowance-holder-quote"]}` });
  }
  const intended = intentCheck(intent);
  if (intended.status === "fail") return refuse(intended);
  const queried = queryProblem(request.query, intent);
  const requested: Check = queried
    ? { name: "quote-request", status: "fail", message: queried }
    : { name: "quote-request", status: "ok", message: "the query 0x answered asks for this trade and nothing else" };
  if (queried) return refuse(intended, requested);
  let body: unknown;
  try {
    body = JSON.parse(Buffer.from(bytesOf(response.body)).toString("utf8"));
  } catch {
    return refuse(intended, requested, { name: "quote-response", status: "fail", message: "the body 0x signed is not JSON" });
  }
  let settlers: Settlers | Error;
  try {
    settlers = typeof options.settlers === "function" ? await options.settlers() : options.settlers;
  } catch (error) {
    settlers = error instanceof Error ? error : new Error(String(error));
  }
  const report = checkBody(body, intent, settlers, response.status);
  return { ...report, checks: [...signature.checks, intended, requested, ...report.checks], signature };
}

/**
 * Where the query 0x signed asks for more than, or other than, this trade. The
 * signature binds the answer to the query, and 0x reads every parameter in
 * it, so only the trade's own names pass: each once, with the intent's value.
 */
function queryProblem(query: string, intent: QuoteIntent): string | undefined {
  const address = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  const exact = (a: string, b: string) => a === b;
  const wanted = new Map<string, { value: string; compare: (a: string, b: string) => boolean; required: boolean }>();
  const want = (name: string, value: string, compare = exact, required = true) => void wanted.set(name, { value, compare, required });
  want("chainId", String(intent.chainId));
  want("sellToken", intent.sellToken, address);
  want("buyToken", intent.buyToken, address);
  want("taker", intent.taker, address);
  if (intent.sellAmount !== undefined) want("sellAmount", intent.sellAmount.toString());
  if (intent.buyAmount !== undefined) want("buyAmount", intent.buyAmount.toString());
  // Without a recipient 0x pays the taker, so the query needs one only for someone else.
  if (intent.recipient !== undefined) want("recipient", intent.recipient, address, !same(intent.recipient, intent.taker));
  if (intent.slippageBps !== undefined) want("slippageBps", String(intent.slippageBps));

  const wrong: string[] = [];
  const seen = new Set<string>();
  const raw = query.startsWith("?") ? query.slice(1) : query;
  for (const part of raw === "" ? [] : raw.split("&")) {
    const at = part.indexOf("=");
    const name = at < 0 ? part : part.slice(0, at);
    const value = at < 0 ? undefined : part.slice(at + 1);
    // 0x decodes %XX and + before it reads a parameter, so an encoded part could name one this check would not see.
    if (/[%+]/.test(part)) wrong.push(`${clip(part)} is encoded, which this check does not decode`);
    else if (!wanted.has(name)) wrong.push(`${clip(name) || "an empty name"} is not part of this trade`);
    else if (seen.has(name)) wrong.push(`${name} is given more than once`);
    else {
      seen.add(name);
      const { value: meant, compare } = wanted.get(name)!;
      if (value === undefined || !compare(value, meant)) wrong.push(`${name}=${clip(value ?? "")} where ${meant} was meant`);
    }
  }
  for (const [name, { value, required }] of wanted) if (required && !seen.has(name)) wrong.push(`${name}=(none) where ${value} was meant`);
  return wrong.length > 0 ? `the request 0x answered is not this trade: ${wrong.join("; ")}` : undefined;
}

/** The AllowanceHolder the quote must call: the pinned one, or the intent's on a chain with none pinned. */
function holderOf(intent: QuoteIntent): Address | undefined {
  return Object.hasOwn(ALLOWANCE_HOLDER, intent.chainId) ? ALLOWANCE_HOLDER[intent.chainId] : intent.allowanceHolder;
}

function intentProblem(intent: QuoteIntent): string | undefined {
  if (typeof intent !== "object" || intent === null) return "the intent is not an object";
  for (const name of ["sellAmount", "buyAmount", "maxSellAmount", "minBuyAmount", "maxGasCost"] as const) {
    const value: unknown = intent[name];
    if (value !== undefined && typeof value !== "bigint") return `the intent's ${name} must be a bigint, such as ${typeof value === "number" && Number.isSafeInteger(value) ? `${value}n` : "312500000000000000000000n"}, not a ${typeof value}`;
  }
  if (!Number.isSafeInteger(intent.chainId) || intent.chainId <= 0) return "the intent's chainId must be a positive whole number, such as 4663";
  if (intent.slippageBps !== undefined && typeof intent.slippageBps !== "number") return "the intent's slippageBps must be a number";
  const exactOut = intent.buyAmount !== undefined;
  if ((intent.sellAmount === undefined) === !exactOut) return "the intent needs exactly one of sellAmount (exact in) and buyAmount (exact out)";
  if ((intent.sellAmount ?? intent.buyAmount)! <= 0n) return `the intent's ${exactOut ? "buyAmount" : "sellAmount"} must be above zero`;
  if (!exactOut && intent.maxSellAmount !== undefined) return "maxSellAmount goes with buyAmount, on an exact-out quote";
  // Settler pays the recipient exactly the minimum on exact out, so what AllowanceHolder lets it take is all that bounds the spend.
  if (exactOut && intent.maxSellAmount === undefined) return "an exact-out intent needs maxSellAmount, the most the caller sells, since the quote's own ceiling is 0x's";
  if (!exactOut && intent.minBuyAmount === undefined) return "an exact-in intent needs minBuyAmount, the least the caller takes, since the quote's own floor is 0x's";
  if (intent.slippageBps !== undefined && !(Number.isInteger(intent.slippageBps) && intent.slippageBps >= 0 && intent.slippageBps <= 10_000)) {
    return "the intent's slippageBps must be a whole number from 0 to 10000";
  }
  if (intent.maxGasCost !== undefined && intent.maxGasCost < 0n) return "the intent's maxGasCost must not be below zero";
  for (const [name, value] of [["taker", intent.taker], ["recipient", intent.recipient], ["sellToken", intent.sellToken], ["buyToken", intent.buyToken], ["allowanceHolder", intent.allowanceHolder]] as const) {
    if (value !== undefined && !isAddress(value, { strict: false })) return `the intent's ${name} is not an address`;
  }
  if (same(intent.sellToken, intent.buyToken)) return "the intent sells and buys the same token";
  const pinned = Object.hasOwn(ALLOWANCE_HOLDER, intent.chainId) ? ALLOWANCE_HOLDER[intent.chainId] : undefined;
  if (pinned !== undefined && intent.allowanceHolder !== undefined && !same(pinned, intent.allowanceHolder)) {
    return `AllowanceHolder on chain ${intent.chainId} is ${pinned}, not the ${intent.allowanceHolder} the intent names`;
  }
  if (holderOf(intent) === undefined) return `this check does not know AllowanceHolder on chain ${intent.chainId}; pass allowanceHolder from 0x's contracts page`;
  return undefined;
}

function readQuote(record: Record<string, unknown>): Quote {
  const amount = (name: string): bigint => {
    const value = record[name];
    if (value === undefined || value === null) throw new Error(`it has no ${name}`);
    if (typeof value !== "string" || !/^\d{1,78}$/.test(value)) throw new Error(`its ${name} is not a whole number`);
    return BigInt(value);
  };
  const address = (value: unknown, name: string): Address => {
    if (typeof value !== "string" || !isAddress(value, { strict: false })) throw new Error(`its ${name} is not an address`);
    return getAddress(value);
  };
  const mode = record.mode;
  if (mode !== "exact-in" && mode !== "exact-out") throw new Error(`its mode is ${JSON.stringify(mode)}`);
  const tx = record.transaction as Record<string, unknown> | undefined;
  if (typeof tx !== "object" || tx === null) throw new Error("it has no transaction; a price never does, so ask the quote endpoint with a taker");
  if (typeof tx.data !== "string" || !/^0x([0-9a-fA-F]{2})*$/.test(tx.data)) throw new Error("its transaction has no calldata");
  const whole = (value: unknown, name: string): bigint => {
    if (typeof value !== "string" || !/^\d{1,78}$/.test(value)) throw new Error(`its transaction's ${name} is not a whole number`);
    return BigInt(value);
  };
  const issues = record.issues as { allowance?: { spender?: unknown } | null } | undefined;
  const spender = issues?.allowance?.spender;
  const target = record.allowanceTarget;
  const exactOut = mode === "exact-out";
  return {
    mode,
    sellToken: address(record.sellToken, "sellToken"),
    buyToken: address(record.buyToken, "buyToken"),
    ...(exactOut ? { maxSellAmount: amount("maxSellAmount") } : { sellAmount: amount("sellAmount"), minBuyAmount: amount("minBuyAmount") }),
    ...(exactOut && record.estimatedNetSellAmount !== undefined ? { estimatedNetSellAmount: amount("estimatedNetSellAmount") } : {}),
    buyAmount: amount("buyAmount"),
    transaction: {
      to: address(tx.to, "transaction.to"),
      data: tx.data as Hex,
      value: whole(tx.value ?? "0", "value"),
      ...(tx.gas !== undefined && tx.gas !== null ? { gas: whole(tx.gas, "gas") } : {}),
      ...(tx.gasPrice !== undefined && tx.gasPrice !== null ? { gasPrice: whole(tx.gasPrice, "gasPrice") } : {}),
    },
    ...(spender !== undefined && spender !== null ? { spender: address(spender, "issues.allowance.spender") } : {}),
    ...(target !== undefined && target !== null ? { allowanceTarget: address(target, "allowanceTarget") } : {}),
    ...(typeof record.zid === "string" ? { zid: record.zid } : {}),
  };
}

/** AllowanceHolder's exec, and inside it the Settler's execute, as the transaction would run them. */
export function decode(transaction: Pick<Quote["transaction"], "data" | "value">): Decoded {
  const outer = decodeFunctionData({ abi: allowanceHolderAbi, data: transaction.data });
  // The decoder ignores bytes past the arguments and the unused high bytes of an address, and the contracts may not.
  if (!same(encodeFunctionData({ abi: allowanceHolderAbi, functionName: "exec", args: outer.args }), transaction.data)) {
    throw new Error("exec's arguments are not in the standard encoding: an address word carries extra bits, or bytes follow the arguments");
  }
  const [operator, token, amount, target, data] = outer.args;
  if (!same(operator, target)) throw new Error(`exec names ${operator} as operator and ${target} as target, where both are the Settler`);
  const inner = decodeFunctionData({ abi: settlerAbi, data });
  if (!same(encodeFunctionData({ abi: settlerAbi, functionName: "execute", args: inner.args }), data)) {
    throw new Error("execute's arguments are not in the standard encoding: an address word carries extra bits, or bytes follow the arguments");
  }
  const [slippage] = inner.args;
  return {
    settler: getAddress(target),
    token: getAddress(token),
    amount,
    value: transaction.value,
    recipient: getAddress(slippage.recipient),
    buyToken: getAddress(slippage.buyToken),
    minAmountOut: slippage.minAmountOut,
  };
}

const maxOf = (a: bigint, b: bigint) => (a > b ? a : b);
const clip = (text: string) => text.replace(/[\p{Cc}\p{Cf}]/gu, "?").slice(0, 200);

function headerOf(headers: SignedResponse["headers"], name: string): string | undefined {
  if (typeof (headers as Headers).get === "function") return (headers as Headers).get(name) ?? undefined;
  const record = headers as Readonly<Record<string, string | undefined>>;
  const key = Object.keys(record).find((k) => k.toLowerCase() === name);
  return key === undefined ? undefined : record[key];
}

// RFC 8941 structured fields, as far as RFC 9421 signatures use them: a dictionary whose members are inner lists of
// strings or byte sequences, each with parameters of strings, integers, tokens or booleans.

/** A token is kept apart from a string, so that serializing it again gives back the field's own text. */
type Bare = string | number | boolean | Buffer | { token: string };
interface Item {
  value: Bare;
  params: [string, Bare][];
}
interface InnerList {
  items: Item[];
  params: [string, Bare][];
}

interface SignatureParams {
  components: { name: string; req: boolean }[];
  /** As serialized for the @signature-params line. */
  serialized: string;
  keyid?: string;
  created?: number;
  expires?: number;
  alg?: string;
  tag?: string;
}

function parseSignatureInput(field: string): SignatureParams {
  const member = parseDictionary(field).get("sig");
  if (member === undefined || !("items" in member)) throw new Error('Signature-Input has no inner list labelled "sig"');
  const components = member.items.map((item) => {
    if (typeof item.value !== "string") throw new Error("a covered component is not a string");
    const unknown = item.params.find(([name]) => name !== "req");
    if (unknown) throw new Error(`the component "${item.value}" has the parameter ${unknown[0]}, which 0x does not use`);
    return { name: item.value, req: item.params.some(([name, value]) => name === "req" && value === true) };
  });
  const param = (name: string) => member.params.find(([key]) => key === name)?.[1];
  const text = (name: string) => {
    const value = param(name);
    if (value !== undefined && typeof value !== "string") throw new Error(`the ${name} parameter is not a string`);
    return value;
  };
  const integer = (name: string) => {
    const value = param(name);
    if (value !== undefined && (typeof value !== "number" || !Number.isInteger(value))) throw new Error(`the ${name} parameter is not an integer`);
    return value;
  };
  const keyid = text("keyid");
  const alg = text("alg");
  const tag = text("tag");
  const created = integer("created");
  const expires = integer("expires");
  return {
    components,
    serialized: serializeInnerList(member),
    ...(keyid !== undefined ? { keyid } : {}),
    ...(alg !== undefined ? { alg } : {}),
    ...(tag !== undefined ? { tag } : {}),
    ...(created !== undefined ? { created } : {}),
    ...(expires !== undefined ? { expires } : {}),
  };
}

function parseSignature(field: string): Buffer {
  const member = parseDictionary(field).get("sig");
  if (member === undefined || "items" in member || !Buffer.isBuffer(member.value)) throw new Error('Signature has no byte sequence labelled "sig"');
  if (member.value.length !== 64) throw new Error(`the signature is ${member.value.length} bytes, where Ed25519 gives 64`);
  return member.value;
}

/** The sha-256 member of a Content-Digest field, base64. */
function sha256Of(field: string): string | undefined {
  try {
    const member = parseDictionary(field).get("sha-256");
    return member !== undefined && !("items" in member) && Buffer.isBuffer(member.value) ? member.value.toString("base64") : undefined;
  } catch {
    return undefined;
  }
}

function signatureBase(params: SignatureParams, request: SignedRequest, response: SignedResponse): string {
  const lines = params.components.map(({ name, req }) => {
    let value: string | undefined;
    if (req) {
      if (name === "@method") value = request.method.toUpperCase();
      else if (name === "@authority") value = request.authority.toLowerCase();
      else if (name === "@path") value = request.path;
      else if (name === "@query") value = request.query;
    } else if (name === "@status") value = String(response.status);
    else if (!name.startsWith("@")) value = headerOf(response.headers, name)?.trim();
    if (value === undefined) throw new Error(`the signature covers ${name}${req ? ";req" : ""}, which this check cannot rebuild from the request and response it has`);
    return `"${name}"${req ? ";req" : ""}: ${value}`;
  });
  return [...lines, `"@signature-params": ${params.serialized}`].join("\n");
}

function parseDictionary(field: string): Map<string, Item | InnerList> {
  const parser = { text: field, at: 0 };
  const members = new Map<string, Item | InnerList>();
  skip(parser, " \t");
  while (parser.at < parser.text.length) {
    const key = parseKey(parser);
    let member: Item | InnerList;
    if (parser.text[parser.at] === "=") {
      parser.at++;
      member = parser.text[parser.at] === "(" ? parseInnerList(parser) : { value: parseBare(parser), params: parseParams(parser) };
    } else {
      member = { value: true, params: parseParams(parser) };
    }
    members.set(key, member);
    skip(parser, " \t");
    if (parser.at >= parser.text.length) break;
    if (parser.text[parser.at] !== ",") throw new Error(`unexpected ${JSON.stringify(parser.text[parser.at])} at ${parser.at}`);
    parser.at++;
    skip(parser, " \t");
    if (parser.at >= parser.text.length) throw new Error("a trailing comma");
  }
  return members;
}

interface Parser {
  text: string;
  at: number;
}

function skip(p: Parser, chars: string): void {
  while (p.at < p.text.length && chars.includes(p.text[p.at]!)) p.at++;
}

function parseKey(p: Parser): string {
  const match = /^[a-z*][a-z0-9_\-.*]*/.exec(p.text.slice(p.at));
  if (!match) throw new Error(`a key was expected at ${p.at}`);
  p.at += match[0].length;
  return match[0];
}

function parseInnerList(p: Parser): InnerList {
  p.at++;
  const items: Item[] = [];
  for (;;) {
    skip(p, " ");
    if (p.text[p.at] === ")") {
      p.at++;
      return { items, params: parseParams(p) };
    }
    if (p.at >= p.text.length) throw new Error("an inner list that does not close");
    items.push({ value: parseBare(p), params: parseParams(p) });
    if (p.text[p.at] !== " " && p.text[p.at] !== ")") throw new Error(`unexpected ${JSON.stringify(p.text[p.at])} in an inner list`);
  }
}

function parseParams(p: Parser): [string, Bare][] {
  const params: [string, Bare][] = [];
  while (p.text[p.at] === ";") {
    p.at++;
    skip(p, " ");
    const key = parseKey(p);
    let value: Bare = true;
    if (p.text[p.at] === "=") {
      p.at++;
      value = parseBare(p);
    }
    params.push([key, value]);
  }
  return params;
}

function parseBare(p: Parser): Bare {
  const c = p.text[p.at];
  if (c === '"') {
    let out = "";
    for (p.at++; p.at < p.text.length; p.at++) {
      const ch = p.text[p.at]!;
      if (ch === "\\") {
        const next = p.text[++p.at];
        if (next !== '"' && next !== "\\") throw new Error("a bad escape in a string");
        out += next;
      } else if (ch === '"') {
        p.at++;
        return out;
      } else if (ch < " " || ch > "~") throw new Error("a string holds a character outside printable ASCII");
      else out += ch;
    }
    throw new Error("a string that does not close");
  }
  if (c === ":") {
    const end = p.text.indexOf(":", p.at + 1);
    if (end < 0) throw new Error("a byte sequence that does not close");
    const b64 = p.text.slice(p.at + 1, end);
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(b64)) throw new Error("a byte sequence that is not base64");
    p.at = end + 1;
    return Buffer.from(b64, "base64");
  }
  if (c === "?") {
    const bit = p.text[p.at + 1];
    if (bit !== "0" && bit !== "1") throw new Error("a bad boolean");
    p.at += 2;
    return bit === "1";
  }
  const number = /^-?\d{1,15}(\.\d{1,3})?/.exec(p.text.slice(p.at));
  if (number) {
    p.at += number[0].length;
    return Number(number[0]);
  }
  const token = /^[A-Za-z*][A-Za-z0-9!#$%&'*+\-.^_`|~:/]*/.exec(p.text.slice(p.at));
  if (token) {
    p.at += token[0].length;
    return { token: token[0] };
  }
  throw new Error(`a value was expected at ${p.at}`);
}

function serializeInnerList(list: InnerList): string {
  return `(${list.items.map((item) => serializeBare(item.value) + serializeParams(item.params)).join(" ")})${serializeParams(list.params)}`;
}

function serializeParams(params: [string, Bare][]): string {
  return params.map(([key, value]) => (value === true ? `;${key}` : `;${key}=${serializeBare(value)}`)).join("");
}

function serializeBare(value: Bare): string {
  if (typeof value === "string") return `"${value.replace(/[\\"]/g, (ch) => `\\${ch}`)}"`;
  if (typeof value === "number") return String(value);
  if (typeof value === "boolean") return value ? "?1" : "?0";
  if (Buffer.isBuffer(value)) return `:${value.toString("base64")}:`;
  return value.token;
}
