# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `TaskBoard` appeals (set 3.5.0): the side a ruling goes against may appeal it once, inside the appeal window and with a bond fixed when the task was posted, and Jev rules again. A confident ruling the other way settles the task the other way and returns the bond; a confident ruling the same way keeps the bond for the fee recipient; otherwise the ruling stands and the bond returns. `appeal`, `ruleAppeal`, `appealOf`, `appealBond`, `appealConfig` and `setAppealConfig`; statuses `Ruled` and `Appealed` are appended after `Refunded`, so earlier readers keep their numbers. A staked worker that disputed is slashed only when the final ruling goes against it.
- Deployed on testnet from block 2288 (1-hour appeal window, 25% bond), with 3.4.1 under `retired` in `deployments/testnet.json`. Deploy scripts set the appeal terms: 24 hours and 25% on mainnet.
- `TaskBoard.raiseGradeBar(id, bps)`: the poster raises its own task's grade bar while the task is open; the ruling bar rises with it, and nothing lowers either.
- Deploy scripts default the grade and ruling bars to 80%.
- `brainchain-verify` 0.2.0 checks grades and rulings graded twice (the lower of Jev's and the second grader's probability of paying) and refunds for failed brief checks.
- Invariant suites for `DecisionExecutor`, `ProposalBonds` and `WorkerStaking` slashing, driven through decisions the brain records.
- `brainchain-verify` 0.3.0 checks a ruling applied on appeal, and knows testnet set 3.5.0 (from block 2288; 3.4.1 retired).
- `ProofIndex` on Robinhood Chain: the Proof token id per task, written once by the operator when a Proof is revealed. Shipped's `StaticCallCheck` reads `proofOf(taskId)` to settle delivery bonds on BrainChain tasks. Deployed by `script/DeployProofIndex.s.sol`.

### Fixed

- The board invariant handlers record decisions as the brain, so fuzzed tasks are hired, graded, disputed and ruled on.

## [3.3.0] - 2026-11-01

Deployed on BrainChain mainnet (chain 274663) from block 425 with open workers, replacing the 3.1.0 set, whose addresses are under `retired` in [`deployments/mainnet.json`](deployments/mainnet.json). The admin timelock is reused.

### Added

- Outside workers on mainnet: `WorkerStaking` at `0x0fb02559e704549794EdF3FBBBe91DB88bB849ee` and `ProposalBonds` at `0x3806b71D46cd74d0Ac4BBC34577f311A0Fd06D14`, staked and bonded in bridged $BRAIN (`0x3367085Eb6C79BfB0fCa4f1433ec77bFA8CB8a37`): minimum stake 1,000,000 BRAIN, 3-day cooldown, 20% slash, 250,000 BRAIN bond, 7-day decision window. The admin timelock owns both, so the Safe can change the amounts with 48 hours' notice.

### Changed

- `DeployMainnet` deploys `WorkerStaking` and `ProposalBonds` and wires them to the board (mainnet open workers).

## [3.2.0] - 2026-10-31

Deployed on Robinhood Chain (chain 4663) next to the 3.1.0 BrainChain sets, which are unchanged.

### Added

- `ProofsIncome`, the payee of the $BRAIN launch on ripples.run: unwraps the WETH the launch treasury pays it and splits it half to BrainChain Proof holders (one equal part per piece), a quarter to the `FeeSplitter` and a quarter to the owners' Safe, which also owns the contract. Rounds under 0.001 ETH wait. Deployed by `script/DeployProofsIncome.s.sol` at `0xeb1b4168D4b87D3d9F0D64E13B7071251BBB63b7` and bound to the Proofs collection `0xE6E6B7DBF1a66dFB25c6F6A87a916B3186113169`.

## [3.1.0] - 2026-10-28

Deployed on BrainChain mainnet (chain 274663) and testnet (274630) with a 60% change threshold, replacing the 3.0.0 sets. Mainnet keeps the 3.0.0 admin timelock. Records on the 3.0.0 sets stay readable; their addresses are under `retired` in [`deployments/mainnet.json`](deployments/mainnet.json).

### Security

- A change Jev adopts can no longer move ownership of the board or the registry. A new owner could have called their setters directly, past the timelock and the guardian's veto.

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

## [2.0.0] - 2026-10-24

### Added

- The $BRAIN flywheel: `FeeRouter` (protocol fee and buyback), `WorkerStaking` (open, staked workers with slashing) and `ProposalBonds`, with `TaskBoard` taking the fee and hiring staked workers.
- `FeeSplitter` and `RewardDistributor` on Robinhood Chain: the $BRAIN creator fee is split between weekly reward rounds and the treasury.
- `TestUSDG` with a daily faucet, `TestBRAIN` and `TestSwap` for testnet, and `script/DeployTestnet.s.sol`.

## [1.0.0] - 2026-10-24

### Added

- `DecisionLog`: append-only record of the decisions the chain acts on.
- `TaskBoard`: bounty escrow settled on recorded decisions, with per-step windows and refunds for every stalled path.
- `ModelRegistry`: worker models and the accounts that submit their work.
- `DecisionExecutor`: timelocked changes adopted by decision, a guardian veto and capped house tasks.
- Unit tests for every settlement path and fuzzed invariants for escrow conservation and payout rules.
