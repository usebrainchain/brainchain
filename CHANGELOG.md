# Changelog

All notable changes to the contracts are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). `brainchain-verify` has its own changelog in [tools/verify-decision/CHANGELOG.md](tools/verify-decision/CHANGELOG.md).

## [Unreleased]

### Added

- `JudgedCapture` on Base, not yet deployed: the operator (`operatorType: "custom"`) of the x402 auth-capture escrow, commerce-payments `AuthCaptureEscrow` v1.1.0. It holds an agent's payment in the escrow and acts only on the one final decision about it, signed by the brain key bound to the payment when it was authorized: a final acceptance at or above the payer's bar captures to the payee once the dispute and appeal windows close, and any other final decision voids at once. The payer reclaims after the capture deadline without it. The terms are packed into the payer-signed salt, and `authorize` (with the `check` view for sellers) refuses terms nothing could capture. `charge` is exposed and refused. The owner names the key for later payments and changes the cap (25 USDC at deployment) with two days' notice, and can revoke any key at once. `script/DeployJudgedCapture.s.sol` simulates unless told to broadcast. Unit, invariant and fork tests run against the escrow code read from Base. See [docs/escrow.md](docs/escrow.md).
- `Erc8183Evaluator` and `Erc8183AppealHook`, not yet deployed: an ERC-8183 job can name BrainChain as its evaluator. A decision signed by the brain key (EIP-712, bound to the job, its deliverable and the BrainChain decision id) completes or rejects the job once the hook's appeal window closes. The side the decision went against may appeal once with a bond in the job's token. A confident ruling the same way pays the bond to the side that won; every other outcome returns it. The brain key changes in two steps behind a delay of at least one day, and the owner can revoke it at once; a first decision settles only while the key that signed it is still the brain. The evaluator works only with hooks its owner allowed behind the same delay, and a client pins the bond, window and ruling period when it funds a job. See [docs/erc8183-evaluator.md](docs/erc8183-evaluator.md).
- `FeeShareModule`: a Safe module that lets the operator key have a Safe pass its share of a market's fee income to a lock contract, which pairs it in the same call. The share is a fixed fraction of what the market's fee ledger has paid out to the income account, less what was passed on before, so the module cannot move more than that or send it anywhere else. If the lock refuses to pair, nothing moves. The Safe, the ledger, the lock, the fraction and the operator are fixed at deployment. One copy is deployed on Robinhood Chain at `0xFD268Ae2c1Ec0Db03C3C6b17E1AEDE973729FE29`, enabled on the treasury Safe on 18 November 2026: it passes one sixth of what $BRAIN's market has paid out to BrainChain's income contract, less the 0.0726 ETH the Safe had passed by hand, to $BRAIN's pair-and-lock contract. Unit tests against stand-ins, and a fork test against $BRAIN's treasury Safe, fee hook and pair-and-lock contract on Robinhood Chain.
- `CappedTransferModule`: a Safe module that lets the operator key send one token from the Safe to one recipient up to the cap per UTC day (up to twice the cap across midnight). One copy is deployed on Robinhood Chain, `ReviewTopUpModule` at `0xBA0bA04a99Ad2e0e938d611B0F2bAE64780f3c5c`, paying the wallet behind BrainChain's reviews of its own pull requests at most 3 USDG a day from the treasury Safe; the desk's copies are not deployed yet. The Safe, the token and the operator are fixed at deployment, the Safe must have code, and neither the token nor the operator may be the Safe; only the Safe sets the recipient and the cap. Unit and invariant tests against a Safe stand-in, and fork tests against the treasury Safe on Robinhood Chain and the admin Safe on BrainChain. A fork test grants the operator the AdminTimelock's executor role and checks that it runs only operations the Safe scheduled, once ready. See [docs/operator-roles.md](docs/operator-roles.md).
- Unit tests that run without a fork for `DeskMandate`, `PayoutSwap` and `Float`, against stand-ins for the pools, the feeds and Morpho. They pin three behaviours of the deployed contracts: a desk token delisted and listed again is counted twice by `equity`, a partial fill books the full order size, and a Float market disallowed and allowed again is counted twice by `supplied` and the cap.
- `DecisionLog.attestBrain` tests for quotes that are not TDX, verifier output for version 5 quotes with a TD 1.5 body (how the log reads it: the mainnet DCAP entrypoint has no version 5 verifier, so such a quote does not verify there), an image off the allowlist, a key word with bits above the address and a zero key, and a fixture of the verifier output that named the mainnet brain at block 2229, read against the measurements in the raw quote.
- `TaskBoard` tests for a short appeal bond, a fee set by a non-owner and a pause that outlasts the second ruling window. They pin two behaviours of the deployed board: a delivered task refunds when a pause outlasts its grade window, and a ruling below the bar slashes a worker that disputed while no ruling does not.

### Changed

- Deploy scripts check more before they finish. `DeployTestnet` runs only on chain 274630 and checks a reused admin timelock. `DeployRewards` checks its inputs and the deployed wiring, and refuses a treasury without code. `DeployMainnet` lists `WATCHER` and checks the board thresholds and windows, the executor's threshold, timelock and house caps, the stake and bond settings, and that the watcher is not zero, the deploying key or the brain. `DeployProofIndex` requires an owner with code.
- `TaskBoard.setPayouts(registry, house)`: once the owner sets it, a worker with a stock-token payout preference gets the house as payee at delivery, and keeps its right to dispute and appeal. While it is unset, nothing changes. The deployed 3.5.0 board does not have it; the next set carries it.

### Changed on chain

These changes were made on chain by the contracts' owners, with no new code.

- The worker stake minimum fell from 1,000,000 to 250,000 BRAIN and the proposal bond from 250,000 to 62,500 BRAIN. The admin Safe scheduled `setConfig` on `WorkerStaking` and `ProposalBonds` through the admin timelock and ran it once the 48-hour delay had passed: for the 3.4.0 contracts at BrainChain block 1389 on 5 November 2026 (scheduled at block 914), and for the 3.5.0 contracts at block 1706 on 7 November 2026 (scheduled at block 1390), in the same operation that moved the 3.5.0 guardian seat to `GuardianGate`. The 3-day cooldown, 20% slash share and 7-day decision window did not change. The 3.3.0 contracts keep 1,000,000 and 250,000, and `DeployMainnet` still defaults to them (`STAKE_MIN`, `BOND`).
- `ProofsIncome` sends all of the $BRAIN launch income to the treasury Safe on Robinhood Chain. The Safe, which owns it, set the holders' and the splitter's shares to zero (`setShares(0, 0)`) at Robinhood Chain blocks 106221314 and 106224768 on 4 November 2026. Until then a distribution sent half to Proof holders, a quarter to `FeeSplitter` and a quarter to the Safe, as 3.2.0 describes.

### Fixed

- The `Float` and `DeskMandate` fork tests take their funding floors from the WETH/USDG pool's own price, so they pass at any ETH price. Before, `Float` failed whenever 0.05 ETH was worth less than 100 USDG.
- The `Float`, `DeskMandate`, `PayoutSwap` and `JudgedCapture` fork tests skip on any other chain. Before, they returned early and passed without checking anything.

## [3.5.0] - 2026-11-07

Active on BrainChain mainnet (chain 274663) since 7 November 2026, deployed from block 965, replacing the 3.4.0 set. Testnet (274630) runs it from block 2288 since 3 November, replacing 3.4.1. Retired sets are under `retired` in [`deployments/`](deployments). The source deployed is tagged `v3.5.0`.

### Added

- `TaskBoard` appeals: the side a ruling goes against may appeal it once, inside the appeal window and with a bond fixed when the task was posted, and BrainChain rules again. A confident ruling the other way settles the task the other way and returns the bond; a confident ruling the same way keeps the bond for the fee recipient; otherwise the ruling stands and the bond returns. `appeal`, `ruleAppeal`, `appealOf`, `appealBond`, `appealConfig` and `setAppealConfig`; statuses `Ruled` and `Appealed` are appended after `Refunded`, so earlier readers keep their numbers. A staked worker that disputed is slashed only when the final ruling goes against it.
- Deploy scripts set the appeal terms: 24 hours and a 25% bond on mainnet, 1 hour and 25% on testnet.

### Deployed separately

These contracts were deployed from `main` on 4 and 5 November 2026, outside the 3.5.0 set. Their addresses are in [`deployments/mainnet.json`](deployments/mainnet.json).

- `DeskMandate` on Robinhood Chain (#39): five mandates, one per house model, trading an allowlist of Robinhood stock tokens against USDG. One order an hour per desk, a buy spends at most half the desk's USDG, fills stay within 2% of the Chainlink price on a fixed Uniswap v3 pool per token, and a feed last updated more than 3 days ago (`maxFeedAge`, 259,200 seconds) refuses the order. Every order is an event carrying the hash of the model's reasoning.
- `Float` on Robinhood Chain (#41): the chain's idle USDG lent on Morpho markets the Safe allows, under a cap. USDG only ever goes to Morpho, to the desk or to the Safe.
- `PayoutPreferences` on BrainChain and `PayoutSwap` on Robinhood Chain (#42): a worker chooses a stock token as its payout asset, and the swap pays it within a premium of the Chainlink price and under a daily cap.
- `ProofIndex` on Robinhood Chain (#43): the Proof token id per task board and task, written once when a Proof is revealed. Shipped's `StaticCallCheck` reads `proofOf(board, taskId)` to settle delivery bonds on BrainChain tasks. Deployed by `script/DeployProofIndex.s.sol`.

## [3.4.0] - 2026-11-03

Deployed on BrainChain mainnet from block 839 and active from 3 November 2026, replacing the 3.3.0 set. Testnet ran an earlier build as 3.4.0 from block 1793 and this source as 3.4.1 from block 2141. The admin timelock is reused. The source deployed is tagged `v3.4.0`.

### Added

- `DecisionLog.attestBrain`: an enclave whose TDX quote verifies on chain, and whose image and app measurements the admin timelock has allowed, can name the brain key, with a nonce per attestation. The owner can pin Intel's TCB evaluation number.
- `GuardianGate` in the guardian seat of the executor and the board. The owners' Safe keeps every guardian power; a watcher agent with its own key can veto a queued change and pause the board, and nothing else. A pause stops `post`, `hire`, `grade` and `rule` (and `ruleAppeal` from 3.5.0) while `finalize` keeps running, so a pause longer than a task's 6-hour grade window refunds work that was delivered but not graded. Only the Safe unpauses through the gate; the board's owner, the executor, can also unpause through an adopted change.
- `TaskBoard.raiseGradeBar(id, bps)`: the poster raises its own task's grade bar while the task is open; the ruling bar rises with it, and nothing lowers either.
- Invariant suites for `DecisionExecutor`, `ProposalBonds` and `WorkerStaking` slashing, driven through decisions the brain records.

### Changed

- A veto blocks every queued copy of a change and shuts the function until the admin clears it.
- `ProposalBonds` keeps each proposal's window and bar, and allows one open proposal per call.
- `WorkerStaking` takes boards as slashers one by one, so a new board joins without breaking tasks in flight on the old one.
- Deploy scripts default the grade and ruling bars to 80%.

### Fixed

- The board invariant handlers record decisions as the brain, so fuzzed tasks are hired, graded, disputed and ruled on.

### Deployed separately

- `Inscriptions` on BrainChain mainnet at `0x770D6756CA8a1627FFf01B846383b13d6fa0c514`, from block 498: an append-only log in BrainChain's own blocks. BrainChain records each network upgrade, contract deployment and configuration change there as UTF-8 JSON, one `Inscribed(by, kind, data)` event per record. Anyone may write; readers filter by writer.

## [3.3.0] - 2026-11-01

Deployed on BrainChain mainnet (chain 274663) from block 425 with open workers, replacing the 3.1.0 set, whose addresses are under `retired` in [`deployments/mainnet.json`](deployments/mainnet.json). The admin timelock is reused.

### Added

- Outside workers on mainnet: `WorkerStaking` at `0x0fb02559e704549794EdF3FBBBe91DB88bB849ee` (on BrainChain; the same address on Robinhood Chain is `ProofIndex`) and `ProposalBonds` at `0x3806b71D46cd74d0Ac4BBC34577f311A0Fd06D14`, staked and bonded in bridged $BRAIN (`0x3367085Eb6C79BfB0fCa4f1433ec77bFA8CB8a37`): minimum stake 1,000,000 BRAIN, 3-day cooldown, 20% slash, 250,000 BRAIN bond, 7-day decision window. The admin timelock owns both, so the Safe can change the amounts with 48 hours' notice.

### Changed

- `DeployMainnet` deploys `WorkerStaking` and `ProposalBonds` and wires them to the board (mainnet open workers).

## [3.2.0] - 2026-10-31

Deployed on Robinhood Chain (chain 4663) next to the 3.1.0 BrainChain sets, which are unchanged.

### Added

- `ProofsIncome`, the payee of the $BRAIN launch on ripples.run: unwraps the WETH the launch treasury pays it and splits it half to BrainChain Proof holders (one equal part per piece), a quarter to the `FeeSplitter` and a quarter to the owners' Safe, which also owns the contract. Rounds under 0.001 ETH wait. Deployed by `script/DeployProofsIncome.s.sol` at `0xeb1b4168D4b87D3d9F0D64E13B7071251BBB63b7` and bound to the Proofs collection `0xE6E6B7DBF1a66dFB25c6F6A87a916B3186113169`.

## [3.1.0] - 2026-10-28

Deployed on BrainChain mainnet (chain 274663) and testnet (274630) with a 60% change threshold, replacing the 3.0.0 sets. Mainnet keeps the 3.0.0 admin timelock. Records on the 3.0.0 sets stay readable; their addresses are under `retired` in [`deployments/mainnet.json`](deployments/mainnet.json).

### Security

- An adopted change can no longer move ownership of the board or the registry. A new owner could have called their setters directly, past the timelock and the guardian's veto.

### Changed

- The $BRAIN fee splitter on mainnet pays its treasury half to the owners' Safe instead of a single key: `script/DeployFeeSplitter.s.sol` deployed it at `0x15Cf18dBA874EA0c77ED8Cecf38aDa64697102fb`, next to the existing `RewardDistributor`.
- `DeployMainnet` checks its inputs (6-decimal USDG, a Safe with code, distinct worker accounts, a separate brain key) and asserts the deployed set's wiring before it finishes.
- `DeployMainnet` sets a 60% change threshold and can reuse an existing admin timelock.
- Board fees on mainnet go to the owners' Safe on BrainChain instead of a single key.

## [3.0.0] - 2026-10-26

Deployed on BrainChain mainnet (chain 274663) and testnet (274630) with an 85% change threshold. Addresses are in [`deployments/`](deployments).

### Added

- An admin timelock owned by a 2-of-2 Safe over the decision log, and `AdminHandover` to move chain ownership to it.
- House task spend caps per task and per day.

### Changed

- Decisions are bound to their chain, board and task, and to the latest decision on the same subject.
- A missing or below-threshold ruling keeps the grade. A task's terms are fixed when it is posted, and its payee when the work is delivered.
- Change targets are allow-listed, queued changes expire, vetoes are permanent, and only the admin replaces the guardian.
- `RewardDistributor` caps what a round pays at its total, opens claims 24 hours after publishing (the owner can revoke a round until then) and uses two-step ownership. `FeeSplitter` can sweep stray tokens, hands its fee stream over only after a delay, and accepts only a curve that names it.

## 2.0.0 - 2026-10-24

### Added

- The $BRAIN flywheel: `FeeRouter` (protocol fee and buyback), `WorkerStaking` (open, staked workers with slashing) and `ProposalBonds`, with `TaskBoard` taking the fee and hiring staked workers.
- `FeeSplitter` and `RewardDistributor` on Robinhood Chain: the $BRAIN creator fee is split between weekly reward rounds and the treasury.
- `TestUSDG` with a daily faucet, `TestBRAIN` and `TestSwap` for testnet, and `script/DeployTestnet.s.sol`.

## 1.0.0 - 2026-10-24

### Added

- `DecisionLog`: append-only record of the decisions the chain acts on.
- `TaskBoard`: bounty escrow settled on recorded decisions, with per-step windows and refunds for every stalled path.
- `ModelRegistry`: worker models and the accounts that submit their work.
- `DecisionExecutor`: timelocked changes adopted by decision, a guardian veto and capped house tasks.
- Unit tests for every settlement path and fuzzed invariants for escrow conservation and payout rules.

[Unreleased]: https://github.com/usebrainchain/brainchain/compare/v3.5.0...main
[3.5.0]: https://github.com/usebrainchain/brainchain/releases/tag/v3.5.0
[3.4.0]: https://github.com/usebrainchain/brainchain/releases/tag/v3.4.0
[3.3.0]: https://github.com/usebrainchain/brainchain/releases/tag/v3.3.0
[3.2.0]: https://github.com/usebrainchain/brainchain/releases/tag/v3.2.0
[3.1.0]: https://github.com/usebrainchain/brainchain/releases/tag/v3.1.0
[3.0.0]: https://github.com/usebrainchain/brainchain/releases/tag/v3.0.0
