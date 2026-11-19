# Changelog

Changes to `brainchain-verify`, the npm package built from this directory. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are npm publish dates, in UTC.

## [0.8.0] - unreleased

### Added

- `--record <agentId>` checks an agent's numbered record on the brain host. Entries are read from the first, a page at a time. They must be numbered with no gap, each naming the hash of the one before, each signed by the brain key it names, and all for the agent asked for. The signed head must end at the last entry with its hash and be at most 15 minutes old. Each receipt an entry names is fetched, hashed and checked with its decision. The report counts each epoch's entries by kind and outcome.
- `record-brain` holds every signing key to the chain. The DecisionLog an entry names must belong to a contract set the tool carries, its `BrainSet` events must name the key, and the entry's `issuedAt` must fall within that key's time as brain, give or take five minutes. A head must name the active set's DecisionLog.
- `--epoch` with `--record` reads the ERC-8004 identity registry on Robinhood Chain for the epoch the agent's id is in now, through a binding adapter where the id is bound to an NFT, and says which entries belong to it. An agent BrainChain runs itself has the build `house: <model id>`, which the registry does not hold. For it the build is read from the newest entry, the controller alone is compared with the registry, and the line says so. The `house:` prefix is BrainChain's own, so it is removed from a build read from the registry, as the brain removes it.
- `--licence <agentId>` checks each licence the brain host lists: its signature, its signing key, its expiry and the epoch the registry gives the id now. The state these give must be the state the host gives, in the host's order: `expired` once past the expiry, before that `suspended` as the host gives it, before that `lapsed` while the id is in another epoch, otherwise `valid`. `licences-epoch` holds the epoch the host's reply gives for the id to the registry. A reply that says it read the registry has every state held to that epoch, and one that says it could not is an `ERROR` on that line. For a licence whose build BrainChain states itself, the reply's epoch decides between `valid` and `lapsed`.
- `--papers <agentId>` checks an agent's papers: the signed text holds the papers the file shows, the brain key of the active DecisionLog signed it within the last 15 minutes, and the record head it names is an entry of the record its signed head ends. `papers-epoch` holds the epoch the papers state to the one the identity registry gives the id now. The host keeps signed papers for up to a minute, so papers signed before the id changed hands fail it, and the verdict is `STALE`, exit 1, when nothing else failed.
- `--item <itemId>` checks a retired exam item: the item without its id, as canonical JSON, hashes to its id.
- `--service <url>` names another brain host for these four. The defaults are `https://brain.usebrainchain.com` on mainnet and `https://brain.testnet.usebrainchain.com` on testnet.
- `--entry` and `--agent` read an entry whose `feedbackURI` serves an entry of the agent's record. The new lines are `entry-record`, `entry-signature`, `entry-brain` and `entry-outcome`, then `record-receipt` and `record-settled` when the record entry names a receipt, which is checked with its decision as before. An exam outcome, written under `licence:<class>`, is read the same way. In JSON such an entry carries `record`.
- `--payment-rpc <url>` reads a receipt's payment on Robinhood Chain, or its testnet with `testnet`, from another RPC, such as a fork or your own node. It must serve that chain, as `--rpc` and `--registry-rpc` must serve theirs. Without it, the public RPC is read as before.
- `verifyRecord`, `verifyLicences`, `verifyPapers`, `verifyItem`, `currentEpoch`, `epochId`, `entryHash`, `recordUrl`, `SERVICES` and `PAYMENT_RPCS` are exported, with their types.

### Changed

- `receipt` and `receipt-decision` read receipt version 2, signed under domain version "2" with the decision's `subject` after `decision`. The subject must be the decision's subject on the log. A version 1 receipt checks as before, and a version 2 receipt without a subject, or a version 1 receipt with one, is not a receipt.
- `evidence` reads evidence version 2, which the brain writes from release 9: the hash also covers the panel's rule, a degraded panel's bar, the grade's pass level and the record's `checks`, so a copy served without the work cannot say the brief's checks ran otherwise. The tool rebuilds the hash under both versions and holds the record to the one its `Recorded` event carries, so a record decided under version 2 cannot pass as version 1. A version 1 record verifies as before, and its line says so.
- `--registry-rpc` is also read by `--licence` and `--papers`, and by `--record` with `--epoch`.
- The `entry` check takes `licence:<class>` as a second tag beside `task`.
- `summary.withReceipt` counts an entry that points at a record entry only when that record entry names a receipt.
- `withheld`, `threshold` and `receipt-outcome`: a line about a decision's recorded answer now says BrainChain answered, because a panel can give that answer.
- An id the tool refuses gets a message with the rule it is held to: an agent id is a whole number written without leading zeros, as the brain host requires, and a decision or task id is one from 1. The ids it refuses are the same as in 0.7.1.
- A host that answers with an error and a reason, as `{ "error": "..." }`, has its reason on the `ERROR` line, a 404 included. A 403 for a record, which the brain host sends for an exam decision while its item is still in use, also says that the decision becomes verifiable once its item is published.

### Fixed

- The README said receipts were not yet live on mainnet, gave version 1 as the receipt's only domain version and listed only evidence version 1's fields. It describes receipts and evidence under both versions.

An entry that points straight at a receipt, and every decision and receipt, verify exactly as in 0.7.1.

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
