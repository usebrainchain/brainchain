# Judged capture on Base

When an agent pays for a task on Base, the payment can wait in escrow until BrainChain decides on the work. It is paid out when the work is accepted and returned when it is not. If nothing is decided by the deadline, the agent takes it back itself.

The escrow is the commerce-payments `AuthCaptureEscrow` that the x402 `auth-capture` scheme uses. [`JudgedCapture`](../src/escrow/JudgedCapture.sol) is the operator of each payment: the one address the escrow lets capture or void it. It acts only on the final decision about a payment, signed by BrainChain's brain key.

## How a payment ends

The payer signs once, an ERC-3009 authorization for the full amount. Anyone may submit it to `JudgedCapture.authorize`, which checks the payment and moves the amount into the escrow. From then on it ends in one of three ways.

| Outcome | When | Where the money goes |
| --- | --- | --- |
| Capture | The final decision accepts the work at or above the payer's bar, the dispute and appeal windows have closed, and the capture deadline has not passed | The payee, less the fee at the payer's `minFeeBps`, which goes to the payment's `feeReceiver` |
| Void | The final decision refuses the work, or accepts it below the bar | All of it back to the payer, at once |
| Reclaim | The capture deadline passes with the payment still held | All of it back to the payer, when the payer calls `reclaim` on the escrow |

The brain signs one final decision per payment, after the last appeal window on BrainChain has closed. Decisions marked as not final cannot capture or void, so a grade that a dispute or an appeal later overturns never moves money. Capture and void take the decision and its signature, so anyone may submit them.

## What the payer signs

The payer's authorization fixes every field of the escrow's `PaymentInfo`: the payee, the token, the amount, the deadlines and the fee terms. Its `salt` is BrainChain's terms for the payment, packed into 32 bytes:

| Term | Bytes | Meaning |
| --- | --- | --- |
| `task` | High 24 | The task the payment is for, as the seller named it. Not zero |
| `barBps` | Next 2 | The lowest confidence, in basis points, at which an acceptance pays. At most 10,000 |
| `windowsClose` | Low 6 | When the dispute and appeal windows close, in Unix seconds. Nothing captures before it |

`JudgedCapture.saltOf` packs the terms and `termsOf` reads them back. A client checks the salt against the terms in the payment requirements before it signs. Once the payment is held, nobody can change its terms, its bar included.

`authorize` refuses a payment whose terms could never lead to a capture: a zero task, a bar above 10,000, or a capture deadline less than `CAPTURE_MARGIN` (one day) after `windowsClose`. The day gives the brain time to sign the final decision and land the capture through a restart or a busy block, so accepted work does not lapse to a reclaim. It also means a payer can reclaim no sooner than a day after the windows close.

The fee terms are `minFeeBps`, `maxFeeBps` and `feeReceiver` (`extra.feeRecipient` in the payment requirements). Under a `"custom"` operator they are the terms the seller agreed with the operator. JudgedCapture always takes the floor, `minFeeBps`, and needs a `feeReceiver` whenever the floor is above zero.

## What a seller does

The payment requirements name `JudgedCapture` as `extra.captureAuthorizer`, with `operatorType` `"custom"`, `paymentFlow` `"escrow"` and `captureMode` `"deferred"`. They leave `receiverAuthorizer` and `policy` unset, so the salt is the terms and nothing else. The asset is USDC, and the amount is at most the cap.

Before settling a payer's authorization, the seller calls `check(paymentInfo, amount)` with the payment the payer signed and the amount it will submit. It reverts unless `authorize` would accept the payment, and returns the terms. It checks that:

- the operator is this contract and the token is USDC;
- the amount is the full `maxAmount` and no more than the cap;
- a fee floor has a `feeReceiver`;
- a brain key is in place to decide the payment;
- the terms have a task, a bar of at most 10,000 and the one-day margin before the capture deadline.

`check` only says the payment can be held. It does not say the terms are the seller's. The seller compares the returned task, bar and `windowsClose` with its own and settles only when all three match. A payer can sign a bar of 10,000 or another seller's task, and `check` still passes: a final acceptance below that bar then voids, and the payer gets its money back for work that was accepted.

The escrow's own checks still apply when the authorization settles, so the seller also simulates the `authorize` call, as the scheme asks of every collect.

The scheme has a `"custom"` operator expose `charge` beside `authorize`. JudgedCapture exposes it and always reverts with `NoCharge`: a judged payment is held until it is decided, never charged up front. A facilitator relays only `authorize` for an `"escrow"` payment.

## The decision

The brain key signs an EIP-712 message under the domain `{ name: "JudgedCapture", version: "1", chainId, verifyingContract }`, where `verifyingContract` is the `JudgedCapture` contract:

```
Decision(bytes24 task,bytes32 paymentInfoHash,bool accepted,bool isFinal,uint16 confidenceBps,uint256 decisionId,address decisionLog)
```

| Field | Meaning |
| --- | --- |
| `task` | Must equal the task in the payment's terms |
| `paymentInfoHash` | The escrow's `getHash` of the one payment it applies to |
| `accepted` | Whether BrainChain accepted the work |
| `isFinal` | True only on the one decision that settles the payment |
| `confidenceBps` | The decision's confidence, from 0 to 10,000 |
| `decisionId` | The decision's id in BrainChain's `DecisionLog` |
| `decisionLog` | The `DecisionLog` address on BrainChain |

A decision about one task cannot capture another task's payment, and a decision about one payment cannot move another payment of the same task. The `Captured` and `Voided` events repeat the decision id and log, so each capture or void on Base points to its record on BrainChain.

## What JudgedCapture cannot do

- Pay anyone other than the payee and the `feeReceiver` the payer signed.
- Take more than the payer signed, or a fee above the payer's floor.
- Hold less than the full amount. A partial hold would spend the payer's authorization on less than it agreed to.
- Hold a payment that could never be captured.
- Capture before the windows close, or after the capture deadline.
- Stop or delay a reclaim after the capture deadline. The escrow lets only the payer reclaim, and needs nothing from the operator.
- Accept a payment above the cap.
- Refund a captured payment. It has no refund call, so a capture is final.
- Charge a payer without a hold.

The contract holds no funds of its own. The escrow keeps each held payment in the token store it runs for this operator.

## The trust it places in the brain key

The contract checks the brain key's signature. It does not check that a decision matches the record on BrainChain. A brain key that signs a false acceptance can capture a payment for work that was not accepted, inside the payer's own terms: to the payee the payer named, after the windows, before the deadline. A brain key that signs a false refusal can send back a payment the payee earned. A brain that signs two final decisions about one payment lets whichever is submitted first settle it. Each decision names its record, so anyone can compare the two.

## What the owner can do

The owner is a Safe on Base. Each payment is decided by the brain key in force when it was authorized, which `brainOf(paymentInfoHash)` returns. The owner's powers:

- `queueBrain` announces a new key. It takes effect two days later, when anyone calls `execute`, and decides only payments authorized after that. The owner can `cancel` it before then. A key the owner names cannot capture a payment that was already held.
- `revokeBrain(key)` stops a key at once and for good. The payments bound to it can no longer be captured or voided, and their payers reclaim at the capture deadline. Revoking the current key also stops new payments until a new key is named through the delay.
- A routine rotation keeps the old key online until every payment bound to it has passed its capture deadline, since only that key can decide them. Revoking a key that is still queued does not cancel the queue: `cancel` it as well, or `execute` installs it and new payments stop for another two days.
- `queueCap` changes the cap with the same two days' notice. A new cap applies to payments authorized after it.

The owner cannot move a held payment, change its terms, or stop a reclaim. Ownership moves in two steps: `transferOwnership`, then `acceptOwnership` by the new owner.

Automata's DCAP attestation verifier is deployed on Base. A later version can let an enclave name the brain key with a verified TDX quote, as `DecisionLog.attestBrain` does on BrainChain. This version names the key only through the owner.

## Deployment

The cap is a constructor argument. [`script/DeployJudgedCapture.s.sol`](../script/DeployJudgedCapture.s.sol) deploys with 25 USDC (`25e6` in USDC's units), and the owner can change it later through `queueCap`. A plain run only simulates the deployment:

```
OWNER=<Base Safe> BRAIN=<brain key> forge script script/DeployJudgedCapture.s.sol --rpc-url https://mainnet.base.org
```

The script refuses `--broadcast` unless `DEPLOY_JUDGED_CAPTURE=true` is also set.

## Addresses on Base

| Contract | Address |
| --- | --- |
| `AuthCaptureEscrow` (commerce-payments v1.1.0) | `0xf96815976523E00e65Be8f34cA5e64b4f41EB19c` |
| `ERC3009PaymentCollector` | `0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `JudgedCapture` | Not deployed yet |

The tests run against the escrow and collector code read from Base ([`test/fixtures/commerce-payments-v1.1.0.json`](../test/fixtures/commerce-payments-v1.1.0.json)), and the fork test checks that this code matches the chain. `JudgedCapture` has not had an external audit; the cap stays until it has.
