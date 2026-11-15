# Judged capture on Base

When an agent pays for a task on Base, the payment can wait in escrow until BrainChain decides on the work. It is paid out when the work is accepted and returned when it is not. If nothing is decided by the deadline, the agent takes it back itself.

The escrow is the commerce-payments `AuthCaptureEscrow` that the x402 `auth-capture` scheme uses. [`JudgedCapture`](../src/escrow/JudgedCapture.sol) is the operator of each payment: the one address the escrow lets capture or void it. It acts only on a decision signed by BrainChain's brain key.

## How a payment ends

The payer signs once, an ERC-3009 authorization for the full amount. Anyone may submit it to `JudgedCapture.authorize`, which moves the amount into the escrow. From then on it ends in one of three ways.

| Outcome | When | Where the money goes |
| --- | --- | --- |
| Capture | A decision accepts the work at or above the payer's bar, the dispute and appeal windows have closed, and the capture deadline has not passed | The payee, less the fee at the payer's `minFeeBps`, which goes to the payer's `feeRecipient` |
| Void | A decision refuses the work, or accepts it below the bar | All of it back to the payer, at once |
| Reclaim | The capture deadline passes with the payment still held | All of it back to the payer, when the payer calls `reclaim` on the escrow |

Capture and void take the decision and the brain key's signature, so anyone may submit them. A void is final: once the money is back with the payer, no later decision moves it.

## What the payer signs

The payer's authorization fixes every field of the escrow's `PaymentInfo`: the payee, the token, the amount, the deadlines and the fee bounds. Its `salt` carries BrainChain's terms for the payment:

| Term | Meaning |
| --- | --- |
| `task` | The task the payment is for, as the seller named it |
| `barBps` | The lowest confidence, in basis points, at which an acceptance pays |
| `windowsClose` | When the dispute and appeal windows close. Nothing captures before it |

The salt is `keccak256(abi.encode(TERMS_TYPEHASH, task, barBps, windowsClose))`, where `TERMS_TYPEHASH` is `keccak256("JudgedCaptureTerms(bytes32 task,uint16 barBps,uint48 windowsClose)")`. `JudgedCapture.saltOf` computes it. A client checks the salt against the terms before it signs. Once the payment is held, nobody can change its terms, its bar included.

The seller's payment requirements name `JudgedCapture` as `extra.captureAuthorizer`, with `operatorType` `"custom"`, `paymentFlow` `"escrow"` and `captureMode` `"deferred"`. They leave `receiverAuthorizer` and `policy` unset, so the salt is the terms and nothing else. The capture deadline should leave time after `windowsClose` for the capture itself.

## The decision

The brain key signs an EIP-712 message under the domain `{ name: "JudgedCapture", version: "1", chainId, verifyingContract }`, where `verifyingContract` is the `JudgedCapture` contract:

```
Decision(bytes32 task,bytes32 paymentInfoHash,bool accepted,uint16 confidenceBps,uint256 decisionId,address decisionLog)
```

| Field | Meaning |
| --- | --- |
| `task` | Must equal the task in the payment's terms |
| `paymentInfoHash` | The escrow's `getHash` of the one payment it applies to |
| `accepted` | Whether Jev accepted the work |
| `confidenceBps` | Jev's confidence, from 0 to 10,000 |
| `decisionId` | The decision's id in BrainChain's `DecisionLog` |
| `decisionLog` | The `DecisionLog` address on BrainChain |

A decision about one task cannot capture another task's payment, and a decision about one payment cannot move another payment of the same task. The `Captured` and `Voided` events repeat the decision id and log, so each capture or void on Base points to its record on BrainChain.

## What JudgedCapture cannot do

- Pay anyone other than the payee and the fee recipient the payer signed.
- Take more than the payer signed, or a fee above the payer's floor.
- Hold less than the full amount. A partial hold would spend the payer's authorization on less than it agreed to.
- Capture before the windows close, or after the capture deadline.
- Stop or delay a reclaim after the capture deadline. The escrow lets only the payer reclaim, and needs nothing from the operator.
- Accept a payment above the cap: 25 USDC per payment, in USDC's units.
- Refund a captured payment. It has no refund call, so a capture is final.
- Charge a payer without a hold. It has no `charge` call, since a charge would pay out before any decision.

The contract holds no funds of its own. The escrow keeps each held payment in the token store it runs for this operator.

## The trust it places in the brain key

The contract checks the brain key's signature. It does not check that a decision matches the record on BrainChain. A brain key that signs a false acceptance can capture a payment for work that was not accepted, inside the payer's own terms: to the payee the payer named, after the windows, before the deadline. A brain key that signs a false refusal can send a payment back that the payee earned. Each decision names its record, so anyone can compare the two.

The owner, a Safe on Base, names the brain key:

- `queueBrain` announces a new key. It takes effect two days later, when anyone calls `execute`. The owner can `cancel` it before then.
- `revokeBrain` removes the key at once. Nothing captures or voids until a new key is named through the delay, and payers can still reclaim.
- The cap changes the same way, through `queueCap` and the same two days.

Signatures by a replaced or revoked key stop working. Ownership moves in two steps: `transferOwnership`, then `acceptOwnership` by the new owner.

Automata's DCAP attestation verifier is deployed on Base. A later version can let an enclave name the brain key with a verified TDX quote, as `DecisionLog.attestBrain` does on BrainChain. This version names the key only through the owner.

## Addresses on Base

| Contract | Address |
| --- | --- |
| `AuthCaptureEscrow` (commerce-payments v1.1.0) | `0xf96815976523E00e65Be8f34cA5e64b4f41EB19c` |
| `ERC3009PaymentCollector` | `0x8612dfdc421f80336cd14E8EF9cb1E765dB5ab88` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `JudgedCapture` | Not deployed yet |

The tests run against the escrow and collector code read from Base ([`test/fixtures/commerce-payments-v1.1.0.json`](../test/fixtures/commerce-payments-v1.1.0.json)), and the fork test checks that this code matches the chain. `JudgedCapture` has not had an external audit; the cap stays until it has.
