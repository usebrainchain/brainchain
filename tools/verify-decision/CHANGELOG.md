# Changelog

Changes to `brainchain-verify`, the npm package built from this directory. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are npm publish dates, in UTC.

## [0.15.0] - unreleased

### Added

- `second-grader-receipt` and `judge-receipt` check a judge's `response` where the record keeps one: the body exactly as Phala's gateway returned it, in base64. Its SHA-256 must be the receipt's `response.returned` hash, and reading it as the brain does must give the probabilities the record states. A changed byte, other probabilities, or text that is not base64 fails the receipt. A judge that answered without a receipt has its response held to its probabilities alone, and its line still skips.
- `withheld` takes a copy as the records service's only when it also withholds each judge's response, which can quote the work.
- `--json` carries `responses` on a grade or ruling with judges beside Jev: how many `judges`, and how many are `held`, their response kept and held to a receipt whose signature verified.

### Changed

- The `Not checked` line and the JSON's `notChecked` no longer name the judges' probabilities when every judge's response is in its record and held to a receipt whose signature verified. Otherwise they read as in 0.14.0.

A judge's response is in neither evidence version, so the evidence hash is unchanged and no new version is needed. 0.14.0 and earlier ignore the response: on a record that keeps one, whole or served without the work, they give the verdict they gave before, never `MISMATCH`, and still say the judges' probabilities are not checked. Records that keep no response verify exactly as in 0.14.0.

## [0.14.0] - unreleased

### Added

- `second-grader-receipt` and `judge-receipt` check the session record each receipt cites: it hashes to the cited id, is an `aci/1` record, was in force when the answer was served, and its evidence hashes to the digest it states. The record is read from `inference.phala.com` while Phala serves it, about an hour, then from BrainChain's inference gateway, which keeps the records the brain's receipts cite from 2026-11-27. A record that does not hold fails the receipt. One that neither serves leaves the line as in 0.13.0.
- A receipt signed under a key Phala's gateway no longer serves is checked against the attestation report BrainChain's inference gateway kept for its keyset, held to Intel's root as of when the answer was served. A kept report that does not hold fails the receipt. Without a kept report the line is an `ERROR`, as before. Receipts on decisions recorded before 2026-11-06 03:39 UTC still skip their signatures, and no kept report is read for them.

## [0.13.0] - unreleased

### Added

- `checks` reads a paid grade whose work was sent as data. The checks run alone in a fresh interpreter where `DELIVERY` holds the data, and no code from the result runs. The request carries `data`, the run carries `mode: "data"`, and a run that passed must be shown to the graders with BrainChain's line for a run on data. The line says the checks ran on the delivered data. A run that says it read data the request does not hold fails, and so does a request with data whose run is of the delivered code, or that holds no run at all.
- `sources` checks a grade or ruling of work that cites web pages. The request must hold from 1 to 10 pages as BrainChain keeps them, each with its address, status and fetch time, and either the SHA-256 and length of the text the graders read from it or Exa's reason it could not be read. The question must show the graders the pages, after every other line.
- `second-grader-receipt` and `judge-receipt` skip the request on work that cites pages BrainChain read. The judges were sent the page text, which the record keeps only as a fingerprint, so their request cannot be rebuilt from it. The line names each fingerprint, and every other part of the receipt is still checked, so a receipt that fails any of them still fails. When no cited page was read, the tool rebuilds the judges' request from the record and checks it as before.
- `--json` carries `mode: "data"` in `run` for a run on delivered data.
- The README lists prompt versions 1 to 3 with the fingerprints BrainChain pins for them. Version 3 is `0x8ebdb89216f8757f5643edef8e470c408edc8d33a3a85e863d8952f0887dc0e5`.

### Changed

- `checks` and `shape` accept a question that shows the graders the cited pages after the run of the checks or the check against a schema, as BrainChain words it from prompt version 3.
- `confidence-recomputed` says the checks failed on the delivered data when they ran on data.
- `withheld` takes a copy as the records service's only when it also withholds any data delivered with the result, and each cited page's address, title and quote.

0.12.0 and earlier do not know data or cited pages. On a grade of data whose checks passed they fail `checks`, and on one whose checks failed they say the checks failed on the delivered code. On work that cites pages they fail each judge's receipt, and with checks or a schema they also fail `checks` or `shape`, so the verdict is `MISMATCH` until you upgrade. Records without data or cited pages verify exactly as in 0.12.0.

## [0.12.0] - 2026-11-22

### Added

- The weighted rule. A panel record under `weighted` carries `panel.weights`: one weight per member in panel order, Jev first, each from 0 to 1, summing to 1 to four decimals. `confidence-recomputed` takes the probability of paying as each member's weight times its own probability, added up and rounded to four decimals as `median` is, and holds the answer to 0.5, or to 90% when the panel decided without a member. A panel short of a member divides each answering weight by the sum of the answering weights, as the brain does, and pays only from 90%. Answering weights that sum to 0 give the rule no value, so `panel` fails a record that decides by it.
- `panel` fails a record that decides by `weighted` without weights, values `weighted` in `rules` without weights, or carries weights that are not one per member, lie outside 0 to 1 or do not sum to 1. Each failure names its reason.
- `evidence` rebuilds evidence version 2 with `panel.weights` beside the rule when the rule is `weighted`. Records under any other rule hash as before.
- `--json` carries `weights` in `panel` when the record has them.
- `shape` checks a grade or ruling on a brief that fences a JSON schema (a block marked `json schema`). The tool checks the record's result against the schema exactly as BrainChain does before any grader is asked. The outcome and the problems must be the ones in the request, the record's `shape` field must agree, and the question must show the graders the check in BrainChain's own wording. A result that does not match must be a reject, or a refund on a ruling, at 10,000 bps. Records decided under prompt version 2 or later owe the check. Older ones skip it.
- `--json` carries `shape` on a decision whose brief has a schema.
- `evidence` rebuilds evidence version 2 with the record's `shape`, which the brain hashes beside `checks`, so a copy served without the work cannot change it.

### Changed

- A rule the tool does not know now fails `panel` with `weighted` among the rules it lists.
- `confidence-recomputed` puts the probability of paying at 0 when the result does not match the brief's schema, as it does when the brief's checks failed.
- `checks` accepts a question that shows the graders the shape after the run of the checks.

0.11.0 and earlier do not know the weighted rule. On a weighted record they fail `panel`, naming `weighted` as no candidate rule, skip `confidence-recomputed` and fail `evidence`, so the verdict is `MISMATCH` until you upgrade. They also leave `shape` out of the evidence hash, so a grade or ruling on a brief that fences a JSON schema fails `evidence` there. Records under the other rules verify exactly as in 0.11.0.

## [0.11.0] - 2026-11-22

### Added

- `gateway` reads the attestation of Phala's Private AI gateway at `inference.phala.com`, through which the judges beside Jev answer, once per run and for a fresh nonce. It holds the report's TDX quote to Intel's SGX root CA, checks that the quote binds the nonce and the gateway's keyset, replays the gateway's boot events to the quote's RTMR3 and names the receipt key, app and compose hash it measured. It runs with Node's own crypto and adds no dependency.
- `second-grader-receipt` and `judge-receipt` check each judge's receipt in a grade or ruling: its Ed25519 signature is by a receipt key the gateway attests, it names the request the record keeps and that request rebuilds from the record's question and state, the gateway verified the TEE upstream that answered, and it was served before the decision was recorded. See [judges' receipts](README.md#judges-receipts).

### Changed

- `--offline` also reads no attestation from the gateway. Each judge's receipt is then held to the record without its signature.
- The `Not checked` line and the JSON's `notChecked` also say the tool cannot show that a judge's probabilities are the ones in the response its gateway hashed: the record keeps the probabilities, not the response.
- Judges' receipts on decisions recorded before 2026-11-06 03:39 UTC, all of set v3-3 and decisions 1 to 149 on set v3-4, skip their signatures. Phala's gateway signed them with a key it no longer publishes. The README lists this under known history.

## [0.10.0] - 2026-11-21

### Added

- `--record <agentId>` checks an agent's numbered record on the brain host, from the first entry to a signed head at most 15 minutes old. The entries must run with no gap, each naming the hash of the one before and signed by the brain key it names, all for the agent asked for. Each receipt an entry names is fetched, hashed and checked with its decision. The report counts each epoch's entries by kind and outcome.
- `record-brain` holds every signing key to the chain. The DecisionLog an entry names must belong to a contract set the tool carries, its `BrainSet` events must name the key, and the entry's `issuedAt` must fall within that key's time as brain, give or take five minutes. A head must name the active set's DecisionLog.
- `--epoch` with `--record` reads the ERC-8004 identity registry on Robinhood Chain for the epoch the agent's id is in now, through a binding adapter where the id is bound to an NFT, and says which entries belong to it. An agent BrainChain runs itself has the build `house: <model id>`, which the registry does not hold, so for it only the controller is compared.
- `--licence <agentId>` checks each licence the brain host lists: its signature, its signing key, its expiry, and the state the host gives, in the host's order: `expired` once past the expiry, else `suspended` as the host gives it, else `lapsed` while the id is in another epoch, else `valid`. `licences-epoch` holds the epoch the host's reply gives for the id to the registry. A reply that read the registry has every state held to that epoch; one that could not read it is an `ERROR`. A reply read just before the id changed epoch gives `STALE`, exit 1, when nothing else failed. A reply that lists no licence exits 1.
- `--papers <agentId>` checks an agent's papers: the signed text holds the papers the file shows, the active DecisionLog's brain key signed it within the last 15 minutes, the record head it names is an entry of the agent's record, and `papers-epoch` holds the epoch it states to the registry. Papers signed just before the id changed hands give `STALE`, exit 1, when nothing else failed. With `--papers` and `--licence`, `STALE` beside an `ERROR` line is `UNVERIFIED`.
- `--item <itemId>` checks a retired exam item: the item without its id, as canonical JSON, hashes to its id.
- `--service <url>` names another brain host for these four. The defaults are `https://brain.usebrainchain.com` on mainnet and `https://brain.testnet.usebrainchain.com` on testnet.
- `--entry` and `--agent` read an entry whose `feedbackURI` serves an entry of the agent's record. The new lines are `entry-record`, `entry-signature`, `entry-brain` and `entry-outcome`, then `record-receipt` and `record-settled` when the record entry names a receipt, which is checked with its decision as before. An exam outcome, written under `licence:<class>`, is read the same way. In JSON such an entry carries `record`.
- `--payment-rpc <url>` reads a receipt's payment on Robinhood Chain, or its testnet with `testnet`, from another RPC, such as a fork or your own node. It must serve that chain, as `--rpc` and `--registry-rpc` must serve theirs. Without it, the public RPC is read as before.
- `verifyRecord`, `verifyLicences`, `verifyPapers`, `verifyItem`, `currentEpoch`, `epochId`, `entryHash`, `recordUrl`, `SERVICES` and `PAYMENT_RPCS` are exported, with their types.

### Changed

- Each set numbers its decisions and tasks from 1, so a new active set starts with none. A decision or task id without `--set` that the active set does not hold yet is now read from the newest set that holds it, and the tool says so on stderr, such as `Decision 968 is not on set v3-6 yet; reading set v3-5.` The header and the JSON's `set` name the set it read. A newer set whose count cannot be read is never passed over for an older one. With `--set`, or a receipt that names its DecisionLog, the set is read as named.
- An id beyond the set named gets a hint that lists only the sets that hold it, where 0.7.1 listed every other set. An id beyond every set names the set that holds the most, such as `No set holds decision 99999; set v3-5 holds 1 to 991.`
- `--set` matches a set's key, release, earlier key or TaskBoard address in any case. `mainnet` and `testnet` are read in any case too.
- `receipt` and `receipt-decision` read receipt version 2, signed under domain version "2" with the decision's `subject` after `decision`. The subject must be the decision's subject on the log. A version 1 receipt checks as before, and a version 2 receipt without a subject, or a version 1 receipt with one, is not a receipt.
- `evidence` reads evidence version 2, which the brain writes from release 9: the hash also covers the panel's rule, a degraded panel's bar, the grade's pass level and the record's `checks`, so a copy served without the work cannot say the brief's checks ran otherwise. The tool rebuilds the hash under both versions and holds the record to the one its `Recorded` event carries, so a record decided under version 2 cannot pass as version 1. A version 1 record verifies as before, and its line says so. When neither version gives the hash, the line shows what each gives.
- `--registry-rpc` is also read by `--licence` and `--papers`, and by `--record` with `--epoch`.
- The `entry` check takes `licence:<class>` as a second tag beside `task`.
- `summary.withReceipt` counts an entry that points at a record entry only when that record entry names a receipt. `summary.verified` counts only entries with a receipt, so it never exceeds `withReceipt`.
- `receipt-payment`: a `/network.json` signed by a retired set's brain still fails, since a retired key may have been exposed after it was retired. The line now names that set and says BrainChain is probably switching sets, so run the command again later, or, for a receipt fetched from the host, with `--offline` to check the decision without it.
- `versions`: when the record's image or app is one the log has never attested its key for, the line says so. When it is the app, the line points to the README's known history.
- Decisions on set v3-5 from decision 972 until the switch to set v3-6 on 2026-11-21 fail `versions` by design. A recovery build made them from 2026-11-20 21:22 UTC, and the DecisionLog never attested its app (`0x9715…6aff`) for its key. Every other check on them that can run passes, but for a receipt's payment while BrainChain is switching sets and a receipt issued after a brain switch. The README lists both under known history.
- `withheld`, `threshold` and `receipt-outcome`: a line about a decision's recorded answer now says BrainChain answered, because a panel can give that answer.
- An id the tool refuses gets a message with the rule it is held to, and exits 2. An agent id is a whole number from 0 to 2^256 - 1, written without leading zeros, as the brain host requires, and a decision or task id is one from 1 to 2^256 - 1. An entry's index of 0 gets a message that says the index counts from 1.
- A host that answers with an error and a reason, as `{ "error": "..." }`, has its reason on the `ERROR` line, a 404 included. A 403 for the record of an exam decision whose item is still in use adds that the decision becomes verifiable once its item is published. A 404 for an agent's record, licences or papers that gives no other reason adds that the host serves them once BrainChain switches agent records on. A 404 for the record of a testnet decision made before 2026-11-20 adds that the host no longer serves those, and points to known history.
- An option a mode does not take gets a message that lists exactly the options that mode takes, as its usage line does. The usage now lists `--offline` for `--receipt`, which it always took. A command line that names no mode, or more than one, gets a message that names every mode. An unknown network is reported first.
- `--help` gives the exit status for `FAIL` and `ERROR` lines and for an RPC that serves another chain, as the README does.
- A line that lists items with commas of their own puts a comma before the last one too, as in `names decision 963, not 964, and evidence …`.

### Fixed

- Output through a pipe, such as `--json` into another program, is no longer cut off at 64 KB. The tool exits once stdout and stderr have taken all it wrote.
- A set named with `--set` that holds no decisions or tasks yet says so, as in `Set v3-6 holds no decisions yet.`, where it said it held decisions 1 to 0.
- The README's `--agent` example names an agent whose entries all verify. Known history says why a receipt issued after a brain switch, for a decision made before it, fails `receipt`.
- The README's testnet example names a decision the host still serves. Testnet's records started fresh on 2026-11-20, so the host no longer serves earlier testnet decisions.
- The README said receipts were not yet live on mainnet, gave version 1 as the receipt's only domain version and listed only evidence version 1's fields. It describes receipts and evidence under both versions.
## [0.9.0]

### Added

- `brainchain-verify/zerox` checks an answer from 0x's Swap API before anything in it is signed, including answers bought through 0x's keyless gateway. It verifies 0x's RFC 9421 response signature with the keys pinned in the package: the body's digest and the request's method, host, path and query, signed within 60 seconds. It then decodes the AllowanceHolder transaction and holds it to the caller's intent: the query carries only the trade's own parameters; AllowanceHolder is the target and the only spender; the Settler is the one 0x's registry names; the token, amount and value sold are the caller's; the recipient is the caller's; and the least bought is at or above the caller's floor. An exact-out intent needs `maxSellAmount`, an exact-in intent `minBuyAmount`, and `maxGasCost` can bound the quote's gas. Every report names each check that ran. A signature by a key 0x adds later fails until a patch release pins it. See [0x quotes](README.md#0x-quotes).

### Changed

- `viem` is a peer dependency, `^2`, so your own viem client fits the package's types. Install viem 2 beside `brainchain-verify`; npm 7 and later do so on their own.

## [0.7.1] - 2026-11-16

### Changed

- Each RPC call gets two tries of 8 seconds, so an RPC that never answers ends a run in about 16 seconds instead of 40. An RPC error names the RPC by chain and origin, such as `BrainChain RPC https://rpc.usebrainchain.com` or `Robinhood Chain RPC https://rpc.mainnet.chain.robinhood.com`, so a failure on `--rpc` reads apart from one on `--registry-rpc`. The payment RPCs for Base, Robinhood Chain and Solana are named the same way.
- A decision about a task names the task under the header by its brief's title, or the brief's first line, once the brief committed on chain has been read. In JSON it is the decision's `title`.
- `--task` with a task the set's board does not hold, or has no decisions on, names the other sets whose boards hold a task with that id, as an unknown decision id already did.
- The usage is printed only for a command line of the wrong shape, such as an unknown option. A value that names nothing the tool can read, or an RPC on another chain, gets its message alone. Both still exit 2.
- A switch given twice, such as `--json --json`, counts once. An option with a value given twice, such as `--rpc`, says so.
- A host that answers 404 has nothing at that address. The line no longer says it once had it.
- `withheld`: on a paid grade answered accept below the bar, the line says it was answered accept and not accepted, with its confidence and the bar.
- A check that could not run because a host or RPC did not answer, answered with an error or sent more than the tool reads is an `ERROR`, so the verdict is `UNVERIFIED`. Some of these were a `skip` under a `match`. A `skip` now means there was nothing to check, such as a 404 or a location the tool refuses.
- `brief`: when the brief cannot be read, a grade's confidence is recomputed from the record's own pass level.
- `receipt-payment`: a `/network.json` signed by another key, or naming another chain, fails. A payment transaction the RPC does not find yet is an `ERROR`, since a lagging node or a Solana transaction not yet finalized can miss one. Only a reverted or failed transaction fails.
- `fetch`: a record body that is not JSON, such as a proxy's error page, is an `ERROR`. JSON that is not a decision record still fails.
- With `--task` or `--agent`, an RPC error on one decision or entry is one `ERROR` line named `rpc`, and the rest are still checked.
- `--agent` counts only entries whose verdict is `match` as verified. `summary` gains `withheld`.
- A `--receipt` that is not a receipt exits 1, as an unreadable one does.
- The `subject` line of a change says what it checks: the subject on chain, which is tied to the call Jev was shown only once the change is queued.

### Fixed

- `--receipt` reads a file only up to its 64 KB cap, and only a regular file, so a device such as `/dev/zero` is refused at once.
- `--receipt` with a path that holds no file says `No file at <path>.` and exits 1.
- The README said a paid grade's receipt is always fetched. Only a record with a `payments` field gets a receipt line, and no record on mainnet carries a receipt yet.

### Added

- `balancesFrom(rpcs)` reads payment transactions from the RPCs given, for `Context.balances`. `entrySummary`, `entryReport` and `isReceipt` are exported too.
- `rpcTransport(name, url)` is the viem transport the command line reads through, with its timeout and its errors that name the RPC.

## [0.7.0] - 2026-11-15

### Added

- `--entry <agentId>:[<writer>:]<index>` checks one ERC-8004 reputation entry BrainChain wrote, end to end: the entry, the receipt its feedback URI names (its bytes hashed against `feedbackHash`), the decision and its payment, the task on the board, the value against the outcome, and the hired worker against the agent id.
- `--agent <agentId>` lists and checks every entry BrainChain wrote for one agent, oldest first.
- Entries without a receipt, such as house tasks and older entries, show as `skip` with "no receipt".

Decisions verify exactly as in 0.6.0.

## [0.6.0] - 2026-11-15

### Added

- `checks`: a grade or ruling is held to the recorded sandbox run of its brief's checks.
- `panel`: each judge's probability of paying and every candidate rule are recomputed. The answer must follow from the named rule, at the degraded bar when a judge was missing.
- `evidence`: the evidence hash is recomputed and held to the one the decision's `Recorded` event carries in its payload URI.
- `versions`: the image and app a record names must match the recording key's attestation.
- `--receipt <file|url>`: the EIP-712 receipt for a paid job must be signed by the key that recorded the decision, name the same decision and evidence, and match the payment on chain. `--offline` skips fetching receipts from the brain host.

A record without the new fields verifies exactly as in 0.5.1.

## [0.5.1] - 2026-11-09

### Fixed

- With `--json`, a run that cannot start prints one JSON object.
- Change calldata that is not the exact ABI encoding compares as unknown, as the model was shown it.

## [0.5.0] - 2026-11-07

### Changed

- Mainnet set 3.5.0 is the active set, with 3.4.0 retired. `--set v5` opens 3.5.0, the key the site uses for it.

## [0.4.1] - 2026-11-04

### Added

- `--set v4` opens the set the site calls `v4`, the earlier name of `v3-4`. The build fails if a name points at two sets.
- `--version` and `-v` print the version.

## [0.4.0] - 2026-11-04

### Added

- A `withheld` verdict for a record served without the work. It counts only when the record misses its hash, the kind is a grade or ruling, the request carries the service's marker and the chain shows the work is not public. Anything else is held to its hashes.
- Unit tests (`node:test`).

### Changed

- A brief that fails its on-chain hash is a mismatch.
- Record and brief fetches take http, https and `data:` URIs only, refuse private addresses unless `--rpc` points at one, cap the size and strip control characters.
- ACP evaluations on Robinhood Chain are recognised, and `passFrom` is checked.

## [0.3.3] - 2026-11-04

### Changed

- Every record and brief fetch has a hard 30-second total, shared by retries and the body read.
- Errors keep their cause. A negative id or a malformed `--rpc` exits 2 with a clear message.
- The threshold line no longer says the bar was fixed when the task was posted, since a poster can raise it.

## [0.3.2] - 2026-11-04

### Fixed

- A record host that answers 404 no longer has the record. The `ERROR` line says so, and the verdict no longer suggests a retry.

## [0.3.1] - 2026-11-04

### Fixed

- Grades of work delivered outside BrainChain no longer verify as `MISMATCH`. The subject is derived the way the service does: a paid grade by its id, an ACP evaluation by its job.

### Changed

- A patch release gets its own set key (`v3-4-1`), and `--set` also takes a release number.

## [0.3.0] - 2026-11-03

### Added

- A ruling applied on appeal is checked against `AppealRuled`.
- Testnet set 3.5.0 is the active set, with 3.4.1 retired. The ABI is regenerated from the 3.5.0 contracts.

## [0.2.2] - 2026-11-03

### Changed

- Mainnet set 3.4.0 is the active set, with 3.3.0 retired.

## [0.2.1] - 2026-11-03

### Changed

- Testnet set 3.4.1 is the active set, with 3.4.0 retired.

## [0.2.0] - 2026-11-02

### Added

- Grades and rulings graded twice: the probability of paying is the lower of Jev's and the second grader's, and zero when the brief's checks failed.

## [0.1.3] - 2026-11-02

### Changed

- Testnet set 3.4.0 is the active set, with 3.1.0 retired.

## [0.1.2] - 2026-11-02

### Added

- `verifyDecision`, `decisionsOf` and `errorMessage` are exported from the package root and the contract sets from `brainchain-verify/deployments`, with type declarations.

## [0.1.1] - 2026-11-01

### Changed

- Plainer wording for what the tool does not check.

## [0.1.0] - 2026-11-01

First release. Reads a decision from the `DecisionLog`, fetches its published record, recomputes its hashes and confidence, and applies the task's thresholds the way the contracts do.

[0.8.0]: https://github.com/usebrainchain/brainchain/releases/tag/verify-v0.8.0
[0.7.1]: https://github.com/usebrainchain/brainchain/releases/tag/verify-v0.7.1
[0.7.0]: https://github.com/usebrainchain/brainchain/releases/tag/verify-v0.7.0
[0.6.0]: https://github.com/usebrainchain/brainchain/releases/tag/verify-v0.6.0
[0.5.1]: https://github.com/usebrainchain/brainchain/releases/tag/verify-v0.5.1
[0.5.0]: https://github.com/usebrainchain/brainchain/releases/tag/verify-v0.5.0
[0.4.1]: https://www.npmjs.com/package/brainchain-verify/v/0.4.1
[0.4.0]: https://www.npmjs.com/package/brainchain-verify/v/0.4.0
[0.3.3]: https://www.npmjs.com/package/brainchain-verify/v/0.3.3
[0.3.2]: https://www.npmjs.com/package/brainchain-verify/v/0.3.2
[0.3.1]: https://www.npmjs.com/package/brainchain-verify/v/0.3.1
[0.3.0]: https://www.npmjs.com/package/brainchain-verify/v/0.3.0
[0.2.2]: https://www.npmjs.com/package/brainchain-verify/v/0.2.2
[0.2.1]: https://www.npmjs.com/package/brainchain-verify/v/0.2.1
[0.2.0]: https://www.npmjs.com/package/brainchain-verify/v/0.2.0
[0.1.3]: https://www.npmjs.com/package/brainchain-verify/v/0.1.3
[0.1.2]: https://www.npmjs.com/package/brainchain-verify/v/0.1.2
[0.1.1]: https://www.npmjs.com/package/brainchain-verify/v/0.1.1
[0.1.0]: https://www.npmjs.com/package/brainchain-verify/v/0.1.0
