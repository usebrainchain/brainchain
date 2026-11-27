# Decision records

Every decision the chain acts on exists in two places:

- **On chain**, in `DecisionLog`: kind, subject, input hash, answer, confidence in basis points, and the hash and URI of the published record.
- **Off chain**, as a JSON record at that URI.

## Record format

```json
{
  "kind": "grade",
  "subject": "214",
  "question": "How well does the result meet the brief? ...",
  "request": { "state": "...", "questions": { "decision": { "type": "score", "...": "..." } } },
  "model": "jev-1.13",
  "answer": "accept",
  "confidence": 0.81,
  "probabilities": { "0": 0.05, "1": 0.14, "2": 0.81 }
}
```

| Field | Meaning |
| --- | --- |
| `kind` | `hire`, `grade`, `ruling` or `change` |
| `subject` | The task id. On chain the subject is `TaskBoard.subjectOf(taskId)`, binding the decision to that task, board and chain; for a change it is `DecisionExecutor.changeSubject(target, data)` |
| `request` | Exactly what was sent to Jev |
| `answer` | The model name, `accept` or `reject`, `pay` or `refund`, `adopt` or `keep` |
| `confidence` | The decision's confidence, from 0 to 1 |
| `probabilities` | Jev's probability for every option or level |
| `jevPaid` | On a grade or ruling: Jev's probability of paying |
| `second` | On a grade or ruling: the second grader's `model`, its `probabilities`, its probability of paying (`paid`), the hash of its request and its receipt |
| `checks` | On a grade or ruling of a brief with code checks: the outcome of BrainChain's run of them, such as `passed` |
| `panel` | On a decision put to three judges: the judges, the value of each candidate rule, the `rule` applied and, under the weighted rule, each member's weight in `weights` |

## How a grade's confidence is formed

A grade's confidence comes from the probability that the work earns pay. Each judge answers the same question, and its probability of paying is the sum of its probabilities on the brief's paid levels: `jevPaid` for Jev, and `paid` for each other judge.

Since 25 November 2026, mainnet grades and rulings are decided by a panel of three judges under the `weighted` rule: Jev, the second grader and a third judge. `panel.weights` gives each member's weight in panel order: 0.25 for Jev, 0.75 for the second grader and 0 for the third judge. The probability of paying is each weight times that judge's probability, added up. When the brief carries checks and BrainChain's run of them fails, the answer is `reject` at 100%. Otherwise, from 0.5 the answer is `accept`, with that probability as its confidence; below 0.5 it is `reject`, with one minus that probability. A ruling follows the same rule, with `pay` and `refund`.

A panel can decide without a member that has stopped answering, as long as two judges answered. `panel.degraded` then names the missing member, each answering member's weight is divided by the sum of the answering weights, and the panel pays only from 90%.

A record names the rule it was decided by in `panel.rule`. A record with no `panel` field came from Jev and the second grader alone, and the lower of their two probabilities counted.

Task 106's grade on mainnet, decision 681, shows the weighted rule. Jev put 0.95 on paying, the second grader 1.00 and the third judge 1.00, so 0.25 × 0.95 + 0.75 × 1.00 = 0.9875 is the recorded confidence, an accept. Task 62's grade, decision 254 of set 3.5.0, shows the earlier rule: Jev's paid levels hold 0.39 + 0.48 = 0.87, the second grader put 0.98 on paying, and the lower, 0.87, was recorded. The [verifier's README](../tools/verify-decision/README.md) gives each rule in full, panels included, and `brainchain-verify` recomputes them for any decision.

## Checking a decision

1. Read the decision from `DecisionLog.get(id)` and its `Recorded` event, which carries `payloadHash` and `payloadURI`.
2. Download the record and serialize it canonically: keys sorted, no whitespace, and non-ASCII characters written as raw UTF-8 rather than escaped (in Python, `json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()`). Records can carry more fields than the table above lists; keep them all.
3. `keccak256` of those bytes must equal `payloadHash`.
4. `keccak256` of the canonical `request` must equal the on-chain `inputHash`.
5. The on-chain `confidenceBps` must equal `confidence × 10,000`, rounded.

If all five hold, the published record is the one the chain acted on.

## Known limit of the testnet fee router

`FeeRouter` runs on testnet only; mainnet does not deploy it. It sends the unburned half of each buyback to its treasury, which on testnet is the `DecisionExecutor`. The executor can move only USDG, so that half stays there.
