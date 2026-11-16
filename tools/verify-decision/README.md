# brainchain-verify

Check any BrainChain decision against the chain. The tool reads the decision from the `DecisionLog`, fetches its published record, recomputes its hashes and confidence, and applies the task's thresholds the way the contracts do. It needs a public RPC and nothing else: no keys, no account.

Each record holds the question BrainChain asked Jev, a decision model served by TypeSafe, and Jev's answer with its probabilities.

It also checks the reputation BrainChain writes for its workers. Each entry in the ERC-8004 registry on Robinhood Chain is followed through its signed receipt to the decision, the payment and the task on the board.

```sh
npx brainchain-verify mainnet 1
npx brainchain-verify mainnet --task 11 --set v3-1
npx brainchain-verify testnet 100 --json
npx brainchain-verify mainnet --receipt receipt.json
npx brainchain-verify mainnet --entry 20424:7
npx brainchain-verify mainnet --agent 20424
```

Requires Node.js 22 or later.

## Usage

```text
brainchain-verify <mainnet|testnet|chainId> <decisionId> [--set <TaskBoard>] [--rpc <url>] [--offline] [--json]
brainchain-verify <mainnet|testnet|chainId> --task <taskId> [--set <TaskBoard>] [--rpc <url>] [--offline] [--json]
brainchain-verify <mainnet|testnet|chainId> [<decisionId>] --receipt <file|url> [--set <TaskBoard>] [--rpc <url>] [--json]
brainchain-verify mainnet --entry <agentId>:[<writer>:]<feedbackIndex> [--rpc <url>] [--registry-rpc <url>] [--json]
brainchain-verify mainnet --agent <agentId> [--rpc <url>] [--registry-rpc <url>] [--json]
```

| Argument | Meaning |
| --- | --- |
| `mainnet`, `testnet` or a chain id | `mainnet` is chain 274663 at `https://rpc.usebrainchain.com`; `testnet` is chain 274630 at `https://rpc.testnet.usebrainchain.com`. |
| `<decisionId>` | The decision's number in its `DecisionLog`, from 1. |
| `--task <id>` | Check every decision about one task, oldest first. |
| `--set <TaskBoard>` | A retired contract set from 3.0.0 on, by its TaskBoard address, by the key a decision page uses (`?set=v3-1`, or an older one the site still opens, such as `v4` for `v3-4`) or by release (`3.1.0`). Without it, the active set. Each set numbers its tasks and decisions from 1. The `v2` set is not supported: its board named tasks by id alone, which the subject check does not read. |
| `--rpc <url>` | Another RPC for the same chain. Records and briefs on private addresses are read only when this RPC is on one too. |
| `--receipt <file\|url>` | Check the receipt for a paid job, from a JSON file or an http(s) URL, of at most 64 KB. Without a decision id, the tool checks the decision the receipt names, in the contract set its DecisionLog belongs to. See [receipts](#receipts). |
| `--entry <agentId>:[<writer>:]<index>` | Check one reputation entry BrainChain wrote. See [reputation entries](#reputation-entries). |
| `--agent <agentId>` | Check every reputation entry BrainChain wrote for one agent, oldest first. |
| `--registry-rpc <url>` | Another RPC for Robinhood Chain, where the ERC-8004 registries are. |
| `--offline` | Fetch no receipt from the brain host. A receipt given with `--receipt` is still checked. |
| `--json` | One JSON object on stdout. |
| `--version` | Print the version. |

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
  ok    threshold: accept at 80% is at or above task 11's 70% grade threshold, so the work is accepted, as the board recorded

Verdict: match. The published record is exactly what the chain recorded, and the chain applied it as its contracts require.
Not checked: that Jev produced the answer. See https://docs.usebrainchain.com/trust-model
```

Each line is one check. `ok` passed and `FAIL` means the record and the chain disagree. `skip` is a check with nothing to run on, such as a brief the host no longer has, with the reason on the line. `ERROR` is a check that could not run because something it reads could not be read: the host did not answer in up to three tries and 30 seconds in all, answered with an error, or sent more than the tool reads. A record the host no longer has, or one the tool refuses to read (see `fetch`), is an `ERROR` too, since no other check can run without it.

The verdict is `match`, `withheld`, `UNVERIFIED` or `MISMATCH`. `withheld` means a record served without the work passed the checks that could run, and says what they leave out.

## What it checks

| Check | What passes |
| --- | --- |
| `read` | `DecisionLog.get(id)` and the decision's `Recorded` event agree. |
| `fetch` | The record at the event's `payloadURI` (https, http or a base64 `data:` URI, with redirects refused) is a decision record of at most 4 MB. A body that is not JSON, such as a proxy's error page, is an `ERROR`; JSON that is not a decision record is a `FAIL`. Briefs are read the same way, up to 256 KB. Anything on a private or loopback address is refused, however its name resolves, unless `--rpc` is on one too. |
| `withheld` | On a record served without the work: the kind is a grade or ruling, the request carries the service's marker where the work was, and the chain shows the work is not public. If any of these fails, the record is held to its hashes like any other. |
| `record-hash` | `keccak256` of the fetched bytes equals `payloadHash`. |
| `input-hash` | `keccak256` of the record's `request`, serialized canonically (keys sorted, no whitespace), equals `inputHash`. |
| `kind` | The record's kind is the one on chain. |
| `subject` | A task decision names `TaskBoard.subjectOf(task)` for this chain and board. A change's subject is the one on chain; it is tied to the call Jev was shown only once the change is queued, by `change-subject` and `change-call`. A grade of outside work is matched by the rules below. |
| `options` | The probabilities cover exactly the options in the question. A panel that decided without Jev records none of Jev's, and `panel` checks that it names Jev as missing. |
| `answer` | The record's answer encodes to the one on chain: the hired model's id or worker address, or 1 for accept, pay, adopt and allow and 0 for their opposites. |
| `confidence` | The record's confidence times 10,000, rounded, equals `confidenceBps`. |
| `top-option` | For a hire, ruling or change, the answer is Jev's most likely option. |
| `confidence-recomputed` | The confidence follows from the probabilities. A hire uses `(p - 1/n) / (1 - 1/n)`, within 0.02 because the probabilities are rounded to two decimals. A grade sums the probabilities on the paid levels. A change uses the chosen option's probability, and so does a ruling recorded before rulings were graded twice. A grade or ruling with a `second` or `checks` field follows the two-grader rule: the probability of paying is the lower of Jev's and the second grader's, zero when the brief's checks failed, and the answer and confidence follow it. A record with a `panel` field follows the panel's rule instead, as [decided by a panel](#decided-by-a-panel) describes. |
| `second-grader` | On a decision graded twice: the second grader's probability of paying recomputes from its probabilities, and the receipt id it carries is shown. |
| `judge` | On a decision by a panel, one line for each judge after the second grader: its probability of paying recomputes from its probabilities, which cover the question's options, and the receipt id it carries is shown. |
| `panel` | On a decision by a panel: the candidate rules recompute from the judges' probabilities of paying, the record's rule is one of them, and a panel short of a member says which and pays only from 90%. |
| `brief` | The question quotes the task's brief, fetched from its `Posted` event and checked against `briefHash`. Bytes that miss the hash are a `FAIL`. A host that answers 404, or a location the tool refuses, is a `skip`. A host that does not answer, answers with an error or sends more than 256 KB is an `ERROR`. Either way, a grade's confidence is still recomputed, from the record's own pass level. |
| `checks` | A brief can carry checks: a fenced block marked `python checks` or `javascript checks`. The record of a grade or ruling on that brief holds BrainChain's run of them after the delivered code, and the line names the run's language and outcome. A run that failed, timed out, found no code in that language or was too long to run makes the answer reject, or refund on a ruling, at 10,000 bps. A run that passed is in the question the graders read, in BrainChain's own wording. A task record with checks in its brief and no run is a `FAIL`. |
| `levels` | A grade or ruling used the brief's own quality levels and pass level. On a grade of outside work, the pass level is a whole number naming one of the question's levels above the lowest. |
| `threshold` | The task's threshold, applied as `TaskBoard.hire`, `grade`, `rule` and `ruleAppeal` do, gives the outcome the board emitted. A poster can raise the grade and ruling thresholds while the task is open, so they can be higher than when it was posted; they cannot change after the hire. A ruling on appeal (set 3.5.0 and later) is checked against the board's `AppealRuled` event. A change is queued only on a yes. |
| `change-subject`, `change-call` | A queued change is the call the decision names and the call Jev was shown. |
| `evidence` | The record's evidence hash recomputes from the chain's `inputHash` and the record's judges, payments and versions, and equals the hash its `Recorded` event carries in `payloadURI`. |
| `versions` | The key the record names sent the decision's `Recorded` transaction, and the image and app it names are the ones the DecisionLog attested that key for. |
| `receipt` | The receipt's EIP-712 signature recovers to the key that sent the decision's `Recorded` transaction. |
| `receipt-decision` | The receipt names this decision, its DecisionLog, its chain and the record's evidence hash. |
| `receipt-outcome` | The receipt's outcome is the board's for a task, or the grade bar's for a paid grade. |
| `receipt-payment` | The receipt's payment is one the record names, and the payment transaction moved its amount from the payer to the desk. |

Some checks skip by design:

- A decision the board never applied, because a later decision or a closed window settled the task, skips `threshold`.
- A brief the host no longer has, or one at a location the tool refuses, skips `brief`. A grade's confidence is then recomputed from the record's own pass level, and `levels` skips.
- A grade recorded before the chain gated on the paid levels skips `confidence-recomputed`: its confidence is Jev's score confidence, which the probabilities alone do not give.
- A grade or ruling recorded before BrainChain ran a brief's checks skips `checks` when its brief carries some. Such a record has no `jevPaid`, which every later grade and ruling states unless its panel decided without Jev.
- A grade of outside work skips `checks` when its brief ends in a checks block and its record holds no run. The section on grades of outside work says why.

### Decided by a panel

A grade or ruling can be put to a panel: Jev, the second grader and a third judge, each asked the same question from the same state. Its record then has a `panel` field beside `second`. A record from Jev and the second grader under the lower-of rule has no `panel` field and is checked as before.

On a record with a panel, the tool checks that:

- each judge's probability of paying recomputes from its own probabilities, measured as Jev's is, and matches its `paid`. Jev's matches `jevPaid`.
- each candidate in `rules` recomputes over the judges that answered. `lower-of` is the lowest probability. `majority` is the lowest within the surest majority, which is the median with three judges. `median` is the middle probability, or the mean of the middle two.
- `rules` holds exactly `lower-of`, `majority` and `median`, and `rule` names one of them.
- the answer and confidence follow from that rule's value: accept or pay from 0.5, at the probability of the answer, and reject or refund at 100% when the brief's checks failed.
- each judge's receipt id is shown, as for the second grader.

A panel of three can decide without a member that stopped answering. `panel.degraded` then names the missing member and gives the bar, which must be 0.9: the panel pays only from 90%, and below it the answer is reject or refund. At least two judges must have answered. When the second grader is missing, the record has no `second`. When Jev is missing, the record holds none of Jev's probabilities and no `jevPaid`, and `model` names the version BrainChain asked for, which `degraded.missing` must name too.

### Evidence and versions

A record made since BrainChain kept evidence has three more fields. `versions` names the version of the questions Jev was asked, the key that recorded the decision, and the enclave image and app the DecisionLog attested that key for. `payments` lists what an agent paid for the job through BrainChain. `evidence` is one hash over what the decision rests on. A record made before has none of the three and is checked as it always was.

`evidence` is the `keccak256` of `{ input, judges, payments, versions }` in canonical form. `input` is the decision's `inputHash` on chain, in lowercase. `judges` is Jev's `{ model, probabilities }`, then `second` and each entry of `panel.judges` as `{ model, probabilities, requestHash, receipt }`. `payments` is the record's, or `[]`. None of these parts is withheld with the work, so the hash is rebuilt on a copy served without it too.

The chain holds the hash too. A decision's `payloadURI` in its `Recorded` event ends in `#evidence=` and the hash, written in the same transaction as the decision. The rebuilt hash and the record's `evidence` must both equal it, and a `payloadURI` with any other fragment fails. The tool fetches the record without the fragment, as every HTTP client does, so the location names the same file. A decision recorded before the hash went on chain has no fragment, and its rebuilt hash is held to the record's own field.

`versions.brain` must be the account that sent the decision's `Recorded` transaction. Only the log's brain can record, so that is the key that recorded it. Its image and app must be the ones in the latest `BrainAttested` event for that key at or before the decision's block. A key the owner named with `setBrain` has no such event, and its records name no image or app. `versions.prompt` is shown. It is the version of the questions on [How Jev is asked](https://docs.usebrainchain.com/how-jev-is-asked), which nothing on chain records.

### Receipts

Every job an agent pays BrainChain for gets a receipt, signed by the key that records decisions. A paid grade gets one once BrainChain decides it. A paid task gets one once the board pays or refunds it, for the grade or ruling it settled on. The receipt is EIP-712 under the domain `BrainChain receipt`, version 1, on the DecisionLog, in the envelope of the x402 offer-and-receipt extension (version 0.6): `{ format, payload, signature }`.

For each paid grade or ruling, the tool asks the host that serves the record for its receipt at `/receipts/<DecisionLog in lowercase>/<decision id>.json`. A host that has none yet is a `skip`. A host that does not answer, or answers with an error, is an `ERROR`. `--offline` turns this off, and `--receipt` checks a receipt you kept instead.

On a receipt, the tool checks that:

- the signature recovers to the account that sent the decision's `Recorded` transaction, and `payload.brain` names it. The key comes from the transaction, so a receipt still checks after a release names a new key in `brain()`.
- `chainId`, `decisionLog`, `decision` and `evidence` are this chain, this DecisionLog, this decision and the record's evidence hash.
- for a task, the board paid it for `accepted` and refunded it for `rejected`, and the last grade or ruling it applied is this decision. For a paid grade, `accepted` means accept at or above the board's grade bar when the decision was recorded.
- `network`, `asset`, `amount`, `payer` and `transaction` are those of a payment in the record, and on that network the transaction moved `amount` of `asset` from `payer` to the desk. The desk is the `payTo` for that network in the brain host's `/network.json`, which the tool believes only when `brain()` on the active DecisionLog signed it. A desk's former addresses count on EVM networks.

The tool reads payments on Base, Robinhood Chain and Solana, and on their testnets, from their public RPCs. A `/network.json` signed by another key, or naming another chain, fails `receipt-payment`. A host with no `/network.json`, or a payment on a network the tool has no RPC for, skips it. A host or RPC that does not answer is an `ERROR`, and so is a payment transaction the RPC does not find yet, since a node that lags or a Solana transaction not yet finalized can miss one. Only a transaction that reverted, or failed on Solana, fails.

### Keeping a receipt

The reply to `POST /x402/grades` carries the receipt in its `receipt` field once the grade is decided. `GET /x402/tasks/<order>` carries it once the task is paid or refunded. Save the reply, or the receipt alone, as JSON:

```sh
npx brainchain-verify mainnet --receipt reply.json
```

The receipt names its decision and its DecisionLog, so the command needs no id, and a receipt on a retired set opens that set. With an id, the receipt is held to that decision. The host serves the same receipt at `https://brain.usebrainchain.com/receipts/<DecisionLog>/<decision id>.json`, at the same address after the contracts change, so a URL works as well as a file.

The reply that delivers a paid grade also carries the extension's own receipt in its `PAYMENT-RESPONSE` header, under `extensions["offer-receipt"].info.receipt`, signed by the same key. `--receipt` reads it too. It names no decision, evidence, outcome or amount, so give the decision's id: the tool checks its signer and its network, payer and transaction, and skips `receipt-decision`.

### Records served without the work

Work stays private until it is accepted, so a grade or ruling on work that was not accepted is served with the work taken out and the header `x-brainchain-withheld: result`. That copy cannot match `payloadHash` or `inputHash`, so `record-hash` and `input-hash` skip and the verdict is `withheld`, never `match`. Exit status stays 0.

The header alone proves nothing, so the tool honours it only under the `withheld` check above. The record's answer and confidence are still held to the chain, and for a task so are its brief, levels and threshold. On a decision whose `payloadURI` carries its evidence hash, every judge's answer, Jev's included, the payments and the versions are held to that hash on chain, so a copy whose judges, payments or versions changed fails `evidence`. The question is the host's word. On an older decision, nothing ties the rest of the copy to the chain: the question, the split of the probabilities behind the confidence, the second grader and any other judge are all the host's word. The chain's rules are the records service's own: a task's work is public once it is paid or graded accepted (a house task's once graded), a paid grade's once accepted, and the delivery in an ACP evaluation never.

### Grades of outside work

A grade of work delivered outside BrainChain has no task on the board. The record's `subject` is a number, and it is checked against the decision's subject on chain by one of two rules:

- A paid grade: the number is the grade's id, and the subject is `keccak256(abi.encode("x402-grade", id))`, with the id as `bytes32`.
- An ACP evaluation: the number is the job, and the subject is `keccak256(abi.encode("acp-evaluation", chainId, job))`, for job chains 8453, 84532, 4663 and 46630.

Its answer and confidence are checked, and the confidence is recomputed from the record's own levels and pass level. Nothing on chain says what those levels should be, so `levels` skips and `threshold` skips: `payloadHash` commits them, but no brief does. The caller who paid for the grade received its verdict directly.

A paid grade runs the checks sent with its request. BrainChain appends them to the brief as its last block, and `checks` holds their run to the same rule as a task's. A caller can also write such a block into the brief's own text, where nothing runs it, and the record reads the same either way. So a brief that ends in a checks block with no run is a `skip`. An ACP evaluation runs no checks.

## Reputation entries

Each task that settles for a registered worker becomes one entry in the ERC-8004 reputation registry on Robinhood Chain (`0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`). The value is 100 when the board paid the bounty and 0 when it refunded it, under the tags `brainchain` and `task`, and the endpoint is the task's page. An entry for a task an agent paid BrainChain for points at the task's signed [receipt](#receipts): `feedbackURI` is where the receipt is served, and `feedbackHash` is the `keccak256` of the receipt as served there. Every other entry names the task page again and carries a zero hash. That covers house tasks, tasks posted straight on the board, ACP orders and entries written before receipts.

```sh
npx brainchain-verify mainnet --entry 20424:7
npx brainchain-verify mainnet --entry 20424:0xafB0C4Ef895D4895040cdC6435B96D3EE8350c6E:12
npx brainchain-verify mainnet --agent 20424 --json
```

The registry names an entry by its agent id, the address that wrote it and its index, which counts from 1 for each agent and writer. `--entry` takes the three in that order, separated by colons. BrainChain writes from `0x97D558417c3D61f1074422AD843e1Db1E565b952`, and wrote from `0xafB0C4Ef895D4895040cdC6435B96D3EE8350c6E` before 10 November 2026. Leave the writer out for an entry from the first. Anyone can write under the same tags, so the tool reads entries from these two addresses only.

On an entry, the tool checks, in order:

| Check | What passes |
| --- | --- |
| `entry` | The entry's `NewFeedback` event and the registry's `readFeedback` agree. The tags are `brainchain` and `task`, and the value is 100 or 0 with no decimals. |
| `endpoint` | The endpoint is a task page naming the task and its board, and the board is in one of the contract sets the tool carries. Entries written before 5 November name the task alone. Task ids restart with each board, so `endpoint` skips on them and the task's checks do not run. |
| `feedback-hash` | The `keccak256` of the bytes served at `feedbackURI` equals `feedbackHash`. A zero hash is a `skip` that reads `no receipt`. |
| `entry-receipt` | The receipt is one BrainChain signs. It names a decision its DecisionLog holds, in one of the contract sets the tool carries, and `feedbackURI` is that decision's receipt address. |
| the decision's checks | The decision the receipt names, checked as any decision is, with this receipt. That covers its record, its evidence hash, and the receipt's signature, outcome and payment. The lines keep their names. |
| `entry-task` | The decision's subject is `subjectOf(task)` on the board the endpoint names. |
| `entry-value` | The board paid the task for 100 and refunded it for 0. With a receipt, its outcome is `accepted` for 100 and `rejected` for 0. |
| `entry-worker` | The board's `WorkerHired` event for the task names the agent. A house worker is hired by the `keccak256` of its model name, so agent 20424 is `keccak256("claude")`. The tool carries the five house agents, 20424 to 20428, as [Worker models](https://docs.usebrainchain.com/workers#erc-8004-identity) lists them. An outside worker is hired by its address, left-padded to 32 bytes. That address must have owned the agent, or been its registered wallet, on the identity registry (`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432`) when the board hired it. |

The public RPC for Robinhood Chain keeps no past state, so the tool replays the agent's transfers and wallet changes on the identity registry up to the hire's block time. A transfer clears the wallet, as the registry does.

```text
$ npx brainchain-verify mainnet --entry 20424:7
Entry 20424:7 in the ERC-8004 reputation registry on Robinhood Chain (0x8004BAa17C55a88189AE136b182e5fdA19dE9b63)

  ok    entry: value 100 for agent 20424 under brainchain and task, written by 0x97D5…b952 in block 114772689, as the registry holds it
  ok    endpoint: task 49 on board 0x44b8…A211, contract set v3-5
  skip  no receipt: the entry's feedbackHash is zero. Only a task an agent paid BrainChain for has a signed receipt; house tasks, tasks posted straight on the board, ACP orders and older entries have none
  ok    value: 100, as the board paid task 49
  ok    worker: the board hired claude for task 49 as keccak256("claude"), and agent 20424 is the house worker claude

Verdict: no receipt. No signed receipt backs this entry, and the checks the chain allows without one passed.
Not checked: that Jev produced the answer. See https://docs.usebrainchain.com/trust-model
```

An entry's verdict is `match`, `no receipt`, `withheld`, `MISMATCH` or `UNVERIFIED`. `no receipt` means the hash is zero and every check that could run passed. `withheld` is a decision record served without the work, as for any decision.

`--agent` gives one line per entry: its verdict, its name and what it is about. Below an entry go the lines of any check that failed or could not run. The last line counts the entries, those with a receipt, those whose receipt and decision fully matched, those withheld, and those that failed. A withheld entry is never counted as verified. `--entry` with a name from the list shows every check.

```text
$ npx brainchain-verify mainnet --agent 20425
Agent 20425 in the ERC-8004 reputation registry on Robinhood Chain (0x8004BAa17C55a88189AE136b182e5fdA19dE9b63): 8 entries BrainChain wrote

  no receipt 20425:0xafB0C4Ef895D4895040cdC6435B96D3EE8350c6E:1  value 100, task 1
  no receipt 20425:0xafB0C4Ef895D4895040cdC6435B96D3EE8350c6E:4  value 100, task 22 in set v3-5
  no receipt 20425:2  value 100, task 41 in set v3-5

8 entries, 0 with a receipt, 0 verified, 0 failed.
```

Trimmed to three entries.

## What it cannot check

That Jev produced the answer. BrainChain records Jev's answers, and the contracts bound what a recorded answer can do. A decision that passes every check has the question, answer and probabilities the chain acted on. The [trust model](https://docs.usebrainchain.com/trust-model) explains what the chain relies on and what bounds it.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | Every check that could run passed. Skips do not fail a decision. A `withheld` verdict also exits 0, so read the verdict if you need to tell it from a full match. |
| 1 | A check failed, a check could not run (an `ERROR` line, such as a record, brief or receipt the host did not serve), or the decision or entry could not be read: an unknown id, a task with no decisions, an entry the registry does not hold, an RPC error, a `--receipt` that cannot be read or is not a receipt. |
| 2 | Bad arguments, or an RPC that serves another chain. |

## JSON

`--json` prints one object. `decisions` holds one entry, or one per decision with `--task`. `verdict` is `match`, `withheld`, `mismatch` or `unverified` (a record could not be fetched). With `withheld`, `withheldNotChecked` says what was left out, and the decision carries `withheld: true`. A grade of outside work carries `outside: true`. A grade or ruling that holds a run of its brief's checks carries `run`, with the run's `language` and `outcome`. A grade or ruling decided by a panel carries `panel`: its `rule`, `judges` with each judge that answered by `model` and `paid`, Jev first, and `degraded`. A degraded panel also carries `missing` and `bar`. These are the record's own values, and the `judge` and `panel` checks say whether they recompute. A decision whose record matched the evidence hash on chain carries it as `evidence`. A decision whose receipt was checked carries `receipt`: where it was read as `from`, and the `job` and `outcome` it states. Each check keeps its `name` across releases, and its `status` is `ok`, `fail`, `skip` or `error`. When the tool cannot run, it prints `{ "error": "..." }` and exits 1, or 2 for bad arguments or an RPC that serves another chain. Trimmed to one check:

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
  "notChecked": "That Jev produced the answer. BrainChain records Jev's answers, and the contracts bound what a recorded answer can do.",
  "trustModel": "https://docs.usebrainchain.com/trust-model"
}
```

With `--entry` or `--agent`, the object holds `registry`, `verdict`, `summary` and `entries` instead of `set` and `decisions`, and `agentId` with `--agent`. `verdict` is `match`, `no-receipt`, `withheld`, `mismatch` or `unverified`. It is `no-receipt` only when every check passed and no entry had a receipt. `summary` counts `entries`, `withReceipt`, `verified`, `withheld`, `failed` and `unverified`. `verified` counts only entries whose verdict is `match`. Each entry carries its name as `entry`, the fields of its `NewFeedback` event, the `task`, `board` and `set` its endpoint names, the `decision` its receipt names with its `id`, `set` and `kind`, its own `verdict` and its `checks`.

## Building

```sh
npm install
npm run build
npm test
```

`build` reads `deployments/*.json` at the repository root into `src/deployments.ts` and compiles to `dist/`. `npm run abi` regenerates `src/abi.ts` from a `forge build` at the root.

## License

MIT
