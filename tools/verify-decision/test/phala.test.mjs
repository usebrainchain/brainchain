import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { canonicalStringify } from "../dist/canonical.js";
import { INTEL_SGX_ROOT_SHA256, parseAciReceipt, signedBy, Unattested, verifyAttestation, verifyTdxQuote } from "../dist/phala.js";

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
