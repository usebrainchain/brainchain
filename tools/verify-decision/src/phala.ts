// Phala Private AI's gateway serves the judges beside Jev and signs a receipt for every answer it returns. The key it
// signs with is published in its attestation: a keyset that a TDX quote binds to the caller's nonce, certified by
// Intel. Both are checked here with Node's own crypto. Intel's root certificate is the only thing pinned.
// See https://docs.phala.com/phala-cloud/confidential-ai/verify/verify-attestation and the receipt reference beside it.

import { createHash, createPublicKey, verify, X509Certificate, type KeyObject } from "node:crypto";

import { canonicalStringify } from "./canonical.js";

/** The gateway the brain asks its judges through. */
export const PHALA_GATEWAY = "https://inference.phala.com/v1";

/**
 * The SHA-256 fingerprint of the Intel SGX Root CA certificate, which certifies every platform's PCK certificate, as
 * Intel publishes it at https://certificates.trustedservices.intel.com/Intel_SGX_Provisioning_Certification_RootCA.cer
 */
export const INTEL_SGX_ROOT_SHA256 = "44A0196B2B99F889B8E149E95B807A350E7424964399E885A7CBB8CCFAB674D3";

/** An attestation or quote that contradicts itself, or a chain that does not end at Intel's root: a failure, where an unreachable gateway is not. */
export class Unattested extends Error {}

export interface ReceiptKey {
  keyId: string;
  /** Hex, 32 bytes. */
  publicKey: string;
}

/** What a verified attestation says about the gateway. */
export interface Attestation {
  /** `sha256:` and the hex digest of the keyset in JCS form, which the quote binds with the nonce. */
  keysetDigest: string;
  /** The keyset's Ed25519 receipt keys. */
  receiptKeys: ReceiptKey[];
  /** When the keyset expires, in Unix seconds. */
  notAfter: number;
  /** What the gateway measured into RTMR3 as it booted: its dstack app id, the hash of its compose file and its OS image. */
  app: string;
  compose: string;
  os: string;
}

const sha256 = (data: string | Uint8Array): Buffer => createHash("sha256").update(data).digest();
const sha384 = (data: Uint8Array): Buffer => createHash("sha384").update(data).digest();
const HEX = /^(?:[0-9a-f]{2})*$/;
const isObject = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const p256 = (key: KeyObject, data: Uint8Array, signature: Uint8Array): boolean => verify("sha256", data, { key, dsaEncoding: "ieee-p1363" }, signature);

/** A TDX quote's TD report, once its signature chain is held to Intel's root. */
interface TdReport {
  tdAttributes: Buffer;
  rtmr3: Buffer;
  reportData: Buffer;
}

/**
 * Checks a version 4 TDX quote: the PCK chain in its certification data ends at Intel's SGX root and is valid at
 * `now`, the PCK key signs the quoting enclave's report, that report binds the attestation key, and the attestation
 * key signs the quote's header and TD report. It does not appraise the platform's TCB level against Intel's
 * collateral, which a reader fetches from Intel's PCS.
 */
export function verifyTdxQuote(quote: Uint8Array, now: number): TdReport {
  const q = Buffer.from(quote);
  if (q.length < 636) throw new Unattested("the quote is shorter than a TDX quote");
  const version = q.readUInt16LE(0);
  const keyType = q.readUInt16LE(2);
  const tee = q.readUInt32LE(4);
  if (version !== 4 || keyType !== 2 || tee !== 0x81) throw new Unattested(`the quote is not a version 4 TDX quote signed with ECDSA P-256: version ${version}, key type ${keyType}, TEE type 0x${tee.toString(16)}`);
  const body = q.subarray(48, 632);
  const length = q.readUInt32LE(632);
  const data = q.subarray(636, 636 + length);
  if (data.length !== length || length < 134) throw new Unattested("the quote's signature data is cut short");
  const signature = data.subarray(0, 64);
  const attestationKey = data.subarray(64, 128);
  const certType = data.readUInt16LE(128);
  const certSize = data.readUInt32LE(130);
  const cert = data.subarray(134, 134 + certSize);
  if (certType !== 6 || cert.length !== certSize || certSize < 450) throw new Unattested(`the quote's certification data is type ${certType}, not the quoting enclave's report with its PCK chain`);
  const qeReport = cert.subarray(0, 384);
  const qeSignature = cert.subarray(384, 448);
  const authSize = cert.readUInt16LE(448);
  const auth = cert.subarray(450, 450 + authSize);
  const tail = cert.subarray(450 + authSize);
  if (auth.length !== authSize || tail.length < 6 || tail.readUInt16LE(0) !== 5) throw new Unattested("the quote carries no PCK certificate chain");
  const pem = tail.subarray(6, 6 + tail.readUInt32LE(2)).toString("utf8");
  const chain = (pem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? []).map((text) => new X509Certificate(text));
  const [pck, ca, root] = chain;
  if (chain.length !== 3 || !pck || !ca || !root) throw new Unattested(`the quote's PCK chain holds ${chain.length} certificates, not a PCK certificate, its CA and Intel's root`);
  if (root.fingerprint256.replaceAll(":", "") !== INTEL_SGX_ROOT_SHA256) throw new Unattested("the quote's PCK chain does not end at Intel's SGX root CA");
  for (const [subject, issuer] of [[pck, ca], [ca, root], [root, root]] as const) {
    if (!subject.checkIssued(issuer) || !subject.verify(issuer.publicKey)) throw new Unattested(`the certificate "${subject.subject.replace(/\n/g, ", ")}" in the quote's PCK chain is not signed by the one above it`);
    if (now < Date.parse(subject.validFrom) || now > Date.parse(subject.validTo)) throw new Unattested(`the certificate "${subject.subject.replace(/\n/g, ", ")}" in the quote's PCK chain is valid only from ${subject.validFrom} to ${subject.validTo}`);
  }
  if (!p256(pck.publicKey, qeReport, qeSignature)) throw new Unattested("the quoting enclave's report is not signed by the quote's PCK certificate");
  const binding = qeReport.subarray(320, 384);
  if (!binding.subarray(0, 32).equals(sha256(Buffer.concat([attestationKey, auth]))) || binding.subarray(32).some((b) => b !== 0)) {
    throw new Unattested("the quoting enclave's report does not vouch for the quote's attestation key");
  }
  const key = createPublicKey({ key: { kty: "EC", crv: "P-256", x: attestationKey.subarray(0, 32).toString("base64url"), y: attestationKey.subarray(32).toString("base64url") }, format: "jwk" });
  if (!p256(key, q.subarray(0, 632), signature)) throw new Unattested("the quote's signature does not verify under its attestation key");
  return { tdAttributes: body.subarray(120, 128), rtmr3: body.subarray(472, 520), reportData: body.subarray(520, 584) };
}

/** The statement the gateway binds into the quote's report data (ACI's aci.report_data.v1), as its docs give it: these fields in this order, without whitespace. */
const reportData = (keysetDigest: string, nonce: string): Buffer => sha256(JSON.stringify({ keyset_digest: keysetDigest, nonce, purpose: "aci.report_data.v1" }));

/**
 * Checks the gateway's attestation report, as GET /v1/aci/attestation?nonce=<nonce> answers it: the keyset hashes
 * to the digest it states, a TDX quote held to Intel's root binds that digest and `nonce`, the keyset has not expired
 * at `now`, the TD is not a debug TD, and the boot event log replays to the quote's RTMR3 with the compose file it
 * measured. Throws Unattested when any of it fails.
 */
export function verifyAttestation(report: unknown, nonce: string, now: number): Attestation {
  const r = isObject(report) ? report : {};
  const attestation = isObject(r.attestation) ? r.attestation : {};
  const keyset = attestation.workload_keyset;
  const evidence = isObject(attestation.evidence) ? attestation.evidence : {};
  if (r.api_version !== "aci/1" || !isObject(keyset) || typeof r.workload_keyset_digest !== "string" || typeof evidence.quote !== "string" || !HEX.test(evidence.quote)) {
    throw new Unattested("the gateway's answer is not an ACI attestation report with a keyset and a quote");
  }
  const keysetDigest = `sha256:${sha256(canonicalStringify(keyset)).toString("hex")}`;
  if (keysetDigest !== r.workload_keyset_digest) throw new Unattested(`its keyset hashes to ${keysetDigest}, not the ${r.workload_keyset_digest} it states`);

  const quote = verifyTdxQuote(Buffer.from(evidence.quote, "hex"), now);
  if (!quote.reportData.equals(Buffer.concat([reportData(keysetDigest, nonce), Buffer.alloc(32)]))) throw new Unattested("its quote does not bind this run's nonce and the keyset");
  if ((quote.tdAttributes[0]! & 1) !== 0) throw new Unattested("its quote comes from a debug TD, whose host can read and change it");
  if (typeof keyset.not_after !== "number" || keyset.not_after * 1000 <= now) throw new Unattested(`its keyset expired at ${typeof keyset.not_after === "number" ? new Date(keyset.not_after * 1000).toISOString() : "a time it does not state"}`);

  const measured = replayRtmr3(evidence.event_log, quote.rtmr3);
  const compose = typeof evidence.app_compose === "string" ? sha256(evidence.app_compose).toString("hex") : undefined;
  if (!measured["compose-hash"] || measured["compose-hash"] !== compose) throw new Unattested("the compose hash it measured is not the hash of the compose file it serves");

  const keys = Array.isArray(keyset.receipt_signing_keys) ? keyset.receipt_signing_keys : [];
  const receiptKeys = keys
    .filter((k): k is { key_id: string; algo: string; public_key: string } => isObject(k) && typeof k.key_id === "string" && k.algo === "ed25519" && typeof k.public_key === "string" && /^[0-9a-f]{64}$/.test(k.public_key))
    .map((k) => ({ keyId: k.key_id, publicKey: k.public_key }));
  if (receiptKeys.length === 0) throw new Unattested("its keyset holds no Ed25519 receipt key");
  return { keysetDigest, receiptKeys, notAfter: keyset.not_after, app: measured["app-id"] ?? "", compose: measured["compose-hash"], os: measured["os-image-hash"] ?? "" };
}

/**
 * Replays dstack's boot events into RTMR3: each event's digest is SHA-384 over its type (u32, little-endian), ":",
 * its name, ":" and its payload, and the register extends by each digest in turn. Returns each named event's payload,
 * as hex or, for the ids and hashes, as dstack writes them.
 */
function replayRtmr3(eventLog: unknown, rtmr3: Buffer): Record<string, string> {
  let events: unknown;
  try {
    events = typeof eventLog === "string" ? JSON.parse(eventLog) : eventLog;
  } catch {
    throw new Unattested("its boot event log is not JSON");
  }
  if (!Array.isArray(events)) throw new Unattested("its boot event log is not a list of events");
  let register: Buffer = Buffer.alloc(48);
  const payloads: Record<string, string> = {};
  for (const e of events) {
    if (!isObject(e) || e.imr !== 3) continue;
    const { event_type: type, event, event_payload: payload, digest } = e;
    if (typeof type !== "number" || typeof event !== "string" || typeof payload !== "string" || !HEX.test(payload) || typeof digest !== "string") throw new Unattested("its boot event log holds an RTMR3 event it cannot replay");
    const head = Buffer.alloc(4);
    head.writeUInt32LE(type);
    const computed = sha384(Buffer.concat([head, Buffer.from(`:${event}:`), Buffer.from(payload, "hex")]));
    if (computed.toString("hex") !== digest) throw new Unattested(`its boot event "${event}" does not hash to the digest it states`);
    register = sha384(Buffer.concat([register, computed]));
    payloads[event] = payload;
  }
  if (!register.equals(rtmr3)) throw new Unattested("its boot event log does not replay to the quote's RTMR3");
  return payloads;
}

/** A receipt as GET /v1/aci/receipts/<id> answers it: the fields read here. The signature covers every field. */
export interface AciReceipt {
  receipt_id: string;
  workload_keyset_digest: string;
  model: unknown;
  endpoint: unknown;
  method: unknown;
  served_at: number;
  event_log: Record<string, unknown>[];
  key_id: string;
  signature: string;
}

export function parseAciReceipt(value: unknown): AciReceipt | undefined {
  if (!isObject(value)) return undefined;
  const { api_version, receipt_id, workload_keyset_digest, served_at, event_log, key_id, signature } = value;
  if (api_version !== "aci/1" || typeof receipt_id !== "string" || typeof workload_keyset_digest !== "string" || typeof key_id !== "string") return undefined;
  if (typeof served_at !== "number" || !Number.isSafeInteger(served_at) || !Array.isArray(event_log) || !event_log.every(isObject)) return undefined;
  if (typeof signature !== "string" || !/^[0-9a-f]{128}$/.test(signature)) return undefined;
  return value as unknown as AciReceipt;
}

/** The receipt's first event of `type`. */
export const eventOf = (receipt: AciReceipt, type: string): Record<string, unknown> | undefined => receipt.event_log.find((e) => e.type === type);

/** Whether `key` signed the receipt: Ed25519 over the JCS form of every field but `signature`, as ACI's receipts are signed. */
export function signedBy(receipt: AciReceipt, key: ReceiptKey): boolean {
  const { signature, ...signed } = receipt as unknown as Record<string, unknown>;
  try {
    const publicKey = createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: Buffer.from(key.publicKey, "hex").toString("base64url") }, format: "jwk" });
    return verify(null, Buffer.from(canonicalStringify(signed)), publicKey, Buffer.from(String(signature), "hex"));
  } catch {
    return false;
  }
}

/** The session the gateway's upstream.verified event cites: the hex id of the record in which it verified the TEE upstream. */
export function citedSession(receipt: AciReceipt): string | undefined {
  const id = eventOf(receipt, "upstream.verified")?.session_id;
  return typeof id === "string" && /^[0-9a-f]{64}$/.test(id) ? id : undefined;
}

/**
 * What does not hold of a session record against the receipt that cites it, as ACI's upstream check reads it: the record
 * hashes, in JCS form, to the cited id, it is an aci/1 record, the answer was served inside its window, and its evidence
 * hashes to the digest it states. The evidence is the upstream's own attestation, which ACI leaves to the gateway.
 */
export function sessionProblems(receipt: AciReceipt, id: string, session: unknown): string[] {
  if (!isObject(session)) return ["it is not a session record"];
  const wrong: string[] = [];
  if (sha256(canonicalStringify(session)).toString("hex") !== id) wrong.push("it does not hash to the id the receipt cites");
  if (session.api_version !== "aci/1") wrong.push("it is not an aci/1 record");
  const { established_at: from, expires_at: until } = session;
  if (typeof from !== "number" || typeof until !== "number" || receipt.served_at < from || receipt.served_at >= until) wrong.push("the answer was served outside its window");
  const evidence = isObject(session.evidence) ? session.evidence : {};
  const data = typeof evidence.data === "string" ? /^data:[^,]*;base64,(.*)$/s.exec(evidence.data)?.[1] : undefined;
  // Node's decoder skips what is not base64, so the bytes must encode back to the text the record holds.
  const bytes = data === undefined ? undefined : Buffer.from(data, "base64");
  if (!bytes || bytes.toString("base64").replace(/=+$/, "") !== data!.replace(/=+$/, "")) wrong.push("its evidence is not base64");
  else if (`sha256:${sha256(bytes).toString("hex")}` !== evidence.digest) wrong.push("its evidence does not hash to the digest it states");
  return wrong;
}
