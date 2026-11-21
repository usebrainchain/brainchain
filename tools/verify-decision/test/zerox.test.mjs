import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { BaseError, ContractFunctionRevertedError, decodeFunctionData, encodeFunctionData, parseAbi } from "viem";

import { ACCEPT_SIGNATURE, checkQuote, decode, NATIVE, readSettlers, SETTLER_REGISTRY, signedRequestOf, verifyQuote, verifyResponse, ZEROX_KEYS } from "../dist/zerox.js";

// Recorded through 0x's keyless gateway on Robinhood Chain on 2026-11-21, for a throwaway taker that holds nothing.
const fixture = (name) => {
  const f = JSON.parse(readFileSync(new URL(`./fixtures/zerox/${name}.json`, import.meta.url), "utf8"));
  const body = Buffer.from(f.body, "base64");
  return { ...f, body, json: JSON.parse(body.toString("utf8")), created: Number(/created=(\d+)/.exec(f.headers["signature-input"])[1]) };
};
const EXACT_OUT_ETH = fixture("quote-exact-out-eth");
const EXACT_OUT_USDG = fixture("quote-exact-out-usdg");
const EXACT_IN_ETH = fixture("quote-exact-in-eth");
const PRICE = fixture("price-exact-in-usdg");
const REFUSED = fixture("quote-refused-stock");

const TAKER = "0x89261C04A9aEE508ab7091FA12CD417664634a7D";
const BRAIN = "0x42b96dbc55e79E930d866c1eE486A342366546BC";
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const STRANGER = "0x4444444444444444444444444444444444444444";
// The registry's answers on Robinhood Chain when the fixtures were recorded.
const SETTLERS = { current: "0xE8852602f84e04e284286d8Db01a41Edd0CCEFb0", previous: "0x24A4d86c8A76B00EE9566eD9C9Ff4f0c3Faf0da7" };
const STAKE = 312_500n * 10n ** 18n;

const at = (f, seconds = 1) => () => (f.created + seconds) * 1000;
const response = (f, changes = {}) => ({ status: f.status, headers: { ...f.headers, ...changes.headers }, body: changes.body ?? f.body });
const failed = (report) => report.checks.find((c) => c.status === "fail");
const intentFor = (f, extra = {}) => {
  const q = new URL(f.url).searchParams;
  return {
    chainId: Number(q.get("chainId")),
    taker: q.get("taker"),
    sellToken: q.get("sellToken"),
    buyToken: q.get("buyToken"),
    ...(q.has("sellAmount") ? { sellAmount: BigInt(q.get("sellAmount")) } : { buyAmount: BigInt(q.get("buyAmount")) }),
    ...extra,
  };
};
const digest = (body) => `sha-256=:${createHash("sha256").update(body).digest("base64")}:`;

const execAbi = parseAbi(["function exec(address operator, address token, uint256 amount, address target, bytes data) payable returns (bytes)"]);
const executeAbi = parseAbi(["function execute((address recipient, address buyToken, uint256 minAmountOut) slippage, bytes[] actions, bytes32 zid) payable returns (bool)"]);

/** The quote's body with its Settler call's slippage changed, re-encoded as the transaction would carry it. */
function withSlippage(body, change) {
  const outer = decodeFunctionData({ abi: execAbi, data: body.transaction.data });
  const inner = decodeFunctionData({ abi: executeAbi, data: outer.args[4] });
  const slippage = { ...inner.args[0], ...change };
  const data = encodeFunctionData({ abi: executeAbi, functionName: "execute", args: [slippage, inner.args[1], inner.args[2]] });
  return { ...body, transaction: { ...body.transaction, data: encodeFunctionData({ abi: execAbi, functionName: "exec", args: [...outer.args.slice(0, 4), data] }) } };
}

describe("the gateway's request as 0x signs it", () => {
  it("maps a gateway quote or price URL to the Swap API request it forwards, keeping the query as sent", () => {
    assert.deepEqual(signedRequestOf(EXACT_OUT_ETH.url), {
      method: "GET",
      authority: "api.0x.org",
      path: "/swap/allowance-holder/quote",
      query: new URL(EXACT_OUT_ETH.url).search,
    });
    assert.equal(signedRequestOf(PRICE.url).path, "/swap/allowance-holder/price");
    assert.equal(signedRequestOf("https://api.0x.org/swap/permit2/quote?chainId=1").path, "/swap/permit2/quote");
    assert.equal(signedRequestOf("https://api.0x.org/swap/allowance-holder/quote").query, "?");
  });

  it("refuses a URL that is not a 0x price or quote endpoint", () => {
    for (const url of [
      "http://api.0x.org/swap/allowance-holder/quote?x=1",
      "https://agent.api.0x.org/v1/x402/cross-chain-quotes/?x=1",
      "https://agent.api.0x.org/v2/x402/swap-allowance-holder-quote/",
      "https://agent.api.0x.org/v1/x402/swap-allowance-holder-quote/extra",
      "https://agent.api.0x.org.example.com/v1/x402/swap-allowance-holder-quote/",
    ]) {
      assert.throws(() => signedRequestOf(url), /not https|not a 0x Swap API/, url);
    }
  });
});

describe("0x's response signature", () => {
  it("verifies every recorded answer, quotes, a price and a refusal, with the key 0x publishes", () => {
    for (const f of [EXACT_OUT_ETH, EXACT_OUT_USDG, EXACT_IN_ETH, PRICE, REFUSED]) {
      const report = verifyResponse(response(f), signedRequestOf(f.url), { now: at(f) });
      assert.equal(report.ok, true, JSON.stringify(failed(report)));
      assert.equal(report.keyid, "0x-signing-key-prod-24092026");
      assert.deepEqual(report.checks.map((c) => c.name), ["zerox-signed", "zerox-key", "zerox-fresh", "zerox-covers", "zerox-digest", "zerox-signature"]);
    }
  });

  it("verifies through the api.0x.org URL of the same request too, since that is what 0x signed", () => {
    const api = `https://api.0x.org/swap/allowance-holder/quote${new URL(EXACT_OUT_ETH.url).search}`;
    assert.equal(verifyResponse(response(EXACT_OUT_ETH), signedRequestOf(api), { now: at(EXACT_OUT_ETH) }).ok, true);
  });

  it("asks for a signature without naming a key, which the refusal above was recorded with", () => {
    assert.equal(REFUSED.acceptSignature, ACCEPT_SIGNATURE);
    assert.doesNotMatch(ACCEPT_SIGNATURE, /keyid/);
  });

  it("fails a body changed after 0x signed it", () => {
    const body = Buffer.from(EXACT_OUT_ETH.body.toString().replace(EXACT_OUT_ETH.json.buyAmount, "1"));
    const report = verifyResponse(response(EXACT_OUT_ETH, { body }), signedRequestOf(EXACT_OUT_ETH.url), { now: at(EXACT_OUT_ETH) });
    assert.equal(failed(report).name, "zerox-digest");
  });

  it("fails a body whose Content-Digest was changed with it", () => {
    const body = Buffer.from(EXACT_OUT_ETH.body.toString().replace(EXACT_OUT_ETH.json.buyAmount, "1"));
    const report = verifyResponse(response(EXACT_OUT_ETH, { body, headers: { "content-digest": digest(body) } }), signedRequestOf(EXACT_OUT_ETH.url), { now: at(EXACT_OUT_ETH) });
    assert.equal(failed(report).name, "zerox-signature");
    assert.match(failed(report).message, /changed, or it answers another request/);
  });

  it("fails an answer held to another request: another amount, path or host", () => {
    const request = signedRequestOf(EXACT_OUT_ETH.url);
    for (const other of [
      { ...request, query: request.query.replace("312500000000000000000000", "312500000000000000000001") },
      { ...request, path: "/swap/allowance-holder/price" },
      { ...request, authority: "agent.api.0x.org" },
      { ...request, method: "POST" },
    ]) {
      assert.equal(failed(verifyResponse(response(EXACT_OUT_ETH), other, { now: at(EXACT_OUT_ETH) })).name, "zerox-signature");
    }
    const status = verifyResponse({ ...response(EXACT_OUT_ETH), status: 201 }, request, { now: at(EXACT_OUT_ETH) });
    assert.equal(failed(status).name, "zerox-signature");
  });

  it("fails a signature older than 60 seconds, or from more than 60 seconds ahead", () => {
    const request = signedRequestOf(EXACT_IN_ETH.url);
    assert.equal(verifyResponse(response(EXACT_IN_ETH), request, { now: at(EXACT_IN_ETH, 60) }).ok, true);
    const old = verifyResponse(response(EXACT_IN_ETH), request, { now: at(EXACT_IN_ETH, 61) });
    assert.equal(failed(old).name, "zerox-fresh");
    assert.match(failed(old).message, /signed 61 seconds ago, outside the 60 seconds/);
    const ahead = verifyResponse(response(EXACT_IN_ETH), request, { now: at(EXACT_IN_ETH, -61) });
    assert.match(failed(ahead).message, /61 seconds ahead of this clock/);
    assert.equal(verifyResponse(response(EXACT_IN_ETH), request, { now: at(EXACT_IN_ETH, 200), maxAgeSeconds: 300 }).ok, true);
  });

  it("picks the key by its id, so a set that still lists the key verifies, and one without it fails", () => {
    const rotated = [{ keyid: "0x-signing-key-prod-01012027", x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo" }, ...ZEROX_KEYS];
    assert.equal(verifyResponse(response(PRICE), signedRequestOf(PRICE.url), { now: at(PRICE), keys: rotated }).ok, true);
    const retired = verifyResponse(response(PRICE), signedRequestOf(PRICE.url), { now: at(PRICE), keys: rotated.slice(0, 1) });
    assert.equal(failed(retired).name, "zerox-key");
    assert.match(failed(retired).message, /not among the keys given \(0x-signing-key-prod-01012027\)/);
    // The id is what selects; the right id on the wrong key does not verify.
    const wrong = verifyResponse(response(PRICE), signedRequestOf(PRICE.url), { now: at(PRICE), keys: [{ ...ZEROX_KEYS[0], x: rotated[0].x }] });
    assert.equal(failed(wrong).name, "zerox-signature");
  });

  it("fails an answer 0x did not sign, and signature headers it cannot read", () => {
    const request = signedRequestOf(PRICE.url);
    const unsigned = verifyResponse(response(PRICE, { headers: { signature: undefined } }), request, { now: at(PRICE) });
    assert.match(failed(unsigned).message, /did not sign this response/);
    for (const input of ['sig=("@status"', "other=();keyid=\"x\"", 'sig=("@status");created=x']) {
      assert.equal(failed(verifyResponse(response(PRICE, { headers: { "signature-input": input } }), request, { now: at(PRICE) })).name, "zerox-signed", input);
    }
    const short = verifyResponse(response(PRICE, { headers: { signature: "sig=:AAAA:" } }), request, { now: at(PRICE) });
    assert.match(failed(short).message, /3 bytes, where Ed25519 gives 64/);
  });

  it("fails another algorithm or tag before it looks at the key", () => {
    const request = signedRequestOf(PRICE.url);
    for (const [from, to] of [['alg="ed25519"', 'alg="rsa-pss-sha512"'], ['tag="0x-swap-api"', 'tag="other"']]) {
      const input = PRICE.headers["signature-input"].replace(from, to);
      assert.equal(failed(verifyResponse(response(PRICE, { headers: { "signature-input": input } }), request, { now: at(PRICE) })).name, "zerox-signed");
    }
  });

  // A key of the test's own, to sign what 0x's key cannot be made to sign.
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const testKey = { keyid: "test", x: publicKey.export({ format: "jwk" }).x };
  const created = 1_800_000_000;
  const signed = (input, base, extra = {}) => {
    const body = Buffer.from('{"ok":true}');
    const signature = sign(null, Buffer.from(base), privateKey).toString("base64");
    return { status: 200, headers: { "content-type": "application/json", "content-digest": digest(body), "signature-input": input, signature: `sig=:${signature}:`, ...extra }, body };
  };
  const request = { method: "GET", authority: "api.0x.org", path: "/swap/allowance-holder/quote", query: "?a=1" };
  const lines = (body, contentDigest = digest(body)) => [`"@status": 200`, `"content-type": application/json`, `"content-digest": ${contentDigest}`, `"@method";req: GET`, `"@authority";req: api.0x.org`, `"@path";req: /swap/allowance-holder/quote`, `"@query";req: ?a=1`];

  it("rebuilds the signature parameters from the field, in any member order and with spaces RFC 8941 allows", () => {
    const params = '("@status" "content-type" "content-digest" "@method";req "@authority";req "@path";req "@query";req);created=1800000000;keyid="test";alg="ed25519";tag="0x-swap-api"';
    const both = `sha-512=:AAAA:, ${digest(Buffer.from('{"ok":true}'))}`;
    const base = [...lines(Buffer.from('{"ok":true}'), both), `"@signature-params": ${params}`].join("\n");
    const input = `other=("@status");keyid="else", sig=( "@status"  "content-type" "content-digest" "@method";req "@authority";req "@path";req "@query";req );created=1800000000;keyid="test";alg="ed25519";tag="0x-swap-api"`;
    const report = verifyResponse(signed(input, base, { "content-digest": both }), request, { keys: [testKey], now: () => created * 1000 });
    assert.equal(report.ok, true, JSON.stringify(failed(report)));
  });

  it("fails a signature that leaves out the query or the body's digest, however validly signed", () => {
    for (const leaveOut of ['"@query";req', '"content-digest"']) {
      const components = '"@status" "content-type" "content-digest" "@method";req "@authority";req "@path";req "@query";req'.replace(leaveOut, "").replace(/ +/g, " ").trim();
      const params = `(${components});created=${created};keyid="test";alg="ed25519";tag="0x-swap-api"`;
      const base = [...lines(Buffer.from('{"ok":true}')).filter((line) => !line.startsWith(leaveOut)), `"@signature-params": ${params}`].join("\n");
      const report = verifyResponse(signed(`sig=${params}`, base), request, { keys: [testKey], now: () => created * 1000 });
      assert.equal(failed(report).name, "zerox-covers");
    }
  });

  it("fails a signature past its expires time, and one that covers a header the response lacks", () => {
    const params = `("@status" "content-type" "content-digest" "@method";req "@authority";req "@path";req "@query";req "x-missing");created=${created};expires=${created + 5};keyid="test";alg="ed25519";tag="0x-swap-api"`;
    const base = [...lines(Buffer.from('{"ok":true}')), `"@signature-params": ${params}`].join("\n");
    assert.equal(failed(verifyResponse(signed(`sig=${params}`, base), request, { keys: [testKey], now: () => (created + 6) * 1000 })).name, "zerox-fresh");
    const report = verifyResponse(signed(`sig=${params}`, base), request, { keys: [testKey], now: () => created * 1000 });
    assert.match(failed(report).message, /covers x-missing, which this check cannot rebuild/);
  });
});

describe("the pinned keys", () => {
  it("are the only keys trusted, and a signature by any other says a newer version of the package is needed", () => {
    const { privateKey } = generateKeyPairSync("ed25519");
    const params = `("@status" "content-type" "content-digest" "@method";req "@authority";req "@path";req "@query";req);created=${PRICE.created};keyid="0x-signing-key-next";alg="ed25519";tag="0x-swap-api"`;
    const signature = sign(null, Buffer.from("anything"), privateKey).toString("base64");
    const report = verifyResponse(response(PRICE, { headers: { "signature-input": `sig=${params}`, signature: `sig=:${signature}:` } }), signedRequestOf(PRICE.url), { now: at(PRICE) });
    assert.equal(failed(report).name, "zerox-key");
    assert.equal(report.keyid, "0x-signing-key-next");
    assert.match(failed(report).message, /^signed with key 0x-signing-key-next, which this version of brainchain-verify does not carry \(it trusts 0x-signing-key-prod-24092026\)\. .*a newer version of brainchain-verify is needed/);
  });
});

describe("a quote held to the caller's intent", () => {
  it("passes the exact-out ETH quote for the 312,500 BRAIN a worker stakes, and reads what its calldata does", () => {
    const report = checkQuote(EXACT_OUT_ETH.json, intentFor(EXACT_OUT_ETH), SETTLERS);
    assert.equal(report.ok, true, JSON.stringify(failed(report)));
    assert.deepEqual(report.checks.map((c) => c.name), ["quote-response", "quote-target", "quote-exec", "quote-settler", "quote-value", "quote-recipient", "quote-buy-token", "quote-min-out"]);
    assert.deepEqual(report.decoded, {
      settler: SETTLERS.current,
      token: "0x0000000000000000000000000000000000000000",
      amount: BigInt(EXACT_OUT_ETH.json.maxSellAmount),
      value: BigInt(EXACT_OUT_ETH.json.maxSellAmount),
      recipient: TAKER,
      buyToken: BRAIN,
      minAmountOut: STAKE,
    });
    assert.equal(report.quote.estimatedNetSellAmount, BigInt(EXACT_OUT_ETH.json.estimatedNetSellAmount));
  });

  it("passes the exact-out USDG quote, which asks for an approval to AllowanceHolder and sends no ETH", () => {
    const report = checkQuote(EXACT_OUT_USDG.json, intentFor(EXACT_OUT_USDG, { maxSellAmount: 140_000_000n }), SETTLERS);
    assert.equal(report.ok, true, JSON.stringify(failed(report)));
    assert.ok(report.checks.some((c) => c.name === "quote-spender" && c.status === "ok"));
    assert.equal(report.decoded.token, USDG);
    assert.equal(report.decoded.value, 0n);
  });

  it("holds an exact-in quote's floor to the caller's", () => {
    const floor = BigInt(EXACT_IN_ETH.json.minBuyAmount);
    assert.equal(checkQuote(EXACT_IN_ETH.json, intentFor(EXACT_IN_ETH, { minBuyAmount: floor }), SETTLERS).ok, true);
    const report = checkQuote(EXACT_IN_ETH.json, intentFor(EXACT_IN_ETH, { minBuyAmount: floor + 1n }), SETTLERS);
    assert.equal(failed(report).name, "quote-min-out");
    assert.match(failed(report).message, /accepts as little as \d+, under the \d+ asked for/);
  });

  it("fails a quote that takes more than the caller sells", () => {
    const report = checkQuote(EXACT_OUT_USDG.json, intentFor(EXACT_OUT_USDG, { maxSellAmount: 100_000_000n }), SETTLERS);
    assert.equal(failed(report).name, "quote-exec");
    assert.match(failed(report).message, /where the caller sells at most 100000000/);
    const inflated = { ...EXACT_IN_ETH.json, sellAmount: "1" };
    assert.equal(failed(checkQuote(inflated, intentFor(EXACT_IN_ETH, { sellAmount: 1n }), SETTLERS)).name, "quote-exec");
  });

  it("accepts the registry's previous Settler, and fails any other or a paused registry", () => {
    assert.equal(checkQuote(EXACT_OUT_ETH.json, intentFor(EXACT_OUT_ETH), { current: STRANGER, previous: SETTLERS.current }).ok, true);
    const counterfeit = checkQuote(EXACT_OUT_ETH.json, intentFor(EXACT_OUT_ETH), { current: STRANGER });
    assert.equal(failed(counterfeit).name, "quote-settler");
    assert.match(failed(counterfeit).message, /neither the registry's current Settler/);
    const paused = checkQuote(EXACT_OUT_ETH.json, intentFor(EXACT_OUT_ETH), {});
    assert.match(failed(paused).message, /0x has paused it/);
  });

  it("fails a transaction to anything but AllowanceHolder, an approval to anything else, and a value that does not match", () => {
    const target = checkQuote({ ...EXACT_OUT_ETH.json, transaction: { ...EXACT_OUT_ETH.json.transaction, to: SETTLERS.current } }, intentFor(EXACT_OUT_ETH), SETTLERS);
    assert.equal(failed(target).name, "quote-target");
    assert.match(failed(target).message, /Never send it/);
    const spender = checkQuote({ ...EXACT_OUT_USDG.json, issues: { ...EXACT_OUT_USDG.json.issues, allowance: { actual: "0", spender: SETTLERS.current } } }, intentFor(EXACT_OUT_USDG), SETTLERS);
    assert.equal(failed(spender).name, "quote-spender");
    const value = checkQuote({ ...EXACT_OUT_ETH.json, transaction: { ...EXACT_OUT_ETH.json.transaction, value: "1" } }, intentFor(EXACT_OUT_ETH), SETTLERS);
    assert.equal(failed(value).name, "quote-value");
  });

  it("reads the recipient, the token bought and the floor from the Settler's calldata, not from the quote's fields", () => {
    const intent = intentFor(EXACT_OUT_ETH);
    const elsewhere = checkQuote(withSlippage(EXACT_OUT_ETH.json, { recipient: STRANGER }), intent, SETTLERS);
    assert.equal(failed(elsewhere).name, "quote-recipient");
    const other = checkQuote(withSlippage(EXACT_OUT_ETH.json, { buyToken: USDG }), intent, SETTLERS);
    assert.equal(failed(other).name, "quote-buy-token");
    const less = checkQuote(withSlippage(EXACT_OUT_ETH.json, { minAmountOut: STAKE - 1n }), intent, SETTLERS);
    assert.equal(failed(less).name, "quote-min-out");
    assert.equal(checkQuote(EXACT_OUT_ETH.json, { ...intent, taker: STRANGER }, SETTLERS).checks.find((c) => c.name === "quote-recipient").status, "fail");
  });

  it("fails a refusal, a price and an answer with no route, saying what 0x said", () => {
    const refused = checkQuote(REFUSED.json, intentFor(REFUSED), SETTLERS, REFUSED.status);
    assert.match(failed(refused).message, /^0x answered 422 BUY_TOKEN_NOT_AUTHORIZED_FOR_TRADE: The buy token is not authorized for trade/);
    assert.match(failed(checkQuote(PRICE.json, { ...intentFor(PRICE), taker: TAKER }, SETTLERS)).message, /a price never does/);
    assert.match(failed(checkQuote({ liquidityAvailable: false, zid: "0x1" }, intentFor(EXACT_IN_ETH), SETTLERS)).message, /no route/);
  });

  it("refuses an intent it cannot hold a quote to", () => {
    const base = intentFor(EXACT_IN_ETH);
    for (const [intent, message] of [
      [{ ...base, buyAmount: 1n }, /exactly one of sellAmount/],
      [{ ...base, maxSellAmount: 1n }, /goes with buyAmount/],
      [{ ...base, buyToken: NATIVE }, /same token/],
      [{ ...base, chainId: 10 }, /does not know AllowanceHolder on chain 10/],
      [{ ...base, taker: "0x12" }, /taker is not an address/],
    ]) {
      assert.match(failed(checkQuote(EXACT_IN_ETH.json, intent, SETTLERS)).message, message);
    }
  });

  it("decodes AllowanceHolder's exec and refuses one whose operator is not its target", () => {
    assert.equal(decode(EXACT_IN_ETH.json.transaction).settler, SETTLERS.current);
    const outer = decodeFunctionData({ abi: execAbi, data: EXACT_IN_ETH.json.transaction.data });
    const data = encodeFunctionData({ abi: execAbi, functionName: "exec", args: [STRANGER, ...outer.args.slice(1)] });
    assert.throws(() => decode({ data, value: 0n }), /operator/);
  });
});

describe("verifyQuote", () => {
  it("checks the signature, the request 0x answered and the quote, reading the Settlers once the signature holds", async () => {
    let reads = 0;
    const settlers = async () => {
      reads += 1;
      return SETTLERS;
    };
    const report = await verifyQuote(response(EXACT_OUT_ETH), EXACT_OUT_ETH.url, intentFor(EXACT_OUT_ETH), { settlers, now: at(EXACT_OUT_ETH) });
    assert.equal(report.ok, true, JSON.stringify(failed(report)));
    assert.equal(reads, 1);
    assert.equal(report.checks.length, 14);

    const stale = await verifyQuote(response(EXACT_OUT_ETH), EXACT_OUT_ETH.url, intentFor(EXACT_OUT_ETH), { settlers, now: at(EXACT_OUT_ETH, 90) });
    assert.equal(failed(stale).name, "zerox-fresh");
    assert.equal(reads, 1);
  });

  it("fails a signed answer to another trade than the one intended", async () => {
    const report = await verifyQuote(response(EXACT_OUT_ETH), EXACT_OUT_ETH.url, intentFor(EXACT_OUT_ETH, { buyAmount: STAKE + 1n }), { settlers: SETTLERS, now: at(EXACT_OUT_ETH) });
    assert.equal(failed(report).name, "quote-request");
    assert.match(failed(report).message, /buyAmount=312500000000000000000000 where 312500000000000000000001 was meant/);
    const taker = await verifyQuote(response(EXACT_OUT_ETH), EXACT_OUT_ETH.url, intentFor(EXACT_OUT_ETH, { taker: STRANGER }), { settlers: SETTLERS, now: at(EXACT_OUT_ETH) });
    assert.match(failed(taker).message, /taker=0x89261C04A9aEE508ab7091FA12CD417664634a7D where 0x4444/);
  });

  it("fails a signed price, which can never be sent", async () => {
    const report = await verifyQuote(response(PRICE), PRICE.url, { ...intentFor(PRICE), taker: TAKER }, { settlers: SETTLERS, now: at(PRICE) });
    assert.match(failed(report).message, /gives a price, which carries no transaction/);
  });
});

describe("readSettlers", () => {
  const client = (answers) => ({
    async readContract({ address, functionName, args }) {
      assert.equal(address, SETTLER_REGISTRY);
      assert.equal(args[0], 2n);
      const answer = answers[functionName];
      if (answer instanceof Error) throw answer;
      return answer;
    },
  });
  const revert = () => new BaseError("reverted", { cause: new ContractFunctionRevertedError({ abi: [], functionName: "ownerOf" }) });

  it("reads the current and previous Settler for taker-sent swaps", async () => {
    assert.deepEqual(await readSettlers(client({ ownerOf: SETTLERS.current, prev: SETTLERS.previous })), SETTLERS);
    assert.deepEqual(await readSettlers(client({ ownerOf: SETTLERS.current, prev: "0x0000000000000000000000000000000000000000" })), { current: SETTLERS.current });
  });

  it("takes a revert as paused and lets an RPC failure throw", async () => {
    assert.deepEqual(await readSettlers(client({ ownerOf: revert(), prev: SETTLERS.previous })), { previous: SETTLERS.previous });
    await assert.rejects(readSettlers(client({ ownerOf: new Error("fetch failed"), prev: SETTLERS.previous })), /fetch failed/);
  });
});
