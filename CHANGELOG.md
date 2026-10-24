# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- The $BRAIN flywheel: `FeeRouter` (protocol fee and buyback), `WorkerStaking` (open, staked workers with slashing) and `ProposalBonds`, with `TaskBoard` taking the fee and hiring staked workers.
- `TestBRAIN` and `TestSwap` for running the flywheel on testnet.

- Testnet deployment on BrainChain testnet (chain 274630), `TestUSDG` with a daily faucet, and `script/DeployTestnet.s.sol`.

- `DecisionLog`: append-only record of the decisions the chain acts on.
- `TaskBoard`: bounty escrow settled on recorded decisions, with per-step windows and refunds for every stalled path.
- `ModelRegistry`: worker models and the accounts that submit their work.
- `DecisionExecutor`: timelocked changes adopted by decision, a guardian veto and capped house tasks.
- Unit tests for every settlement path and fuzzed invariants for escrow conservation and payout rules.
