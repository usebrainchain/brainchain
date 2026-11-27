import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { canonicalStringify } from "../dist/canonical.js";
import { keccak256 } from "viem";
import { privateKeyToAccount, sign as signHash } from "viem/accounts";

import { attest, custodyOf, INTEL_SGX_ROOT_SHA256, KMS_ROOT, parseAciReceipt, PHALA_APP, replayRtmr3, signedBy, Unattested, verifyAttestation, verifyTdxQuote } from "../dist/phala.js";

// Recorded on 2026-11-22: Phala's gateway attestation for a fresh nonce, and BrainChain mainnet records whose second
// grader answered through it, as brain.usebrainchain.com serves them.
const read = (name) => JSON.parse(readFileSync(new URL(`./fixtures/phala/${name}.json`, import.meta.url), "utf8"));
const ATTESTED = read("attestation");
const { nonce: NONCE, fetchedAt: AT, report: REPORT } = ATTESTED;
const RECEIPT_KEY = "c9bd1a9c235cfffbd07d71fb5d9ea5f51d50fe1edb937f1189ab0e771722f34e";
const receiptOf = (name) => read(name).second.receipt.body;

const copy = (value) => JSON.parse(JSON.stringify(value));
const refused = (report, pattern, { nonce = NONCE, at = AT } = {}) =>
  assert.throws(() => verifyAttestation(report, nonce, at), (error) => error instanceof Unattested && pattern.test(error.message));

describe("the gateway's attestation", () => {
  it("holds a fresh quote to Intel's root and reads the receipt key, app and compose it measured", () => {
    const attested = verifyAttestation(REPORT, NONCE, AT);
    assert.deepEqual(attested, {
      keysetDigest: "sha256:b7f84d538c1f7763171fd24e7b340c06a06c863c7a638fcac7bb88fd58976301",
      receiptKeys: [{ keyId: "dstack-kms-receipt-ed25519-v1", publicKey: RECEIPT_KEY }],
      notAfter: 1_797_922_925,
      app: "89c51ab856bee41efe78c40309a4deb277a02a0f",
      compose: "261760d004c92eab0b6bed59a55cf3214c65d2cb543a1bed6dff371cd2650a7a",
      os: "8db40cb23008d6213668b5816702d100b37b859a8a5bfd18d938ae3a1b3715bd",
    });
    // Intel publishes its root certificate; this is its SHA-256 fingerprint.
    assert.equal(INTEL_SGX_ROOT_SHA256, "44A0196B2B99F889B8E149E95B807A350E7424964399E885A7CBB8CCFAB674D3");
  });

  it("refuses a report that does not bind this run's nonce", () => {
    refused(REPORT, /does not bind this run's nonce and the keyset/, { nonce: "00".repeat(32) });
  });

  it("refuses a keyset that misses its digest, or one the quote does not bind", () => {
    const swapped = copy(REPORT);
    swapped.attestation.workload_keyset.receipt_signing_keys[0].public_key = "11".repeat(32);
    refused(swapped, /^its keyset hashes to sha256:\w{64}, not the sha256:b7f8\w+ it states$/);
    swapped.workload_keyset_digest = `sha256:${createHash("sha256").update(canonicalStringify(swapped.attestation.workload_keyset)).digest("hex")}`;
    refused(swapped, /does not bind this run's nonce and the keyset/);
  });

  it("refuses a quote changed after it was signed, and one read outside its certificates' validity", () => {
    const quote = Buffer.from(REPORT.attestation.evidence.quote, "hex");
    quote[48 + 472] ^= 1;
    const changed = copy(REPORT);
    changed.attestation.evidence.quote = quote.toString("hex");
    refused(changed, /^the quote's signature does not verify under its attestation key$/);
    refused(REPORT, /in the quote's PCK chain is valid only from/, { at: Date.UTC(2026, 0, 1) });
    assert.throws(() => verifyTdxQuote(quote.subarray(0, 600), AT), /shorter than a TDX quote/);
  });

  it("refuses an expired keyset", () => {
    refused(REPORT, /^its keyset expired at 2026-12-22T07:02:05\.000Z$/, { at: (REPORT.attestation.workload_keyset.not_after + 1) * 1000 });
  });

  it("replays the boot events to RTMR3 and holds the compose file to the hash it measured", () => {
    const events = JSON.parse(REPORT.attestation.evidence.event_log);
    const compose = events.find((e) => e.event === "compose-hash");
    compose.event_payload = "00".repeat(32);
    const relabelled = copy(REPORT);
    relabelled.attestation.evidence.event_log = JSON.stringify(events);
    refused(relabelled, /^its boot event "compose-hash" does not hash to the digest it states$/);

    const swapped = copy(REPORT);
    swapped.attestation.evidence.app_compose = `${swapped.attestation.evidence.app_compose} `;
    refused(swapped, /^the compose hash it measured is not the hash of the compose file it serves$/);
  });

  it("refuses an answer that is not an attestation report", () => {
    for (const report of [null, {}, { ...REPORT, api_version: "aci/2" }]) refused(report, /is not an ACI attestation report/);
  });
});

describe("the gateway's receipts", () => {
  const key = { keyId: "dstack-kms-receipt-ed25519-v1", publicKey: RECEIPT_KEY };

  it("verifies a receipt under the key the gateway attests, whichever keyset it cites since the gateway moved", () => {
    for (const name of ["record-v3-6-400", "record-v3-6-248", "record-v3-4-154"]) assert.equal(signedBy(parseAciReceipt(receiptOf(name)), key), true, name);
    assert.notEqual(receiptOf("record-v3-6-248").workload_keyset_digest, REPORT.workload_keyset_digest);
  });

  it("does not verify a receipt changed after it was signed, or one signed before the gateway moved", () => {
    const changed = { ...receiptOf("record-v3-6-400"), served_at: receiptOf("record-v3-6-400").served_at + 1 };
    assert.equal(signedBy(parseAciReceipt(changed), key), false);
    assert.equal(signedBy(parseAciReceipt(receiptOf("record-v3-4-22")), key), false);
  });

  it("reads only the receipt the gateway signs", () => {
    const receipt = receiptOf("record-v3-6-400");
    assert.ok(parseAciReceipt(receipt));
    for (const body of [null, { result: "verified" }, { ...receipt, api_version: "aci/2" }, { ...receipt, signature: "0x5151" }, { ...receipt, event_log: "none" }]) assert.equal(parseAciReceipt(body), undefined);
  });
});

describe("the receipt key's custody", () => {
  const receiptKey = (report) => report.attestation.evidence.key_custody.keys.find((key) => key.role === "receipt");

  it("holds on the gateway's report: the dstack KMS chain runs from the receipt key through Phala's app to the KMS root on Base", async () => {
    assert.equal(await custodyOf(REPORT, PHALA_APP), undefined);
    const attested = await attest(REPORT, NONCE, AT);
    assert.deepEqual(attested.custody, { holds: true });
    assert.equal(attested.compose, "261760d004c92eab0b6bed59a55cf3214c65d2cb543a1bed6dff371cd2650a7a");
    // kmsInfo().k256Pubkey of 0x2f83172A49584C017F2B256F0FB2Dca14126Ba9C on Base, read on 27 Nov 2026.
    assert.equal(KMS_ROOT, "02a335aea3df11d46ae0a373d3f26fbd1d208572ecc87e630e618dac693b7af721");
  });

  it("fails a well formed chain that ends at another root", async () => {
    const appKey = `0x${"22".repeat(32)}`;
    const point = privateKeyToAccount(appKey).publicKey;
    const app = `${BigInt(`0x${point.slice(-2)}`) % 2n === 0n ? "02" : "03"}${point.slice(4, 68)}`;
    const other = copy(REPORT);
    const entry = receiptKey(other);
    const purpose = await signHash({ hash: keccak256(Buffer.from(`aci.receipt.ed25519.v1:${entry.kms_public_key}`)), privateKey: appKey, to: "hex" });
    const issued = await signHash({ hash: keccak256(Buffer.concat([Buffer.from("dstack-kms-issued:"), Buffer.from(PHALA_APP, "hex"), Buffer.from(app, "hex")])), privateKey: `0x${"11".repeat(32)}`, to: "hex" });
    entry.signature_chain = [purpose.slice(2), issued.slice(2)];
    assert.match(await custodyOf(other, PHALA_APP), /^the custody chain ends at 0[23][0-9a-f]{64}, not the root of Phala's KMS contract on Base, 02a335ae/);
    assert.deepEqual((await attest(other, NONCE, AT)).custody.holds, false);
  });

  it("fails a changed signature, another app, another purpose and a chain of one", async () => {
    const changed = copy(REPORT);
    const chain = receiptKey(changed).signature_chain;
    chain[0] = `${chain[0].slice(0, 6)}${chain[0][6] === "0" ? "1" : "0"}${chain[0].slice(7)}`;
    assert.match(await custodyOf(changed, PHALA_APP), /ends at|does not verify/);
    assert.equal(await custodyOf(REPORT, "cd".repeat(20)), `the boot measured app ${"cd".repeat(20)}, not Phala's gateway, ${PHALA_APP}`);
    const purpose = copy(REPORT);
    receiptKey(purpose).purpose = "aci.e2ee.v1";
    assert.equal(await custodyOf(purpose, PHALA_APP), "the custody chain is for aci.e2ee.v1, not aci.receipt.ed25519.v1");
    const short = copy(REPORT);
    receiptKey(short).signature_chain.pop();
    assert.equal(await custodyOf(short, PHALA_APP), "the custody chain is not two signatures");
  });

  it("fails a keyset with a receipt key outside the chain, another subject, or no custody evidence", async () => {
    const extra = copy(REPORT);
    extra.attestation.workload_keyset.receipt_signing_keys.push({ key_id: "other", algo: "ed25519", public_key: "11".repeat(32) });
    assert.equal(await custodyOf(extra, PHALA_APP), "the keyset lists a receipt key the custody chain does not cover");
    const subject = copy(REPORT);
    subject.attestation.workload_keyset.subject = "app-id:0xcdcd";
    assert.equal(await custodyOf(subject, PHALA_APP), "the keyset names subject app-id:0xcdcd, not the app the boot measured");
    const none = copy(REPORT);
    delete none.attestation.evidence.key_custody;
    assert.equal(await custodyOf(none, PHALA_APP), "the report carries no evidence of who holds its keys");
    const elsewhere = copy(REPORT);
    elsewhere.attestation.evidence.key_custody.provider = "local";
    assert.equal(await custodyOf(elsewhere, PHALA_APP), "its keys are held by local, not the dstack KMS");
  });
});

describe("the boot event replay", () => {
  const RUNTIME = 0x08000001;
  const sha384 = (data) => createHash("sha384").update(data).digest();
  const v1 = (event, payload) => {
    const head = Buffer.alloc(4);
    head.writeUInt32LE(RUNTIME);
    return { imr: 3, event_type: RUNTIME, event, event_payload: payload, digest: sha384(Buffer.concat([head, Buffer.from(`:${event}:`), Buffer.from(payload, "hex")])).toString("hex") };
  };
  const v2 = (event, payload) => {
    const preimage = Buffer.from(canonicalStringify({ name: event, payload, type: RUNTIME }));
    return { imr: 3, event_type: RUNTIME, event, event_payload: payload, version: 2, preimage: preimage.toString("hex"), digest: sha384(preimage).toString("hex") };
  };
  const rtmr3 = (events) => events.reduce((register, e) => sha384(Buffer.concat([register, Buffer.from(e.digest, "hex")])), Buffer.alloc(48));

  it("reads version 2 events and the first of each name before system-ready, as dstack's find_event does", () => {
    const events = [v2("app-id", "ab".repeat(20)), v1("compose-hash", "11".repeat(32)), v1("system-ready", ""), v1("compose-hash", "22".repeat(32))];
    assert.deepEqual(replayRtmr3(JSON.stringify(events), rtmr3(events)), { "app-id": "ab".repeat(20), "compose-hash": "11".repeat(32) });
  });

  it("refuses a version 2 preimage that is not its event, an event of another type, and a version 1 name with a colon", () => {
    const forged = { ...v2("app-id", "ab".repeat(20)), event_payload: "cd".repeat(20) };
    assert.throws(() => replayRtmr3([forged], rtmr3([forged])), /its boot event "app-id" states a preimage that is not the event$/);
    const other = { ...v1("app-id", "ab"), event_type: 1 };
    assert.throws(() => replayRtmr3([other], rtmr3([other])), /holds an RTMR3 event it cannot replay/);
    const colon = v1("app:id", "ab");
    assert.throws(() => replayRtmr3([colon], rtmr3([colon])), /is of a form dstack does not write/);
  });
});
