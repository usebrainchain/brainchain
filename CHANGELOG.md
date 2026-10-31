# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `ProofsIncome`, the payee of the $BRAIN launch on ripples.run (Robinhood Chain 4663): unwraps the WETH the launch treasury pays it and splits it half to the holders of BrainChain Proofs, one part per piece, a quarter to the `FeeSplitter` and a quarter to the owners' Safe. Deployed by `script/DeployProofsIncome.s.sol` at `0xeb1b4168d4b87d3d9f0d64e13b7071251bbb63b7`.

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
