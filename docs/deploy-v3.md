# Deploying v3 and handing over admin

v3 replaces every contract of the v2 deployment. Nothing in v2 is upgradeable, so v3 is a fresh deployment, and the $BRAIN fee recipient must be the v3 `FeeSplitter` from the launch transaction onward.

## What the owners provide

- **A second signer** for each 2-of-2 Safe: one Safe on Robinhood Chain and one on BrainChain. The deployer key can be the first signer at the start; the goal is that no single key holds admin powers.
- A Safe on BrainChain needs the Safe contracts deployed there first (through the Safe singleton factory, or deployed at our own addresses with the Safe CLI).

## Order

1. **Robinhood Chain, before $BRAIN launches.** Run [`script/DeployRewards.s.sol`](../script/DeployRewards.s.sol) with `OWNER_SAFE`, `PUBLISHER`, `TREASURY` and `PONS_ESCROW` (`0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e`). It deploys the `RewardDistributor`, the `FeeSplitter` and the rollup's admin timelock. The reward contracts are owned by the Safe directly, because the owner must be able to revoke a bad round inside its 24-hour claim delay.
2. **Launch $BRAIN on Pons** with the v3 `FeeSplitter` as creator fee recipient, the native ETH pair, and buyback off. Then bind the curve from the deployer: `bindCurve` only accepts a curve that pays this splitter through this escrow.
3. **BrainChain.** Deploy the Safe, then run [`script/DeployMainnet.s.sol`](../script/DeployMainnet.s.sol) with `ADMIN_SAFE`, `BRAIN`, `USDG`, `FEE_RECIPIENT` and the five `WORKER_*` accounts. It deploys the admin timelock (48 hours, the Safe its only proposer and executor), the `DecisionLog` owned by it, the `ModelRegistry`, the `DecisionExecutor` and the `TaskBoard`, sets the 3% fee, and binds the board. The deployer is the guardian until step 6.
4. **Point the services at v3**: new addresses and ABIs. Task decisions name `TaskBoard.subjectOf(taskId)` and change decisions `DecisionExecutor.changeSubject(target, data)`; the `Task` struct gained fields at the end; `Ruled`, `BountyPaid`, `BountyRefunded` and `FeeTaken` gained fields. Fund the new house treasury. v2 tasks in flight settle on the v2 board as before; the v2 house treasury can move to v3 through a v2 change, or stay.
5. **Chain-level handover.** Run [`script/AdminHandover.s.sol`](../script/AdminHandover.s.sol) with `L3_ADMIN` and `ROLLUP_ADMIN`. It prints six transactions and sends none. Review them, then send them from the deployer in the printed order: four on BrainChain (the UpgradeExecutor becomes chain owner, the admin timelock gets `EXECUTOR_ROLE`, the deployer stops being chain owner and loses the role) and two on Robinhood Chain (the rollup timelock gets the rollup UpgradeExecutor's `EXECUTOR_ROLE`, the deployer loses it). [`test/fork/AdminHandover.t.sol`](../test/fork/AdminHandover.t.sol) replays the UpgradeExecutor steps on forks of both chains.
6. **Guardian to the Safe.** The Safe proposes `DecisionExecutor.setGuardian(safe)` through the BrainChain admin timelock; after 48 hours it executes, and the board's guardian follows.

After step 5, upgrading BrainChain's bridged tokens, changing chain parameters or changing the rollup needs the Safe and 48 hours of notice. After step 6, pausing and vetoing need the Safe.
