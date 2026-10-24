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
| `subject` | The task id, or for a change the hash of the target and calldata |
| `request` | Exactly what was sent to Jev |
| `answer` | The model name, `accept` or `reject`, `pay` or `refund`, `adopt` or `keep` |
| `confidence` | Jev's confidence, from 0 to 1 |
| `probabilities` | Jev's probability for every option or level |

## Checking a decision

1. Read the decision from `DecisionLog.get(id)` and its `Recorded` event, which carries `payloadHash` and `payloadURI`.
2. Download the record and serialize it canonically: keys sorted, no whitespace.
3. `keccak256` of those bytes must equal `payloadHash`.
4. `keccak256` of the canonical `request` must equal the on-chain `inputHash`.
5. The on-chain `confidenceBps` must equal `confidence × 10,000`, rounded.

If all five hold, the published record is the one the chain acted on.
