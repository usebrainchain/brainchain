# Operator roles

BrainChain's operator key, `0x70C665780E43BA1496a4E691e408F24844dB58eC`, runs routine jobs around the clock. Two of those jobs used to wait for both Safe owners to sign: topping up the desk's USDG, and executing a timelock operation once its delay has passed. Each now has a narrow power of its own. The owners keep everything else, and can take either power back with a Safe transaction.

## Desk top-ups

[`CappedTransferModule`](../src/safe/CappedTransferModule.sol) is a Safe module. One copy serves each Safe that funds the desk: the treasury Safe on Robinhood Chain and the admin Safe on BrainChain. Each copy's address is added to `deployments/mainnet.json` when it is deployed.

The operator can call `send(amount)`, which moves USDG from the Safe to the module's recipient, the desk. All sends in one UTC day together stay within the daily cap.

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

The AdminTimelock on BrainChain, `0xB23F49390061B1E7Faf0F99B146E491Ee1574B1e`, holds the admin powers over the decision logs, the executors and the boards. It is OpenZeppelin's `TimelockController` with a 48-hour delay. The admin Safe is its only proposer and its only canceller. The timelock alone holds the admin role over its own roles.

With the executor role, the operator can execute an operation the Safe scheduled, once its delay has passed. An operation is identified by the hash of its targets, values, calldata, predecessor and salt, so the operator can run only exactly what the Safe scheduled. The timelock refuses an operation that was never scheduled, one still waiting out its delay, one already executed, and one whose predecessor has not run.

The operator cannot:

- schedule an operation, which needs the proposer role;
- cancel one, which needs the canceller role;
- grant or revoke a role, or change the delay, which only the timelock itself can do through an operation the Safe scheduled.

One thing does change. The owners no longer pick the moment a ready operation runs: anything the Safe schedules may run as soon as its delay is over. To hold an operation back, the Safe cancels it and schedules it again when it should run.

| To | Transaction | Takes effect |
| --- | --- | --- |
| Stop one operation | `cancel(id)` on the timelock, from the Safe | At once |
| Remove the role | `revokeRole(EXECUTOR_ROLE, operator)` scheduled on the timelock by the Safe, then executed | After 48 hours |

While a revoke waits out its delay, the Safe cancels any operation it does not want run. The operator can also give the role up at once with `renounceRole`.

## Watching

BrainChain's monitor reports every send and every execution by the operator. It raises an alert on a send above the cap, on any other module enabled on either Safe, and on an execution the owners have not reviewed.
