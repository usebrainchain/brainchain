# Changelog

Changes to `brainchain-verify`, the npm package built from this directory. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are npm publish dates, in UTC.

## [Unreleased]

### Added

- `brainchain-verify/zerox` checks an answer from 0x's Swap API before it is signed: 0x's RFC 9421 response signature (key by `keyid`, 60 seconds, the body's digest, the request's method, host, path and query), then the AllowanceHolder transaction, decoded and held to the caller's intent: AllowanceHolder as target, the Settler from 0x's registry, the token and amount sold, the value, the recipient and the least bought. It works for answers bought through 0x's keyless gateway, whose requests 0x signs as the Swap API requests they forward. Tested on answers recorded on Robinhood Chain. See [0x quotes](README.md#0x-quotes).

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
