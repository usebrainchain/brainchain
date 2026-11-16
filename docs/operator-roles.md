# Operator roles

BrainChain's operator key, `0x70C665780E43BA1496a4E691e408F24844dB58eC`, runs routine jobs around the clock. Two of those jobs wait for both Safe owners to sign: topping up the desk's USDG, and executing a timelock operation once its delay has passed. This page describes a narrow power for each. Neither is in place for these jobs yet: the desk's copies of `CappedTransferModule` are not deployed, and the operator does not hold the timelock's executor role. One copy of the module is live for another recipient, described below. With both in place, the owners keep every other power and can take either one back with a Safe transaction.

## Keys

Every key that holds a role in the deployed contracts, read from the contracts on 16 November 2026. The admin Safe on BrainChain and the treasury Safe on Robinhood Chain each need both of their owners to sign, and each can replace the keys below on the contracts it owns.

| Key | Address | Chain | What it can do |
| --- | --- | --- | --- |
| Brain | `0xB72d772669cD8d3CdF7a4855Bd1B752e3792B589` | BrainChain | Record decisions in `DecisionLog`, apply them to tasks, queue adopted changes on `DecisionExecutor`, and post house tasks within the caps. The key changes with each enclave release: the new enclave names its own key with a fresh quote (`DecisionLog.attestBrain`), so read the current one from `DecisionLog.brain()` |
| Watcher | `0xc29D469AD0b802b8Cf65E1c38fccF1428BcBAB13` | BrainChain | Through `GuardianGate`, veto a queued change and pause the board. It cannot unpause. The admin Safe replaces it at once with `GuardianGate.setWatcher`, without a timelock |
| Deployer key | `0x8D4b5d7E287ddf83C440a19b2DD6037F58723660` | Both | One of the two owners of the admin Safe and of the treasury Safe. Owns Automata's DCAP entrypoint, `0x94552cb7C8806fAD00c4EB59182E98C5Ba4bBfcb`, so it can change how enclave quotes are verified without a delay ([architecture](architecture.md#the-quote-check)). Can bind a curve to `FeeSplitter` once; none is bound |
| Second Safe owner | `0xbbCB24B44399460005e1e89e4045607ceaF48914` | Both | The other owner of the admin Safe and of the treasury Safe |
| Desk operator | `0x97D558417c3D61f1074422AD843e1Db1E565b952` | Robinhood Chain | Trade for the five desks through `DeskMandate.trade`, within its bounds. Pay a worker in a stock token through `PayoutSwap.pay`, swapping USDG it holds within 2% of the Chainlink price and 500 USDG a UTC day. The treasury Safe replaces it with `setOperator` on either contract |
| ProofIndex operator | `0x415e4DB7D4D79FE3A2D2CAE24BA7a6c06b45bad8` | Robinhood Chain | Record the Proof token id of a task with `ProofIndex.setProof`, once per board and task |
| RewardDistributor publisher | `0x6aF0915c1e90349C09dE4409C3d7e6D8eA4A2a85` | Robinhood Chain | Publish a reward round with `RewardDistributor.publish`, allocating no more ETH than the distributor holds unallocated. The treasury Safe can revoke a round for 24 hours after it is published |
| Review top-up operator | `0x70C665780E43BA1496a4E691e408F24844dB58eC` | Robinhood Chain | BrainChain's operator key. Send USDG from the treasury Safe to `0xFe4d9d7c5c530c9652A46D0BF6178b041Bc2F858` through `ReviewTopUpModule.send`, at most 3 USDG per UTC day, as described below |
| Float desk | `0xafB0C4Ef895D4895040cdC6435B96D3EE8350c6E` | Robinhood Chain | Nothing on the Float. It is the only address the Float's operator can release USDG to; the treasury Safe changes it with `Float.setDesk` |
| ProofsIncome deployer | `0xf07eb9C975dC7947F66D0483084ff13efCf5427f` | Robinhood Chain | Nothing now. It could bind the Proofs collection once, and bound `0xE6E6B7DBF1a66dFB25c6F6A87a916B3186113169` |

## Desk top-ups

[`CappedTransferModule`](../src/safe/CappedTransferModule.sol) is a Safe module. Each copy pays one recipient from one Safe, so a Safe can hold several copies. The desk's copies, one on the treasury Safe on Robinhood Chain and one on the admin Safe on BrainChain, are not deployed yet. One copy is live, `ReviewTopUpModule` at `0xBA0bA04a99Ad2e0e938d611B0F2bAE64780f3c5c`: it pays the wallet behind BrainChain's reviews of its own pull requests, from the treasury Safe on Robinhood Chain, at most 3 USDG per UTC day. Each copy's address is added to `deployments/mainnet.json` when it is deployed.

The operator can call `send(amount)`, which moves USDG from the Safe to the module's recipient (the desk, for the desk's copies). All sends in one UTC day together stay within the cap. Days are calendar days, so across midnight the operator can send up to twice the cap within seconds: the full cap at 23:59:59 and again at 00:00:00.

The operator cannot:

- send another token, or ETH;
- send to any address other than the recipient;
- change the recipient or the cap;
- make the Safe call anything else, or delegatecall.

The Safe, the token and the operator are fixed when the module is deployed. Only a transaction from the Safe sets the recipient and the cap. A lower cap applies at once, to what is left of the current day as well. A send that would go over what is left of the cap is refused, and so is one whose token transfer fails or returns false.

Every send emits `Sent` with the recipient, the amount, the day's total and the cap. Every change emits `RecipientSet` or `CapSet`.

| To | Safe transaction | Takes effect |
| --- | --- | --- |
| Pause top-ups | `setCap(0)` on the module | At once |
| Change the desk | `setRecipient(address)` on the module | At once |
| Remove the power | `disableModule(prevModule, module)` on the Safe | At once |

A disabled module can send nothing, whatever its settings.

## Executing ready timelock operations

The AdminTimelock on BrainChain, `0xB23F49390061B1E7Faf0F99B146E491Ee1574B1e`, holds the admin powers over the decision logs, the executors and the boards. It is OpenZeppelin's `TimelockController` with a 48-hour delay. The admin Safe is its only proposer, its only canceller and its only executor. The timelock alone holds the admin role over its own roles.

With the executor role, the operator can execute an operation the Safe scheduled, once its delay has passed. An operation is identified by the hash of its targets, values, calldata, predecessor and salt, so the operator can run only exactly what the Safe scheduled. The timelock refuses an operation that was never scheduled, one still waiting out its delay, one already executed, and one whose predecessor has not run.

The operator cannot:

- schedule an operation, which needs the proposer role;
- cancel one, which needs the canceller role;
- grant or revoke a role, or change the delay, which only the timelock itself can do through an operation the Safe scheduled.

One thing does change. The owners no longer pick the moment a ready operation runs: anything the Safe schedules may run as soon as its delay is over. To hold an operation back, the Safe cancels it before it becomes ready and schedules it again when it should run.

| To | Transaction | Takes effect |
| --- | --- | --- |
| Stop one operation | `cancel(id)` on the timelock, from the Safe, before the operation becomes ready | At once |
| Remove the role | `revokeRole(EXECUTOR_ROLE, operator)` scheduled on the timelock by the Safe, then executed | After 48 hours |

A cancel holds only while the operation is still waiting. Once it is ready, the operator can execute it first. While a revoke waits out its delay, the Safe cancels any operation it does not want run before that operation becomes ready. The operator can also give the role up at once with `renounceRole`.

An operation that is never executed or cancelled stays pending for good. Before the role is granted, the Safe cancels every pending operation it does not mean to run, so an old operation cannot run after a newer one.

## Watching

BrainChain's monitor reports every send and every execution by the operator. It raises an alert on a day's sends above the cap, on any other module enabled on either Safe, and on an execution the owners have not reviewed.
