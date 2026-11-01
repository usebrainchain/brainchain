# brainchain-verify

Check any BrainChain decision against the chain. The tool reads the decision from the `DecisionLog`, fetches the record Jev's answer was published in, recomputes its hashes and confidence, and applies the task's thresholds the way the contracts do. It needs a public RPC and nothing else: no keys, no account.

```sh
npx brainchain-verify mainnet 1
npx brainchain-verify mainnet --task 11 --set v3-1
npx brainchain-verify testnet 100 --json
```

Requires Node.js 22 or later.

## Usage

```text
brainchain-verify <mainnet|testnet|chainId> <decisionId> [--set <TaskBoard>] [--rpc <url>] [--json]
brainchain-verify <mainnet|testnet|chainId> --task <taskId> [--set <TaskBoard>] [--rpc <url>] [--json]
```

| Argument | Meaning |
| --- | --- |
| `mainnet`, `testnet` or a chain id | `mainnet` is chain 274663 at `https://rpc.usebrainchain.com`; `testnet` is chain 274630 at `https://rpc.testnet.usebrainchain.com`. |
| `<decisionId>` | The decision's number in its `DecisionLog`, from 1. |
| `--task <id>` | Check every decision about one task, oldest first. |
| `--set <TaskBoard>` | A retired contract set, by its TaskBoard address or by the key a decision page uses (`?set=v3-1`). Without it, the active set. Each set numbers its tasks and decisions from 1. |
| `--rpc <url>` | Another RPC for the same chain. |
| `--json` | One JSON object on stdout. |

The package carries the active and retired contract sets from [`deployments/`](../../deployments) as they stood when it was built. An unknown `--set` lists them.

## Output

```text
$ npx brainchain-verify mainnet 22 --set v3-1
Decision 22 on BrainChain mainnet, contract set v3-1 (DecisionLog 0xbe8E68EbDEaf2C65bc13D8AD070d17098Be6d335)

  ok    read from DecisionLog 0xbe8E…d335: grade, recorded 2026-11-01 00:40:23 UTC in block 419, confidence 8000 bps
  ok    fetched the record from https://brain.usebrainchain.com/records/0xc6570be10e86227b06d9ce78b739c83dac8d62e9f9cf33b67f25b7d148e8182a.json
  ok    record hash matches payloadHash 0xc657…182a
  ok    request hash matches inputHash 0x7f5f…55ca
  ok    kind: grade
  ok    subject: task 11 on board 0x6fBF…f6e0, chain 274663
  ok    probabilities cover exactly the options Jev was asked
  ok    answer: accept, recorded as 0x0000…0001
  ok    confidence: 0.8 is 8000 bps, as recorded
  ok    the question quotes task 11's brief, as committed on chain
  ok    the levels Jev scored against are the brief's, lowest first
  ok    confidence recomputed: paid levels 1, 2 hold 0.46 + 0.34 = 0.8000, so accept at 0.8000
  ok    threshold: accept at 80% is at or above the 70% grade threshold fixed when task 11 was posted, so the work is accepted, as the board recorded

Verdict: match. The published record is exactly what the chain recorded, and the chain applied it as its contracts require.
Not checked: that Jev produced the answer. The chain trusts the brain key for that: https://docs.usebrainchain.com/trust-model
```

Each line is one check. `ok` passed and `FAIL` means the record and the chain disagree. `skip` is a check that could not run, with the reason on the line. `ERROR` means the record host did not answer after three tries, so the checks that need the record did not run.

## What it checks

| Check | What passes |
| --- | --- |
| `read` | `DecisionLog.get(id)` and the decision's `Recorded` event agree. |
| `fetch` | The record at the event's `payloadURI` (https, http or a base64 `data:` URI, with redirects refused) is a decision record. |
| `record-hash` | `keccak256` of the fetched bytes equals `payloadHash`. |
| `input-hash` | `keccak256` of the record's `request`, serialized canonically (keys sorted, no whitespace), equals `inputHash`. |
| `kind` | The record's kind is the one on chain. |
| `subject` | A task decision names `TaskBoard.subjectOf(task)` for this chain and board. A change names its exact call. |
| `options` | The probabilities cover exactly the options in the question. |
| `answer` | The record's answer encodes to the one on chain: the hired model's id or worker address, or 1 for accept, pay, adopt and allow and 0 for their opposites. |
| `confidence` | The record's confidence times 10,000, rounded, equals `confidenceBps`. |
| `top-option` | For a hire, ruling or change, the answer is Jev's most likely option. |
| `confidence-recomputed` | The confidence follows from the probabilities. A hire uses `(p - 1/n) / (1 - 1/n)`, within 0.02 because the probabilities are rounded to two decimals. A grade sums the probabilities on the paid levels. A ruling or change uses the chosen option's probability. |
| `brief` | The question quotes the task's brief, fetched from its `Posted` event and checked against `briefHash`. |
| `levels` | A grade or ruling used the brief's own quality levels and pass level. |
| `threshold` | The threshold fixed when the task was posted, applied as `TaskBoard.hire`, `grade` and `rule` do, gives the outcome the board emitted. A change is queued only on a yes. |
| `change-subject`, `change-call` | A queued change is the call the decision names and the call Jev was shown. |

Some checks skip by design:

- A record for work Jev did not accept is served without the work, so `record-hash` and `input-hash` cannot match it. The answer, confidence and threshold are still checked.
- A decision the board never applied, because a later decision or a closed window settled the task, skips `threshold`.
- A grade recorded before the chain gated on the paid levels skips `confidence-recomputed`: its confidence is Jev's score confidence, which the probabilities alone do not give.

## What it cannot check

That Jev produced the answer. The chain trusts the brain key to record Jev's answers faithfully, and the contracts bound what a recorded answer can do. A decision that passes every check has the question, answer and probabilities the chain acted on; whether Jev gave that answer rests on the brain key. The [trust model](https://docs.usebrainchain.com/trust-model) says what bounds that key.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | Every check that could run passed. Skips do not fail a decision. |
| 1 | A check failed, a record could not be fetched, or the decision could not be read: an unknown id, a task with no decisions, an RPC error. |
| 2 | Bad arguments, or an RPC that serves another chain. |

## JSON

`--json` prints one object. `decisions` holds one entry, or one per decision with `--task`. `verdict` is `match`, `mismatch` or `unverified` (a record could not be fetched). Each check keeps its `name` across releases, and its `status` is `ok`, `fail`, `skip` or `error`. When the tool cannot run, it prints `{ "error": "..." }` and exits 1. Trimmed to one check:

```json
{
  "network": "BrainChain mainnet",
  "chainId": 274663,
  "set": {
    "key": "v3-1",
    "release": "3.1.0",
    "fromBlock": 282,
    "board": "0x6fBF25F036F18C7AE3b1B7343ED8d16Dc695f6e0",
    "log": "0xbe8E68EbDEaf2C65bc13D8AD070d17098Be6d335",
    "executor": "0xC5442fEFDa6B55f48a1FCfc195a8737D7EfB829B"
  },
  "verdict": "match",
  "failed": 0,
  "errors": 0,
  "skipped": 0,
  "decisions": [
    {
      "id": 22,
      "kind": "grade",
      "task": 11,
      "block": 419,
      "recordedAt": "2026-11-01 00:40:23 UTC",
      "confidenceBps": 8000,
      "payloadURI": "https://brain.usebrainchain.com/records/0xc6570be10e86227b06d9ce78b739c83dac8d62e9f9cf33b67f25b7d148e8182a.json",
      "verdict": "match",
      "checks": [
        { "name": "record-hash", "status": "ok", "message": "record hash matches payloadHash 0xc657…182a" }
      ]
    }
  ],
  "notChecked": "That Jev produced the answer. The chain trusts the brain key to record Jev's answers faithfully.",
  "trustModel": "https://docs.usebrainchain.com/trust-model"
}
```

## Building

```sh
npm install
npm run build
```

`build` reads `deployments/*.json` at the repository root into `src/deployments.ts` and compiles to `dist/`. `npm run abi` regenerates `src/abi.ts` from a `forge build` at the root.

## License

MIT
