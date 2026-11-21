import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { BaseError, ContractFunctionRevertedError, decodeFunctionData, encodeFunctionData, parseAbi } from "viem";

import { ACCEPT_SIGNATURE, checkQuote, decode, NATIVE, readSettlers, SETTLER_REGISTRY, signedRequestOf, verifyQuote, verifyResponse, ZEROX_KEYS } from "../dist/zerox.js";

// Recorded on Robinhood Chain on 2026-11-21, for a throwaway taker that holds nothing: through 0x's keyless gateway,
// and the exact-in USDG quotes from the Swap API directly.
const fixture = (name) => {
  const f = JSON.parse(readFileSync(new URL(`./fixtures/zerox/${name}.json`, import.meta.url), "utf8"));
  const body = Buffer.from(f.body, "base64");
  return { ...f, body, json: JSON.parse(body.toString("utf8")), created: Number(/created=(\d+)/.exec(f.headers["signature-input"])[1]) };
};
const EXACT_OUT_ETH = fixture("quote-exact-out-eth");
const EXACT_OUT_USDG = fixture("quote-exact-out-usdg");
const EXACT_IN_ETH = fixture("quote-exact-in-eth");
const EXACT_IN_USDG = fixture("quote-exact-in-usdg");
const USDG_FOR_ETH = fixture("quote-exact-in-usdg-eth");
const PRICE = fixture("price-exact-in-usdg");
const REFUSED = fixture("quote-refused-stock");

const TAKER = "0x89261C04A9aEE508ab7091FA12CD417664634a7D";
const BRAIN = "0x42b96dbc55e79E930d866c1eE486A342366546BC";
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const STRANGER = "0x4444444444444444444444444444444444444444";
const HOLDER = "0x0000000000001fF3684f28c67538d4D072C22734";
// The registry's answers on Robinhood Chain when the fixtures were recorded.
const SETTLERS = { current: "0xE8852602f84e04e284286d8Db01a41Edd0CCEFb0", previous: "0x24A4d86c8A76B00EE9566eD9C9Ff4f0c3Faf0da7" };
const STAKE = 312_500n * 10n ** 18n;

const at = (f, seconds = 1) => () => (f.created + seconds) * 1000;
const response = (f, changes = {}) => ({ status: f.status, headers: { ...f.headers, ...changes.headers }, body: changes.body ?? f.body });
const failed = (report) => report.checks.find((c) => c.status === "fail");
/** The trade the fixture asked for, held to the quote's own limits unless `extra` says otherwise. */
const intentFor = (f, extra = {}) => {
  const q = new URL(f.url).searchParams;
  return {
    chainId: Number(q.get("chainId")),
    taker: q.get("taker"),
    sellToken: q.get("sellToken"),
    buyToken: q.get("buyToken"),
    ...(q.has("sellAmount")
      ? { sellAmount: BigInt(q.get("sellAmount")), ...(f.json?.minBuyAmount ? { minBuyAmount: BigInt(f.json.minBuyAmount) } : {}) }
      : { buyAmount: BigInt(q.get("buyAmount")), ...(f.json?.maxSellAmount ? { maxSellAmount: BigInt(f.json.maxSellAmount) } : {}) }),
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
    for (const f of [EXACT_OUT_ETH, EXACT_OUT_USDG, EXACT_IN_ETH, EXACT_IN_USDG, USDG_FOR_ETH, PRICE, REFUSED]) {
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

  it("asks for a signature without naming a key, which the refusal and the direct quotes were recorded with", () => {
    for (const f of [REFUSED, EXACT_IN_USDG, USDG_FOR_ETH]) assert.equal(f.acceptSignature, ACCEPT_SIGNATURE);
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
    assert.deepEqual(report.checks.map((c) => c.name), ["quote-intent", "quote-response", "quote-target", "quote-spender", "quote-exec", "quote-settler", "quote-value", "quote-recipient", "quote-buy-token", "quote-min-out"]);
    assert.equal(report.checks[0].message, `the intent buys exactly ${STAKE} for at most ${EXACT_OUT_ETH.json.maxSellAmount} on chain 4663`);
    assert.equal(report.checks[3].message, "it names AllowanceHolder for approvals and asks for none");
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

  it("passes an exact-in USDG quote, whose approval and allowance target are AllowanceHolder, and reports 0x's gas price", () => {
    const report = checkQuote(EXACT_IN_USDG.json, intentFor(EXACT_IN_USDG), SETTLERS);
    assert.equal(report.ok, true, JSON.stringify(failed(report)));
    assert.equal(report.checks.find((c) => c.name === "quote-spender").message, "the approval it asks for is to AllowanceHolder");
    assert.equal(report.quote.allowanceTarget, HOLDER);
    assert.equal(report.decoded.token, USDG);
    assert.equal(report.decoded.amount, 10_000_000n);
    assert.equal(report.decoded.value, 0n);
    assert.equal(report.decoded.minAmountOut, BigInt(EXACT_IN_USDG.json.minBuyAmount));
    assert.equal(report.quote.transaction.gasPrice, BigInt(EXACT_IN_USDG.json.transaction.gasPrice));
  });

  it("passes a quote that buys the native token, which the Settler counts under the Swap API's own name for it", () => {
    const report = checkQuote(USDG_FOR_ETH.json, intentFor(USDG_FOR_ETH), SETTLERS);
    assert.equal(report.ok, true, JSON.stringify(failed(report)));
    assert.equal(report.decoded.buyToken, NATIVE);
    assert.equal(report.decoded.recipient, TAKER);
    assert.equal(report.decoded.token, USDG);
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
    const refused = checkQuote(REFUSED.json, intentFor(REFUSED, { minBuyAmount: 1n }), SETTLERS, REFUSED.status);
    assert.match(failed(refused).message, /^0x answered 422 BUY_TOKEN_NOT_AUTHORIZED_FOR_TRADE: The buy token is not authorized for trade/);
    assert.match(failed(checkQuote(PRICE.json, { ...intentFor(PRICE), taker: TAKER }, SETTLERS)).message, /a price never does/);
    assert.match(failed(checkQuote({ liquidityAvailable: false, zid: "0x1" }, intentFor(EXACT_IN_ETH), SETTLERS)).message, /no route/);
  });

  it("refuses an intent it cannot hold a quote to", () => {
    const base = intentFor(EXACT_IN_ETH);
    const out = intentFor(EXACT_OUT_ETH);
    for (const [intent, message] of [
      [{ ...base, buyAmount: 1n }, /exactly one of sellAmount/],
      [{ ...base, maxSellAmount: 1n }, /goes with buyAmount/],
      [{ ...base, sellAmount: 0n }, /sellAmount must be above zero/],
      [{ ...base, minBuyAmount: undefined }, /exact-in intent needs minBuyAmount/],
      [{ ...out, maxSellAmount: undefined }, /exact-out intent needs maxSellAmount/],
      [{ ...base, slippageBps: 1.5 }, /slippageBps must be a whole number from 0 to 10000/],
      [{ ...base, maxGasCost: -1n }, /maxGasCost must not be below zero/],
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
    assert.deepEqual(report.checks.slice(6, 8).map((c) => [c.name, c.status]), [["quote-intent", "ok"], ["quote-request", "ok"]]);
    assert.equal(report.checks.length, 17);

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
  const client = (answers, chainId = 4663) => ({
    chain: { name: chainId === 4663 ? "Robinhood Chain" : "Base" },
    async getChainId() {
      return chainId;
    },
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
    assert.deepEqual(await readSettlers(client({ ownerOf: SETTLERS.current, prev: SETTLERS.previous }), 4663), SETTLERS);
    assert.deepEqual(await readSettlers(client({ ownerOf: SETTLERS.current, prev: "0x0000000000000000000000000000000000000000" }), 4663), { current: SETTLERS.current });
  });

  it("takes a revert as paused and lets an RPC failure throw", async () => {
    assert.deepEqual(await readSettlers(client({ ownerOf: revert(), prev: SETTLERS.previous }), 4663), { previous: SETTLERS.previous });
    await assert.rejects(readSettlers(client({ ownerOf: new Error("fetch failed"), prev: SETTLERS.previous }), 4663), /fetch failed/);
  });

  it("refuses a client on another chain than the quote's, naming both", async () => {
    await assert.rejects(readSettlers(client({ ownerOf: SETTLERS.current, prev: SETTLERS.previous }, 8453), 4663), /^Error: the client reads chain 8453 \(Base\), not chain 4663, which the quote is for$/);
  });
});

describe("what a quote may not carry", () => {
  // 0x signs whatever query it is sent, so a key of the test's own stands in for 0x's to sign any request.
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const keys = [{ keyid: "test", x: publicKey.export({ format: "jwk" }).x }];
  const created = 1_900_000_000;
  const options = { keys, now: () => (created + 1) * 1000, settlers: SETTLERS };
  const answer = (url, json) => {
    const body = Buffer.from(JSON.stringify(json));
    const { path, query } = signedRequestOf(url);
    const params = `("@status" "content-type" "content-digest" "@method";req "@authority";req "@path";req "@query";req);created=${created};keyid="test";alg="ed25519";tag="0x-swap-api"`;
    const base = [`"@status": 200`, `"content-type": application/json`, `"content-digest": ${digest(body)}`, `"@method";req: GET`, `"@authority";req: api.0x.org`, `"@path";req: ${path}`, `"@query";req: ${query}`, `"@signature-params": ${params}`].join("\n");
    const signature = sign(null, Buffer.from(base), privateKey).toString("base64");
    return { status: 200, headers: { "content-type": "application/json", "content-digest": digest(body), "signature-input": `sig=${params}`, signature: `sig=:${signature}:` }, body };
  };
  const rewrite = (body, amount) => {
    const outer = decodeFunctionData({ abi: execAbi, data: body.transaction.data });
    const data = encodeFunctionData({ abi: execAbi, functionName: "exec", args: [outer.args[0], outer.args[1], amount, outer.args[3], outer.args[4]] });
    return { ...body, transaction: { ...body.transaction, data } };
  };

  it("passes the trade's own query signed by the stand-in key, so what follows fails on the query alone", async () => {
    const report = await verifyQuote(answer(EXACT_IN_ETH.url, EXACT_IN_ETH.json), EXACT_IN_ETH.url, intentFor(EXACT_IN_ETH), options);
    assert.equal(report.ok, true, JSON.stringify(failed(report)));
  });

  it("refuses parameters the trade did not ask for: slippage, fees, surplus and gas price for someone else", async () => {
    const url = `${EXACT_IN_ETH.url}&slippageBps=10000&swapFeeRecipient=${STRANGER}&swapFeeBps=1000&swapFeeToken=${BRAIN}&tradeSurplusRecipient=${STRANGER}&gasPrice=1000000000000000`;
    const json = { ...withSlippage(EXACT_IN_ETH.json, { minAmountOut: 1n }), minBuyAmount: "1" };
    const report = await verifyQuote(answer(url, json), url, intentFor(EXACT_IN_ETH), options);
    assert.equal(failed(report).name, "quote-request");
    for (const name of ["slippageBps", "swapFeeRecipient", "swapFeeBps", "swapFeeToken", "tradeSurplusRecipient", "gasPrice"]) {
      assert.ok(failed(report).message.includes(`${name} is not part of this trade`), name);
    }
    // Asked for by name, slippageBps passes only at the intent's value, and the caller's floor still holds the calldata.
    const asked = `${EXACT_IN_ETH.url}&slippageBps=100`;
    assert.match(failed(await verifyQuote(answer(asked, EXACT_IN_ETH.json), asked, intentFor(EXACT_IN_ETH, { slippageBps: 30 }), options)).message, /slippageBps=100 where 30 was meant/);
    assert.equal((await verifyQuote(answer(asked, EXACT_IN_ETH.json), asked, intentFor(EXACT_IN_ETH, { slippageBps: 100 }), options)).ok, true);
    assert.match(failed(await verifyQuote(answer(EXACT_IN_ETH.url, EXACT_IN_ETH.json), EXACT_IN_ETH.url, intentFor(EXACT_IN_ETH, { slippageBps: 100 }), options)).message, /slippageBps=\(none\) where 100 was meant/);
    const floorless = await verifyQuote(answer(asked, json), asked, intentFor(EXACT_IN_ETH, { slippageBps: 100 }), options);
    assert.equal(failed(floorless).name, "quote-min-out");
  });

  it("refuses names that only match once decoded, a name given twice, and an empty part", async () => {
    const encoded = `${EXACT_IN_ETH.url}&tradeSurplus%52ecipient=${STRANGER}`;
    assert.match(failed(await verifyQuote(answer(encoded, EXACT_IN_ETH.json), encoded, intentFor(EXACT_IN_ETH), options)).message, /tradeSurplus%52ecipient=0x4444.* is encoded/);
    const plus = EXACT_IN_ETH.url.replace("taker=", "tak+er=");
    assert.match(failed(await verifyQuote(answer(plus, EXACT_IN_ETH.json), plus, intentFor(EXACT_IN_ETH), options)).message, /is encoded.*taker=\(none\)/);
    const twice = `${EXACT_IN_ETH.url}&sellAmount=1&taker=${STRANGER}&chainId=1`;
    const report = await verifyQuote(answer(twice, EXACT_IN_ETH.json), twice, intentFor(EXACT_IN_ETH), options);
    for (const name of ["sellAmount", "taker", "chainId"]) assert.ok(failed(report).message.includes(`${name} is given more than once`), name);
    const empty = `${EXACT_IN_ETH.url}&`;
    assert.match(failed(await verifyQuote(answer(empty, EXACT_IN_ETH.json), empty, intentFor(EXACT_IN_ETH), options)).message, /an empty name is not part of this trade/);
  });

  it("asks for a recipient only when it is someone else, and then requires it", async () => {
    const intent = intentFor(EXACT_IN_ETH, { recipient: STRANGER });
    assert.match(failed(await verifyQuote(answer(EXACT_IN_ETH.url, EXACT_IN_ETH.json), EXACT_IN_ETH.url, intent, options)).message, /recipient=\(none\) where 0x4444/);
    const named = `${EXACT_IN_ETH.url}&recipient=${TAKER}`;
    assert.equal((await verifyQuote(answer(named, EXACT_IN_ETH.json), named, intentFor(EXACT_IN_ETH, { recipient: TAKER }), options)).ok, true);
    assert.match(failed(await verifyQuote(answer(named, EXACT_IN_ETH.json), named, intentFor(EXACT_IN_ETH), options)).message, /recipient is not part of this trade/);
  });

  it("refuses an exact-out quote with no ceiling of the caller's, and one over it", () => {
    const ten = BigInt(EXACT_OUT_ETH.json.maxSellAmount) * 10n;
    const json = { ...rewrite(EXACT_OUT_ETH.json, ten), maxSellAmount: String(ten) };
    json.transaction.value = String(ten);
    assert.match(failed(checkQuote(json, intentFor(EXACT_OUT_ETH, { maxSellAmount: undefined }), SETTLERS)).message, /exact-out intent needs maxSellAmount/);
    const report = checkQuote(json, intentFor(EXACT_OUT_ETH), SETTLERS);
    assert.equal(failed(report).name, "quote-exec");
    assert.match(failed(report).message, new RegExp(`where the caller sells at most ${EXACT_OUT_ETH.json.maxSellAmount}`));
  });

  it("refuses an allowance target that is not AllowanceHolder, whether or not an approval is asked for", () => {
    for (const issues of [EXACT_OUT_USDG.json.issues, { ...EXACT_OUT_USDG.json.issues, allowance: null }]) {
      const report = checkQuote({ ...EXACT_OUT_USDG.json, allowanceTarget: STRANGER, issues }, intentFor(EXACT_OUT_USDG), SETTLERS);
      assert.equal(failed(report).name, "quote-spender");
      assert.match(failed(report).message, /names 0x4444444444444444444444444444444444444444 as allowanceTarget, not AllowanceHolder/);
    }
    assert.equal(failed(checkQuote({ ...EXACT_OUT_USDG.json, allowanceTarget: "nobody" }, intentFor(EXACT_OUT_USDG), SETTLERS)).name, "quote-response");
  });

  it("holds the quote's gas cost to the caller's limit when one is given, and reports the gas price", () => {
    const json = { ...EXACT_IN_ETH.json, transaction: { ...EXACT_IN_ETH.json.transaction, gasPrice: "1000000000000000", gas: "30000000" } };
    const open = checkQuote(json, intentFor(EXACT_IN_ETH), SETTLERS);
    assert.equal(open.ok, true);
    assert.equal(open.quote.transaction.gasPrice, 1_000_000_000_000_000n);
    const capped = checkQuote(json, intentFor(EXACT_IN_ETH, { maxGasCost: 10n ** 15n }), SETTLERS);
    assert.equal(failed(capped).name, "quote-gas");
    assert.match(failed(capped).message, /comes to 30000000000000000000000 wei, over the 1000000000000000 asked for/);
    const real = BigInt(EXACT_IN_ETH.json.transaction.gas) * BigInt(EXACT_IN_ETH.json.transaction.gasPrice);
    assert.equal(checkQuote(EXACT_IN_ETH.json, intentFor(EXACT_IN_ETH, { maxGasCost: real }), SETTLERS).ok, true);
    const { gasPrice: _, ...priceless } = EXACT_IN_ETH.json.transaction;
    assert.match(failed(checkQuote({ ...EXACT_IN_ETH.json, transaction: priceless }, intentFor(EXACT_IN_ETH, { maxGasCost: real }), SETTLERS)).message, /states no gasPrice/);
  });

  it("refuses a clock or an age limit that is not a finite number, which would pass any signature as fresh", () => {
    const request = signedRequestOf(EXACT_IN_ETH.url);
    for (const options of [{ now: at(EXACT_IN_ETH, 86_400), maxAgeSeconds: Number.NaN }, { now: () => Number.NaN }, { now: at(EXACT_IN_ETH), maxAgeSeconds: Number.POSITIVE_INFINITY }, { now: at(EXACT_IN_ETH), maxAgeSeconds: -1 }]) {
      const report = verifyResponse(response(EXACT_IN_ETH), request, options);
      assert.equal(failed(report).name, "zerox-fresh");
      assert.match(failed(report).message, /must be finite numbers/);
    }
  });

  it("maps no gateway slug that is a property of every object", () => {
    for (const slug of ["constructor", "__proto__", "toString", "hasOwnProperty"]) {
      assert.throws(() => signedRequestOf(`https://agent.api.0x.org/v1/x402/${slug}/?a=1`), /not a 0x Swap API/, slug);
    }
  });

  it("refuses another AllowanceHolder on a chain whose AllowanceHolder is pinned", () => {
    const json = { ...EXACT_OUT_ETH.json, transaction: { ...EXACT_OUT_ETH.json.transaction, to: STRANGER } };
    const report = checkQuote(json, intentFor(EXACT_OUT_ETH, { allowanceHolder: STRANGER }), SETTLERS);
    assert.match(failed(report).message, /AllowanceHolder on chain 4663 is 0x0000000000001fF3684f28c67538d4D072C22734, not the 0x4444/);
    assert.equal(checkQuote(EXACT_OUT_ETH.json, intentFor(EXACT_OUT_ETH, { allowanceHolder: HOLDER }), SETTLERS).ok, true);
  });

  it("refuses calldata the decoder reads but the contracts may not: extra bits in an address word, bytes past the arguments", () => {
    const data = EXACT_IN_ETH.json.transaction.data;
    const dirty = `${data.slice(0, 10)}ff${data.slice(12)}`;
    for (const changed of [dirty, `${data}deadbeef`]) {
      assert.throws(() => decode({ data: changed, value: 0n }), /not in the standard encoding/);
      const report = checkQuote({ ...EXACT_IN_ETH.json, transaction: { ...EXACT_IN_ETH.json.transaction, data: changed } }, intentFor(EXACT_IN_ETH), SETTLERS);
      assert.equal(failed(report).name, "quote-exec");
    }
    const outer = decodeFunctionData({ abi: execAbi, data });
    const inner = `${outer.args[4]}00`;
    const padded = encodeFunctionData({ abi: execAbi, functionName: "exec", args: [...outer.args.slice(0, 4), inner] });
    assert.throws(() => decode({ data: padded, value: 0n }), /execute's arguments are not in the standard encoding/);
  });

  it("refuses an Ed25519 signature whose S is past the group order", () => {
    const sig = Buffer.from(/sig=:(.*):/.exec(EXACT_IN_ETH.headers.signature)[1], "base64");
    const L = 2n ** 252n + 27742317777372353535851937790883648493n;
    let s = 0n;
    for (let i = 63; i >= 32; i--) s = (s << 8n) | BigInt(sig[i]);
    s += L;
    const malleated = Buffer.from(sig);
    for (let i = 32; i < 64; i++) {
      malleated[i] = Number(s & 0xffn);
      s >>= 8n;
    }
    const report = verifyResponse(response(EXACT_IN_ETH, { headers: { signature: `sig=:${malleated.toString("base64")}:` } }), signedRequestOf(EXACT_IN_ETH.url), { now: at(EXACT_IN_ETH) });
    assert.equal(failed(report).name, "zerox-signature");
  });

  it("refuses an answer a proxy added a second signature label or digest to", () => {
    const request = signedRequestOf(EXACT_IN_ETH.url);
    const forged = new Headers(EXACT_IN_ETH.headers);
    forged.append("signature-input", 'sig=("@status");created=1;keyid="x";alg="ed25519";tag="0x-swap-api"');
    assert.equal(failed(verifyResponse({ status: 200, headers: forged, body: EXACT_IN_ETH.body }, request, { now: at(EXACT_IN_ETH) })).name, "zerox-key");
    const digests = new Headers(EXACT_IN_ETH.headers);
    digests.append("content-digest", "sha-256=:AAAA:");
    assert.equal(failed(verifyResponse({ status: 200, headers: digests, body: EXACT_IN_ETH.body }, request, { now: at(EXACT_IN_ETH) })).name, "zerox-digest");
  });

  it("refuses a quote on a chain whose registry reverts for the Settler, as one with no such feature does", async () => {
    const revert = () => {
      throw new BaseError("reverted", { cause: new ContractFunctionRevertedError({ abi: [], functionName: "ownerOf" }) });
    };
    const settlers = await readSettlers({ getChainId: async () => 4663, readContract: async () => revert() }, 4663, 77n);
    assert.deepEqual(settlers, {});
    assert.match(failed(checkQuote(EXACT_OUT_ETH.json, intentFor(EXACT_OUT_ETH), settlers)).message, /0x has paused it/);
  });
});

describe("what a caller passes", () => {
  const options = { settlers: SETTLERS, now: at(EXACT_OUT_ETH) };

  it("takes the body as the bytes 0x sent, and refuses anything parsed, decoded or not yet wrapped in a Uint8Array", async () => {
    const buffer = EXACT_OUT_ETH.body.buffer.slice(EXACT_OUT_ETH.body.byteOffset, EXACT_OUT_ETH.body.byteOffset + EXACT_OUT_ETH.body.byteLength);
    assert.equal((await verifyQuote({ ...response(EXACT_OUT_ETH), body: new Uint8Array(buffer) }, EXACT_OUT_ETH.url, intentFor(EXACT_OUT_ETH), options)).ok, true);
    for (const body of [EXACT_OUT_ETH.json, EXACT_OUT_ETH.body.toString("utf8"), null, buffer]) {
      await assert.rejects(verifyQuote({ ...response(EXACT_OUT_ETH), body }, EXACT_OUT_ETH.url, intentFor(EXACT_OUT_ETH), options), (error) => {
        assert.ok(error instanceof TypeError);
        assert.match(error.message, /^the response body is (an object|a string|null|an ArrayBuffer): pass the raw response bytes 0x sent as a Uint8Array, such as new Uint8Array\(await response\.clone\(\)\.arrayBuffer\(\)\)/);
        return true;
      });
    }
  });

  it("says which intent field must be a bigint, rather than comparing a number", async () => {
    const report = await verifyQuote(response(EXACT_OUT_ETH), EXACT_OUT_ETH.url, intentFor(EXACT_OUT_ETH, { maxSellAmount: 84362251006626774 }), options);
    assert.equal(failed(report).name, "quote-intent");
    assert.equal(failed(report).message, "the intent's maxSellAmount must be a bigint, such as 312500000000000000000000n, not a number");
    assert.match(failed(checkQuote(EXACT_IN_ETH.json, intentFor(EXACT_IN_ETH, { sellAmount: 10_000_000 }), SETTLERS)).message, /^the intent's sellAmount must be a bigint, such as 10000000n, not a number$/);
    assert.match(failed(checkQuote(EXACT_IN_ETH.json, intentFor(EXACT_IN_ETH, { chainId: "4663" }), SETTLERS)).message, /chainId must be a positive whole number/);
    assert.deepEqual(report.checks.map((c) => c.name).slice(-1), ["quote-intent"]);
  });

  it("throws a clear error without options, and fails quote-settler with the cause when the Settlers cannot be read", async () => {
    await assert.rejects(verifyQuote(response(EXACT_OUT_ETH), EXACT_OUT_ETH.url, intentFor(EXACT_OUT_ETH)), /^TypeError: verifyQuote needs options with settlers/);
    const report = await verifyQuote(response(EXACT_OUT_ETH), EXACT_OUT_ETH.url, intentFor(EXACT_OUT_ETH), {
      now: at(EXACT_OUT_ETH),
      settlers: async () => {
        throw new Error("HTTP request failed. Status: 503");
      },
    });
    assert.equal(failed(report).name, "quote-settler");
    assert.match(failed(report).message, /could not be read on chain 4663, so Settler 0xE8852602f84e04e284286d8Db01a41Edd0CCEFb0 was not checked: HTTP request failed\. Status: 503$/);
    assert.equal(report.checks.filter((c) => c.status === "fail").length, 1);
  });

  it("says when 0x signed the same parameters in another order, rather than calling the answer changed", async () => {
    const url = new URL(EXACT_OUT_ETH.url);
    const parts = url.search.slice(1).split("&");
    url.search = `?${[parts[1], parts[0], ...parts.slice(2)].join("&")}`;
    const report = await verifyQuote(response(EXACT_OUT_ETH), url.href, intentFor(EXACT_OUT_ETH), options);
    assert.equal(failed(report).name, "zerox-signature");
    assert.equal(failed(report).message, "0x signed the parameters in a different order: pass the exact URL you requested, not one rebuilt from its parameters");
    const other = new URL(EXACT_OUT_ETH.url);
    other.searchParams.set("buyAmount", "1");
    assert.match(failed(await verifyQuote(response(EXACT_OUT_ETH), other.href, intentFor(EXACT_OUT_ETH), options)).message, /the answer was changed, or it answers another request/);
  });
});
