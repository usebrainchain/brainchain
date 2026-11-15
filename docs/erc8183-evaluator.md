# ERC-8183 evaluator

An ERC-8183 job can name BrainChain as its evaluator. BrainChain's decision then completes or rejects the job, and the side that decision goes against has a window to appeal it once, with a bond.

Two contracts do this:

- [`Erc8183Evaluator`](../src/evaluators/Erc8183Evaluator.sol) is the job's evaluator. It completes or rejects a job only on a decision signed by BrainChain's brain key, about that job and the deliverable its provider submitted.
- [`Erc8183AppealHook`](../src/evaluators/Erc8183AppealHook.sol) is the job's hook. It holds the evaluator's decision for an appeal window, takes the appeal and its bond, and pays the bond out when the job settles.

Neither contract is deployed yet. They follow ERC-8183 (status Draft) as written in the reference repository, [erc-8183/base-contracts](https://github.com/erc-8183/base-contracts) at commit `142e669`, and its job contract `ERC8183`.

## ERC-8183 in brief

A job has a client who funds it, a provider who delivers, and one evaluator. The client escrows the budget. The provider submits a `bytes32` deliverable. Only the evaluator can then complete the job, which pays the provider, or reject it, which refunds the client. If nobody acts, anyone can expire the job after `expiredAt` and the client is refunded. The standard has no dispute path: a rejection or an expiry is final.

A job may also name a hook. The job contract calls the hook before and after each step, and a hook may revert to block a step. `claimRefund`, the expiry refund, is never hooked.

## Using it

The client creates the job with this evaluator and this hook:

```solidity
jobs.createJob(provider, evaluator, expiredAt, description, appealHook, providerAgentId);
```

Three conditions apply.

- The job contract's admin must have whitelisted the hook. The reference contract refuses any other hook.
- The hook must hold a bond for the job's token. Funding is refused for a token without one.
- `expiredAt` must leave room for the appeal window and the ruling period after the decision. Funding is refused if it cannot leave that room even for a decision made at once.

The job then runs as usual. The provider sets a budget, the client funds it, and the provider submits. The hook records the deliverable when it is submitted, because the reference job contract does not store it.

## Lifecycle

1. **First decision.** The brain judges the deliverable and signs a decision. Anyone submits it with `Erc8183Evaluator.decide`. The job stays Submitted and the hook opens the appeal window.
2. **No appeal.** Once the window closes, anyone calls `Erc8183Evaluator.finalize`. The first decision completes or rejects the job.
3. **Appeal.** Inside the window, the side the first decision went against calls `Erc8183AppealHook.appeal` and posts the bond. That is the client when the job would complete, and the provider when it would be rejected. Each job takes one appeal.
4. **Ruling.** The brain judges again and signs a second decision, marked as a ruling on the appeal. Submitting it settles the job at once. If no ruling arrives within the ruling period, anyone calls `finalize`, the first decision settles the job, and the bond returns.

A decision for a job that has not been submitted is refused. The evaluator never rejects a funded job before delivery, although the standard allows evaluators to.

## The decision the brain signs

The brain signs an EIP-712 message. The domain names this contract and the chain:

| Domain field | Value |
| --- | --- |
| `name` | `BrainChain ERC-8183 Evaluator` |
| `version` | `1` |
| `chainId` | The chain the evaluator is on |
| `verifyingContract` | The evaluator's address |

```
Decision(address jobContract,uint256 jobId,bytes32 deliverable,bool appeal,bool accept,uint16 confidenceBps,uint256 logChainId,address decisionLog,uint256 decisionId)
```

| Field | Meaning |
| --- | --- |
| `jobContract`, `jobId` | The job judged |
| `deliverable` | The deliverable judged, as the provider submitted it |
| `appeal` | False for the first decision, true for a ruling on an appeal |
| `accept` | True to complete the job, false to reject it |
| `confidenceBps` | Jev's confidence, from 0 to 10,000 |
| `logChainId`, `decisionLog`, `decisionId` | The BrainChain decision behind it: the chain, the `DecisionLog` address and the record id |

`hashDecision(decision)` returns the digest to sign. A decision is refused if:

- it was not signed by the current brain key;
- it names a job whose evaluator is another address, or a job that is not Submitted;
- the job's hook is not an appeal hook bound to this evaluator and job contract;
- its deliverable differs from the one the provider submitted;
- its BrainChain decision has already been applied, to this job or any other;
- it is a first decision for a job already decided, or a ruling for a job never decided or never appealed.

When the evaluator completes or rejects a job, it passes the digest of the deciding message as the standard's `reason`. Its `Settled` event carries the BrainChain decision id, so the transaction links to the decision record.

## The confidence rule

`minConfidenceBps` is fixed when the evaluator is deployed. A decision below it takes the safe default, as on BrainChain's own task board:

| Decision | At or above the bar | Below the bar |
| --- | --- | --- |
| First decision | `accept` decides | The job is rejected and the client refunded |
| Ruling on an appeal | `accept` decides | The first decision stands |

## The bond

The hook's owner sets one bond amount per token with `setBond`. A job's bond, window and ruling period are fixed when it is funded, so later changes apply only to new jobs.

| Ruling | Job | Bond |
| --- | --- | --- |
| Confident, same as the first decision | Settles as first decided | To the side that won |
| Confident, the other way | Settles the other way | Back to the appellant |
| Below the confidence bar | Settles as first decided | Back to the appellant |
| None within the ruling period | Settles as first decided | Back to the appellant |

A confirmed appeal pays the bond to the side that won. The brain issued the first decision, so a bond paid to BrainChain on confirmation would reward the judge for upholding itself. Paid to the winner, it compensates the side whose payment or refund the appeal delayed, and the judge gains nothing from either answer. BrainChain's task board keeps a confirmed bond for its fee recipient; this evaluator judges outside jobs, where that incentive matters more.

If the job ends without passing through the hook, `releaseBond` returns a held bond to the appellant. That happens when the job expires through `claimRefund`, or when the job contract's admin detaches the hook.

## What the hook can hold

ERC-8183 lets a hook revert `complete` and `reject`. The appeal hook uses that to keep the evaluator's settlement waiting until the window closes, or until the appeal is ruled on or its ruling period runs out. The evaluator's own calls are the only ones it gates, since only the evaluator can complete or reject a funded job.

The standard does not let a hook hold `claimRefund`. In the reference contract, anyone can expire a Submitted job one hour after `expiredAt` (the evaluation grace period) and refund the client, whatever the evaluator decided. So the hook takes a first decision only if the appeal window and the ruling period both end by `expiredAt`. Every step then finishes before the refund opens, with the grace hour left for the final `finalize`. A decision that comes too late is refused, and the job runs to expiry and refunds the client. The client should set `expiredAt` at least one window and one ruling period after it expects the decision.

The job contract's admin can detach a hook from a job (`batchDetachHook`). The hold ends with it. `finalize` then settles the first decision at once, and a held bond is returned through `releaseBond`.

## The brain key

The evaluator's owner, a Safe, names the brain key. The first key is a constructor argument. A change takes two steps:

1. The owner calls `proposeBrain(key)`.
2. Once `brainDelay` has passed, anyone calls `acceptBrain()`.

The owner can cancel a proposal before it takes effect. `brainDelay` is fixed at deployment and is at least one day. Decisions signed by the old key stop counting once the new key takes effect.

The evaluator is deployed on a chain other than BrainChain, so it cannot read the brain key from `DecisionLog`. It keeps its own copy. `setKeyCheck` names a contract a proposed key must also pass before it takes effect, such as one that verifies the brain enclave's TDX quote on that chain. None is set at first.

## Fees

The evaluator holds no job money. If the job contract's admin sets an evaluator fee, the reference contract pays it to the evaluator on completion only, never on rejection. BrainChain does not set that fee. The owner moves what builds up with `sweep`.

## Limits

- A job must name the appeal hook itself. A router that fans out to several hooks is not supported.
- The hook serves one job contract and one evaluator.
- Timing depends on the reference contract's one-hour evaluation grace period. A job contract without one leaves no time to call `finalize` after the last step.
- The hook pays bonds directly. A recipient the token refuses would block the job's settlement until it expires.

## Tests

The tests run every path against a reduced copy of the reference job contract, [`test/erc8183/ERC8183.sol`](../test/erc8183/ERC8183.sol). ERC-8183 is not published as a package. The copy keeps the reference job lifecycle, fees, hook calls, hook data and grace period, and leaves out milestone claims, payout receivers, pausing, upgrades and signed authorizations. An invariant suite checks that the job contract holds exactly the open budgets, that the hook holds exactly the pending bonds, and that every client, provider, treasury and evaluator balance matches what the signed decisions and the standard's expiry rule give it.
