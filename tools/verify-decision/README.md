# brainchain-verify

Check any BrainChain decision against the chain. The tool reads the decision from the `DecisionLog`, fetches its published record, recomputes its hashes and confidence, and applies the task's thresholds the way the contracts do. It needs a public RPC and nothing else: no keys, no account.

Each record holds the question BrainChain asked Jev, a decision model served by TypeSafe, and Jev's answer with its probabilities. A grade or ruling also holds the answers of the judges beside Jev, open models served in a TEE through Phala's Private AI gateway, each with the receipt the gateway signed. The tool checks those receipts against the key the gateway's enclave attests.

It also checks the reputation BrainChain writes for its workers. Each entry in the ERC-8004 registry on Robinhood Chain is followed through its signed receipt to the decision, the payment and the task on the board.

It checks what the brain host signs about an agent as well: its numbered record, its licences and its papers, each held to the keys the `DecisionLog` named its brain. The host serves them once BrainChain switches agent records on, and answers 404 until then.

And it checks the orders BrainChain's desks send through 0x on Robinhood Chain: that 0x signed the quote for that exact order, and that the chain settled the order as quoted. See [desk orders](#desk-orders).

```sh
npx brainchain-verify mainnet 1 --set v3-5
npx brainchain-verify mainnet --task 11 --set v3-1
npx brainchain-verify testnet 363 --json
npx brainchain-verify mainnet --receipt receipt.json
npx brainchain-verify mainnet --entry 20424:7
npx brainchain-verify mainnet --agent 20424
npx brainchain-verify mainnet --record 20424
npx brainchain-verify mainnet --licence 20424
npx brainchain-verify mainnet --papers 20424
npx brainchain-verify desk-order 0x4829f77f52142de55f083691099fdfb5bf13ca97bbf15e1a7dc3881b74ea869f
```

Requires Node.js 22 or later.

## Usage

```text
brainchain-verify <mainnet|testnet|chainId> <decisionId> [--set <TaskBoard>] [--rpc <url>] [--payment-rpc <url>] [--offline] [--json]
brainchain-verify <mainnet|testnet|chainId> --task <taskId> [--set <TaskBoard>] [--rpc <url>] [--payment-rpc <url>] [--offline] [--json]
brainchain-verify <mainnet|testnet|chainId> [<decisionId>] --receipt <file|url> [--set <TaskBoard>] [--rpc <url>] [--payment-rpc <url>] [--offline] [--json]
brainchain-verify mainnet --entry <agentId>:[<writer>:]<feedbackIndex> [--rpc <url>] [--registry-rpc <url>] [--payment-rpc <url>] [--json]
brainchain-verify mainnet --agent <agentId> [--rpc <url>] [--registry-rpc <url>] [--payment-rpc <url>] [--json]
brainchain-verify <mainnet|testnet|chainId> --record <agentId> [--epoch] [--service <url>] [--rpc <url>] [--registry-rpc <url>] [--payment-rpc <url>] [--json]
brainchain-verify <mainnet|testnet|chainId> --licence <agentId> [--service <url>] [--rpc <url>] [--registry-rpc <url>] [--json]
brainchain-verify <mainnet|testnet|chainId> --papers <agentId> [--service <url>] [--rpc <url>] [--registry-rpc <url>] [--json]
brainchain-verify <mainnet|testnet|chainId> --item <itemId> [--service <url>] [--rpc <url>] [--json]
brainchain-verify desk-order <tx> [--quote <file|url>] [--rpc <url>] [--json]
```

| Argument | Meaning |
| --- | --- |
| `mainnet`, `testnet` or a chain id | `mainnet` is chain 274663 at `https://rpc.usebrainchain.com`; `testnet` is chain 274630 at `https://rpc.testnet.usebrainchain.com`. Either name is read in any case. |
| `<decisionId>` | The decision's number in its `DecisionLog`, from 1. |
| `--task <id>` | Check every decision about one task, oldest first. A task id the active set does not hold yet is read from the newest set that holds it, as a decision id is. |
| `--set <TaskBoard>` | A retired contract set from 3.0.0 on, by its TaskBoard address, by the key a decision page uses (`?set=v3-1`, or an older one the site still opens, such as `v4` for `v3-4`) or by release (`3.1.0`), in any case. Without it, the active set, or for an id the active set does not hold yet, the newest set that does. Each set numbers its tasks and decisions from 1. The `v2` set is not supported: its board named tasks by id alone, which the subject check does not read. |
| `--rpc <url>` | Another RPC for the same chain, or for Robinhood Chain with `desk-order`. Records and briefs on private addresses are read only when this RPC is on one too. |
| `--receipt <file\|url>` | Check the receipt for a paid job, from a JSON file or an http(s) URL, of at most 64 KB. Without a decision id, the tool checks the decision the receipt names, in the contract set its DecisionLog belongs to. See [receipts](#receipts). |
| `--entry <agentId>:[<writer>:]<index>` | Check one reputation entry BrainChain wrote. See [reputation entries](#reputation-entries). |
| `--agent <agentId>` | Check every reputation entry BrainChain wrote for one agent, oldest first. |
| `--record <agentId>` | Check an agent's numbered record on the brain host, from its first entry to its signed head. See [agent records](#agent-records). |
| `--epoch` | With `--record`: read the identity registry for the epoch the agent's id is in now, and say which entries belong to it. |
| `--licence <agentId>` | Check each licence the brain host lists for an agent. See [licences](#licences). |
| `--papers <agentId>` | Check an agent's papers. See [papers](#papers). |
| `--item <itemId>` | Check a retired exam item against the commitment it was known by. See [exam items](#exam-items). |
| `desk-order <tx>` | Check an order a BrainChain desk sent on Robinhood Chain against the 0x quote it was sent on. See [desk orders](#desk-orders). |
| `--quote <file\|url>` | With `desk-order`: the order's quote record, from a file or an http(s) URL, in place of the one the desk log names. |
| `--service <url>` | Another brain host for `--record`, `--licence`, `--papers` and `--item`. Without it, `https://brain.usebrainchain.com` on mainnet and `https://brain.testnet.usebrainchain.com` on testnet. A host on a private address is read only when `--rpc` is on one too. |
| `--registry-rpc <url>` | Another RPC for Robinhood Chain, where the ERC-8004 registries are. `--entry`, `--agent`, `--licence` and `--papers` read it, and `--record` only with `--epoch`. |
| `--payment-rpc <url>` | Another RPC for Robinhood Chain, or Robinhood Chain testnet with `testnet`, such as a fork or your own node. A receipt's payment on that chain is read from it, for a decision, `--task`, `--receipt`, `--entry`, `--agent` and `--record`. Without it, the public RPC. Payments on Base and Solana are read from their public RPCs either way. See [receipts](#receipts). |
| `--offline` | Fetch no receipt from the brain host, and no attestation from the judges' gateway. A receipt given with `--receipt` is still checked, and each judge's receipt is held to the record without its signature. |
| `--json` | One JSON object on stdout. |
| `--version` | Print the version. |

The package carries the active and retired contract sets from [`deployments/`](https://github.com/usebrainchain/brainchain/tree/main/deployments) as they stood when it was built. An unknown `--set` lists them.

Each set numbers its decisions and tasks from 1, so a new active set starts with none. A decision or task id without `--set` that the active set does not hold yet is read from the newest set that holds it. The tool says so in one line on stderr, such as `Decision 968 is not on set v3-6 yet; reading set v3-5.`, and the header names the set it read. For an id beyond every set, the tool names the set that holds the most, such as `No set holds decision 99999; set v3-5 holds 1 to 991.` With `--set`, the set is read as named, and a set that holds none yet says so, such as `Set v3-6 holds no decisions yet.` To read an older decision, name its set.

## Output

```text
$ npx brainchain-verify mainnet 22 --set v3-1
Decision 22 on BrainChain mainnet, contract set v3-1 (DecisionLog 0xbe8E68EbDEaf2C65bc13D8AD070d17098Be6d335)
Task 11: Compare the rule of 72 with the exact doubling time

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
Not checked: that Jev produced the answer, or that a judge's probabilities are the ones in the response its gateway hashed. See https://docs.usebrainchain.com/trust-model
```

Under the header, a decision about a task names the task by its brief's title, or the brief's first line, cut to 100 characters, once the brief committed on chain has been read. With `--task` that line reads `Brief:`. If the title is not the task you meant, check `--set`: each set numbers its own tasks and decisions.

Each line is one check. `ok` passed. `FAIL` means the record and the chain disagree, or the host and the chain do, as when the host's `/network.json` is signed by a key the active set does not name. `skip` is a check with nothing to run on, such as a brief the host does not have, with the reason on the line. `ERROR` is a check that could not run because something it reads could not be read: the host did not answer in up to three tries and 30 seconds in all, answered with an error, or sent more than the tool reads. A record the host does not have, or one the tool refuses to read (see `fetch`), is an `ERROR` too, since no other check can run without it. An `ERROR` line gives the reason the host sent with its error, where it sent one. With `--task` or `--agent`, a decision or entry the RPC cannot read gets one `ERROR` line, named `rpc`, and the others are still checked. Each RPC call gets two tries of 8 seconds, and an RPC error names the RPC by chain and origin, such as `BrainChain RPC https://rpc.usebrainchain.com` or `Robinhood Chain RPC https://rpc.mainnet.chain.robinhood.com`.

The verdict is `match`, `withheld`, `UNVERIFIED` or `MISMATCH`. `withheld` means a record served without the work passed the checks that could run, and says what they leave out. `--papers` and `--licence` can also give `STALE`: see [papers](#papers) and [licences](#licences). `STALE` says every other check held, so beside an `ERROR` line the verdict is `UNVERIFIED`.

## What it checks

| Check | What passes |
| --- | --- |
| `read` | `DecisionLog.get(id)` and the decision's `Recorded` event agree. |
| `fetch` | The record at the event's `payloadURI` (https, http or a base64 `data:` URI, with redirects refused) is a decision record of at most 4 MB. A body that is not JSON, such as a proxy's error page, is an `ERROR`; JSON that is not a decision record is a `FAIL`. The brain host answers 403 for the record of an exam decision while its item is still in use, which is an `ERROR` that says so: an exam decision becomes verifiable once its item is published. Briefs are read the same way, up to 256 KB. Anything on a private or loopback address is refused, however its name resolves, unless `--rpc` is on one too. |
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
| `panel` | On a decision by a panel: the candidate rules recompute from the judges' probabilities of paying, and the record's rule is one of them. Weights, which the weighted rule decides by, must be one per member and sum to 1. A panel short of a member says which and pays only from 90%. |
| `brief` | The question quotes the task's brief, fetched from its `Posted` event and checked against `briefHash`. Bytes that miss the hash are a `FAIL`. A host that answers 404, or a location the tool refuses, is a `skip`. A host that does not answer, answers with an error or sends more than 256 KB is an `ERROR`. Either way, a grade's confidence is still recomputed, from the record's own pass level. |
| `checks` | A brief can carry checks: a fenced block marked `python checks` or `javascript checks`. The record of a grade or ruling on that brief holds BrainChain's run of them after the delivered code, and the line names the run's language and outcome. A run that failed, timed out, found no code in that language or was too long to run makes the answer reject, or refund on a ruling, at 10,000 bps. A run that passed is in the question the graders read, in BrainChain's own wording. A task record with checks in its brief and no run is a `FAIL`. A paid grade can send its work as data: the checks then run alone and read it as `DELIVERY`, and the line says so. See [grades of outside work](#grades-of-outside-work). |
| `shape` | A brief can carry a JSON schema: a fenced block marked `json schema`. BrainChain checks the result against it before any grader is asked, and the tool runs the same check again on the result the record holds. The outcome and every problem it names must be the ones in the request, and the record's `shape` field must give the same outcome. A result that does not match makes the answer reject, or refund on a ruling, at 10,000 bps. Either way the question the graders read says so, in BrainChain's own wording. A record decided under prompt version 2 or later, on a brief with a schema, and with no check of it is a `FAIL`. |
| `sources` | On a grade or ruling of work that cites web pages: the request holds from 1 to 10 pages as BrainChain keeps them, each with its address, status and fetch time, and either the SHA-256 and length of the text the graders read from it (`excerptSha256`, `excerptLength`) or Exa's reason it could not be read. The question shows the graders the pages, in BrainChain's own wording, after every other line. The tool does not hold the pages to the addresses in the result, or fetch them. |
| `levels` | A grade or ruling used the brief's own quality levels and pass level. On a grade of outside work, the pass level is a whole number naming one of the question's levels above the lowest. |
| `threshold` | The task's threshold, applied as `TaskBoard.hire`, `grade`, `rule` and `ruleAppeal` do, gives the outcome the board emitted. A poster can raise the grade and ruling thresholds while the task is open, so they can be higher than when it was posted; they cannot change after the hire. A ruling on appeal (set 3.5.0 and later) is checked against the board's `AppealRuled` event. A change is queued only on a yes. |
| `change-subject`, `change-call` | A queued change is the call the decision names and the call Jev was shown. |
| `evidence` | The record's evidence hash recomputes from the chain's `inputHash` and the record's judges, payments and versions, and equals the hash its `Recorded` event carries in `payloadURI`. Since evidence version 2 the hash also covers the panel's rule, its weights under the weighted rule, a degraded panel's bar, the grade's pass level, the record's `checks` and its `shape`, so a copy served without the work cannot name another rule or another outcome of the brief's checks. The tool recomputes both versions and takes the one the chain holds; the line says when a record is version 1. When neither gives the hash, the line shows what each gives. |
| `gateway` | On a grade or ruling whose judges carry receipts: the attestation of Phala's gateway at `inference.phala.com`, read once per run for a fresh nonce, holds. A TDX quote certified by Intel's SGX root binds the nonce and the gateway's keyset, and the gateway's boot events replay to the quote. The line names the receipt key, and the app and compose hash the enclave measured. Phala's app contract on Base must allow that compose, and the receipt key's custody chain must lead to the root of Phala's dstack KMS: either failing fails the line, and a Base that cannot be read leaves it an `ERROR`. See [judges' receipts](#judges-receipts). |
| `second-grader-receipt` | The second grader's receipt is signed by a receipt key the gateway attests. It names the request the record keeps, that request is Jev's question and state as the brain puts them to a judge, the gateway verified the TEE upstream that answered, and it was served before the decision was recorded. The keyset that signed it must stand as the `gateway` line requires: its compose on Phala's list on Base, its receipt key's custody holding. On work that cites pages BrainChain read, the request cannot be rebuilt and the line skips: see [judges' receipts](#judges-receipts). |
| `judge-receipt` | The same, for each judge on a panel after the second grader. |
| `versions` | The key the record names sent the decision's `Recorded` transaction, and the image and app it names are the ones the DecisionLog attested that key for. |
| `receipt` | The receipt's EIP-712 signature recovers to the key that sent the decision's `Recorded` transaction. |
| `receipt-decision` | The receipt names this decision, its DecisionLog, its chain and the record's evidence hash. A version 2 receipt also names the decision's subject, the task or the paid grade, which must be the subject on the log. Version 1 receipts, signed before receipts named their subject, check as before. |
| `receipt-outcome` | The receipt's outcome is the board's for a task, or the grade bar's for a paid grade. |
| `receipt-payment` | The receipt's payment is one the record names, and the payment transaction moved its amount from the payer to the desk. |

Some checks skip by design:

- A decision the board never applied, because a later decision or a closed window settled the task, skips `threshold`.
- A brief the host does not have, or one at a location the tool refuses, skips `brief`. A grade's confidence is then recomputed from the record's own pass level, and `levels` skips.
- A grade recorded before the chain gated on the paid levels skips `confidence-recomputed`: its confidence is Jev's score confidence, which the probabilities alone do not give.
- A grade or ruling recorded before BrainChain ran a brief's checks skips `checks` when its brief carries some. Such a record has no `jevPaid`, Jev's probability of paying, which every later grade and ruling states unless its panel decided without Jev.
- A grade of outside work skips `checks` when its brief ends in a checks block and its record holds no run. The section on grades of outside work says why.
- A judge that answered without a receipt skips its receipt line. With `--offline`, `gateway` skips, and so does the signature on each judge's receipt, while its request and upstream are still checked. A receipt on a decision recorded before 2026-11-06 03:39 UTC skips its signature: see [known history](#known-history).
- A grade or ruling decided before prompt version 2, or naming no prompt version, skips `shape` when its brief fences a JSON schema. BrainChain started checking results against a schema with prompt version 2.
- A grade or ruling of work that cites pages BrainChain read skips each judge's receipt line once everything else on the receipt holds. The judge's signed request covers page text the record keeps only as a fingerprint, so it cannot be rebuilt from the record.

### Decided by a panel

A grade or ruling can be put to a panel: Jev, the second grader and a third judge, each asked the same question from the same state. Its record then has a `panel` field beside `second`. A record from Jev and the second grader under the lower-of rule has no `panel` field and is checked as before.

On a record with a panel, the tool checks that:

- each judge's probability of paying recomputes from its own probabilities, measured as Jev's is, and matches its `paid`. Jev's matches `jevPaid`.
- each candidate in `rules` recomputes over the judges that answered. `lower-of` is the lowest probability. `majority` is the lowest within the surest majority, which is the median with three judges. `median` is the middle probability, or the mean of the middle two. `weighted` is each member's weight times its probability, added up in panel order and rounded to four decimals, as `median` is.
- `rules` holds `lower-of`, `majority` and `median`, and `weighted` only when the record carries weights. `rule` names one of the four.
- the answer and confidence follow from that rule's value: accept or pay from 0.5, at the probability of the answer, and reject or refund at 100% when the brief's checks failed or the result does not match the brief's JSON schema.
- each judge's receipt is checked as the second grader's is: see [judges' receipts](#judges-receipts).

Under the weighted rule the panel pays on a blend of its members' answers. `panel.weights` gives one weight per member in panel order: Jev first, then the second grader, then each judge after it, counting any member the panel decided without. Each weight is from 0 to 1, and together they sum to 1 to four decimals. With Jev at 0.25 and the second grader at 0.75, a grade pays when 0.25 × Jev's probability of a paid level plus 0.75 × the second grader's reaches 0.5. A record that names `weighted` without weights fails `panel`, as do weights that do not sum to 1 or do not give each member one. Versions before 0.12.0 do not know the rule: on a weighted record they fail `panel` and `evidence` and give `MISMATCH`, never a match.

A panel of three can decide without a member that stopped answering. `panel.degraded` then names the missing member and gives the bar, which must be 0.9: the panel pays only from 90%, and below it the answer is reject or refund. At least two judges must have answered. When the second grader is missing, the record has no `second`. When Jev is missing, the record holds none of Jev's probabilities and no `jevPaid`, and `model` names the version BrainChain asked for, which `degraded.missing` must name too.

Under the weighted rule, a panel short of a member divides each answering member's weight by the sum of the answering weights, so the members that answered decide as a full panel would, and only from 90%. Answering weights that sum to 0 give the rule no value, and BrainChain waits rather than decide, so a record that decides by it then fails `panel`. The record keeps the judges after the second grader that answered apart from those missing, so with two or more of them it may not say which place a missing judge held. The record's `weighted` value must then be one that some such order gives.

### Judges' receipts

The second grader and any other judge on a panel answer through Phala's Private AI gateway at `inference.phala.com`, which runs in an Intel TDX enclave. For every answer the gateway signs a receipt with an Ed25519 key it publishes in its attestation. BrainChain keeps the receipt in the record, as `second.receipt.body` or `panel.judges[i].receipt.body`, beside `requestHash`, the SHA-256 of the request it sent. The evidence hash covers both.

On decision 706 on set v3-6 the two lines read:

```text
  ok    gateway: inference.phala.com attests receipt key c9bd…f34e: a TDX quote that Intel's SGX root certifies binds its keyset, sha256:c34f…9253, to this run's nonce, and measures app 89c5…2a0f and compose f713…ace1. Phala's app contract on Base allows its compose, f713…ace1, and its receipt key's custody holds: the dstack KMS chain runs from that key through app 89c5…2a0f to the root of Phala's KMS contract on Base, 02a3…f721
  ok    the second grader's receipt rcpt-ea84fcff3e760d506d2b61f2 is signed by inference.phala.com's receipt key c9bd…f34e. The gateway received the request the record names, sha256:5eea…9ce0, which is Jev's question and state put to deepseek/deepseek-v4.1-flash-1017, and served it at 2026-11-27 21:12:41 UTC from a TEE upstream it verified, in session 0298…c459, whose record, as inference.phala.com serves it, hashes to that id and was in force when it served the answer. Of the keyset that signed it, Phala's app contract on Base allows its compose, f713…ace1, and its receipt key's custody holds: the dstack KMS chain runs from that key through app 89c5…2a0f to the root of Phala's KMS contract on Base, 02a3…f721
```

The tool reads the gateway's attestation once per run, from `/v1/aci/attestation` with a fresh 32-byte nonce, and checks that:

- the keyset, in JCS form ([RFC 8785](https://www.rfc-editor.org/rfc/rfc8785)), hashes to the `workload_keyset_digest` the report states.
- the quote is a version 4 TDX quote whose PCK certificate chain ends at the Intel SGX Root CA, held by its certificate's SHA-256 fingerprint, `44A0196B…74D3`. The PCK key signs the quoting enclave's report, that report vouches for the attestation key, and the attestation key signs the quote. Each certificate is valid at the time of the run.
- the quote's report data is the SHA-256 of `{"keyset_digest":"<digest>","nonce":"<nonce>","purpose":"aci.report_data.v1"}` for this run's nonce, so the report was made for this run.
- the enclave is not a debug TD, and the keyset has not expired.
- the boot events replay to the quote's RTMR3, each digest recomputed from its event as dstack writes it (version 1 or 2), and the compose hash they measured is the SHA-256 of the compose file the report carries. The app id and compose hash are the first of each before `system-ready`, as dstack reads them.
- the release: Phala publishes each production release of the gateway with its compose hash at least three days ahead, in [Dstack-TEE/private-ai-gateway](https://github.com/Dstack-TEE/private-ai-gateway/releases), and the app contract on Base, `0x89c51ab856bee41efe78c40309a4deb277a02a0f`, answers `allowedComposeHashes(bytes32)` for the composes allowed to boot. The tool reads it once per run per compose, through `mainnet.base.org` and then `base-rpc.publicnode.com`, as it stands now, so a release Phala withdraws reads as withdrawn. A compose it does not allow is a `FAIL`. With no answer from Base the line is an `ERROR`.
- the receipt key's custody, check id-5 of Phala's `pap`, ported: the report's `key_custody` entry for the receipt key is a dstack KMS chain of two secp256k1 signatures. The first, by an app key, signs `aci.receipt.ed25519.v1:` and the KMS key it derives the receipt key from; the second, by the KMS root, signs `dstack-kms-issued:`, the app id the boot measured and that app key. The root must be `02a335ae…f721`, which Phala's KMS contract on Base, `0x2f83172A49584C017F2B256F0FB2Dca14126Ba9C`, names as its root in `kmsInfo()`, and the app id must be Phala's gateway, `89c5…2a0f`. Every receipt key the keyset lists must be the one the chain covers. A chain that does not hold is a `FAIL`. It needs no network.

On each judge's receipt, it checks that:

- the keyset that signed it, the live one or one BrainChain's gateway kept, stands as above: its compose on Phala's list on Base and its receipt key's custody holding. A keyset that does not fails the receipt, and a Base that cannot be read leaves it an `ERROR`.
- the signature is Ed25519 over the JCS form of the receipt without `signature`, by the key in the attested keyset that `key_id` names. The gateway renews its keyset as it restarts and has kept the same receipt key since 2026-11-06, so a receipt that cites an earlier keyset still verifies, and the line names both keysets.
- `receipt_id`, `model`, `method` and `endpoint` are the record's receipt id, the judge's model, `POST` and `/v1/chat/completions`.
- the gateway's `request.received` hash is the record's `requestHash`, and that hash rebuilds from the record's question and state as the brain sends them to a judge (`promptFor` in the brain's `judges.ts`, with `max_tokens` 8000, or 2000 before 2026-11-03). A copy served without the work cannot rebuild it, and the line says so. Nor can a record of work that cites pages BrainChain read: Jev and the judges were sent up to 3,000 characters of each page, and the record keeps only the SHA-256 of that text, `excerptSha256`, its length and a quote of at most 300 characters. The line is then a `skip` that names each fingerprint, and every other part of the receipt is still checked. Anyone who holds a page's text can hold it to its fingerprint, as [How Jev is asked](https://docs.usebrainchain.com/how-jev-is-asked) describes. When no cited page was read, the record holds everything the judges were sent, and the tool rebuilds their request without each page's fetch time, which they were not sent.
- `upstream.verified` has `result` `verified`, `required` true and a session id: the gateway verified the TEE upstream before it forwarded the request.
- the session record that id names hashes to it in JCS form, is an `aci/1` record, was in force when the answer was served (`established_at` to `expires_at`), and its evidence hashes to the digest it states. Phala serves a session record at `inference.phala.com/v1/aci/sessions/<id>` for about an hour. After that the tool reads it from BrainChain's inference gateway (`inference.usebrainchain.com/v1/served/sessions/<id>`), which keeps each record the brain's receipts cite, exactly as Phala served it, for decisions from 2026-11-27 13:10 UTC. Since the record must hash to the id in the signed receipt, the gateway's copy is checked like Phala's. A record neither serves is not checked, and the line does not name a session.
- `served_at` is at most five minutes after the decision was recorded, which allows for the gateway's clock and the chain's.

A signature that does not verify under the key of the keyset the receipt cites fails. A receipt that cites a keyset the gateway no longer serves, and does not verify under the key it serves now, is checked against the attestation report BrainChain's inference gateway kept for that keyset (`inference.usebrainchain.com/v1/served/keysets/<hex>`), held to Intel's root as it is above, as of when the answer was served. That report was read with the gateway's nonce, not this run's, so it shows that the enclave held the key, not when. A kept report that does not hold is a `FAIL`; with no kept report, or one that cannot be read, the line is an `ERROR`, since the key that signed it cannot be read. A gateway that does not answer is an `ERROR` on the `gateway` line, and an attestation that does not hold is a `FAIL` there. Either way each judge's signature then skips, while its request and upstream are still checked.

A receipt shows that the gateway received exactly the request in the record and served it from a verified TEE upstream. It also hashes the response the gateway returned (`response.returned`), but the record keeps each judge's probabilities, not its response, so nothing ties the probabilities to that hash. The tool does not appraise the platform's TCB level against Intel's collateral, or the upstream's own attestation inside the session record, which Phala's gateway verified. The custody chain shows that the KMS issued the key the receipt key is derived from to Phala's app; that the Ed25519 receipt key is the one derived from it rests on the code the compose runs, which is why the compose is held to Phala's list. Where the TLS and E2EE keys are held is not checked.

### Evidence and versions

A record made since BrainChain kept evidence has three more fields. `versions` names the version of the questions Jev was asked, the key that recorded the decision, and the enclave image and app the DecisionLog attested that key for. `payments` lists what an agent paid for the job through BrainChain. `evidence` is one hash over what the decision rests on. A record made before has none of the three and is checked as it always was.

`evidence` is the `keccak256` of an object in canonical form, in one of two versions:

- Version 1 is `{ input, judges, payments, versions }`. `input` is the decision's `inputHash` on chain, in lowercase. `judges` is Jev's `{ model, probabilities }`, then `second` and each entry of `panel.judges` as `{ model, probabilities, requestHash, receipt }`. `payments` is the record's, or `[]`.
- Version 2 is `{ version: 2, input, judges, payments, versions }` with the same parts, and four more where the record has them. `panel` is `{ rule }`, the record's `panel.rule`, with the record's `panel.weights` beside it when the rule is `weighted` and the record's `panel.degraded` when the panel decided without a member. Weights under any other rule are left out, so those records hash as they did before weights. `passFrom` is the grade's pass level. `checks` is how the brief's checks ran, `passed` or `failed`. `shape` is how the result matched the brief's JSON schema, `passed` or `failed`. A copy served without the work then cannot name another rule, weights, bar or pass level than the decision was made on, nor another outcome of the checks or of the schema.

None of these parts is withheld with the work, so the hash is rebuilt on a copy served without it too. The tool rebuilds both versions and holds the record to the one the chain carries, as below, so a record made under version 2 cannot pass as version 1. The `evidence` line says when a record is version 1.

The chain holds the hash too. A decision's `payloadURI` in its `Recorded` event ends in `#evidence=` and the hash, written in the same transaction as the decision. The rebuilt hash and the record's `evidence` must both equal it, and a `payloadURI` with any other fragment fails. The tool fetches the record without the fragment, as every HTTP client does, so the location names the same file. A decision recorded before the hash went on chain has no fragment, and its rebuilt hash is held to the record's own field.

`versions.brain` must be the account that sent the decision's `Recorded` transaction. Only the log's brain can record, so that is the key that recorded it. Its image and app must be the ones in the latest `BrainAttested` event for that key at or before the decision's block. When they are not, and the log has never attested that key for the image or app the record names, the line says so. Where it is the app, the line points to [known history](#known-history). A key the owner named with `setBrain` has no such event, and its records name no image or app. `versions.prompt` is shown. It is the version of the questions on [How Jev is asked](https://docs.usebrainchain.com/how-jev-is-asked), which nothing on chain records. BrainChain's own tests pin each version to a fingerprint, the `keccak256` of the canonical JSON of every question it asks and the framing its judges read, so a change to any of them needs a new version:

| Prompt version | Fingerprint | What it added |
| --- | --- | --- |
| 1 | `0x7e4ffe22a3e62e80edabc1f2a70c872a6c9517658be446c6876c2e9b3a81109c` | The first numbered set |
| 2 | `0xb28dcb2bb83a3e884fe426cbd9abf09840848589cbafea21fbfa5fb3f1f83f49` | The line that shows the graders a result's check against the brief's JSON schema |
| 3 | `0x8ebdb89216f8757f5643edef8e470c408edc8d33a3a85e863d8952f0887dc0e5` | The line for checks run alone on delivered data, and the line for the pages a result cites |

A record carries the version, not the fingerprint, so the tool shows the version and checks each line it knows where BrainChain puts it.

### Receipts

Every job an agent pays BrainChain for gets a receipt, signed by the key that records decisions. A paid grade gets one once BrainChain decides it. A paid task gets one once the board pays or refunds it, for the grade or ruling it settled on. Records from before receipts have none. The receipt is EIP-712 under the domain `BrainChain receipt` on the DecisionLog and BrainChain's chain id, in the envelope of the x402 offer-and-receipt extension (version 0.6): `{ format, payload, signature }`. The payload's `version` is also the domain's version:

- Version 1 signs `version`, `chainId`, `decisionLog`, `decision`, `brain`, `evidence`, `job`, `outcome`, `network`, `payer`, `asset`, `amount`, `transaction` and `issuedAt`, under domain version "1".
- Version 2 also signs `subject`, the decision's subject on the log as a `bytes32`, after `decision`, under domain version "2". It names the task or the paid grade the receipt is for.

A version 2 receipt without a subject, or a version 1 receipt with one, is not a receipt BrainChain signs.

For a grade or ruling whose record has a `payments` field, the tool asks the host that serves the record for its receipt at `/receipts/<DecisionLog in lowercase>/<decision id>.json`. A record without one, as every record from before receipts is, gets no receipt line. A host that has none yet is a `skip`. A host that does not answer, or answers with an error, is an `ERROR`. `--offline` turns this off, and `--receipt` checks a receipt you kept instead.

On a receipt, the tool checks that:

- the signature recovers to the account that sent the decision's `Recorded` transaction, and `payload.brain` names it. The key comes from the transaction, so a receipt still checks after a release names a new key in `brain()`.
- `chainId`, `decisionLog`, `decision` and `evidence` are this chain, this DecisionLog, this decision and the record's evidence hash. On a version 2 receipt, `subject` is the decision's subject on the log.
- for a task, the board paid it for `accepted` and refunded it for `rejected`, and the last grade or ruling it applied is this decision. For a paid grade, `accepted` means accept at or above the board's grade bar when the decision was recorded.
- `network`, `asset`, `amount`, `payer` and `transaction` are those of a payment in the record, and on that network the transaction moved `amount` of `asset` from `payer` to the desk. The desk is the `payTo` for that network in the brain host's `/network.json`, which the tool believes only when `brain()` on the active DecisionLog signed it. A desk's former addresses count on EVM networks.

The tool reads payments on Base, Robinhood Chain and Solana, and on their testnets, from their public RPCs. `--payment-rpc` reads Robinhood Chain from another RPC, such as a fork or your own node, and must serve that chain. A `/network.json` signed by another key, or naming another chain, fails `receipt-payment`. That holds for a retired set's brain too, since a retired key may have been exposed after it was retired. The line then names that set and says BrainChain is probably switching sets: run the command again later, or, for a receipt fetched from the host, with `--offline` to check the decision without it. A host with no `/network.json`, or a payment on a network the tool has no RPC for, skips it. A host or RPC that does not answer is an `ERROR`, and so is a payment transaction the RPC does not find yet, since a node that lags or a Solana transaction not yet finalized can miss one. Only a transaction that reverted, or failed on Solana, fails.

### Keeping a receipt

The reply to `POST /x402/grades` carries the receipt in its `receipt` field once the grade is decided. `GET /x402/tasks/<order>` carries it once the task is paid or refunded. Save the reply, or the receipt alone, as JSON:

```sh
npx brainchain-verify mainnet --receipt reply.json
```

The receipt names its decision and its DecisionLog, so the command needs no id, and a receipt on a retired set opens that set. With an id, the receipt is held to that decision. The host serves the same receipt at `https://brain.usebrainchain.com/receipts/<DecisionLog>/<decision id>.json`, at the same address after the contracts change, so a URL works as well as a file.

The reply that delivers a paid grade also carries the extension's own receipt in its `PAYMENT-RESPONSE` header, under `extensions["offer-receipt"].info.receipt`, signed by the same key. `--receipt` reads it too. It names no decision, evidence, outcome or amount, so give the decision's id: the tool checks its signer and its network, payer and transaction, and skips `receipt-decision`.

### Records served without the work

Work stays private until it is accepted, so a grade or ruling on work that was not accepted is served with the work taken out and the header `x-brainchain-withheld: result`. That copy cannot match `payloadHash` or `inputHash`, so `record-hash` and `input-hash` skip and the verdict is `withheld`, never `match`. Exit status stays 0.

The header alone proves nothing, so the tool honours it only under the `withheld` check above. The record's answer and confidence are still held to the chain, and for a task so are its brief, levels and threshold. On a decision whose `payloadURI` carries its evidence hash, every judge's answer, Jev's included, the payments and the versions are held to that hash on chain, so a copy whose judges, payments or versions changed fails `evidence`. The question is the host's word. On an older decision, nothing ties the rest of the copy to the chain: the question, the split of the probabilities behind the confidence, the second grader and any other judge are all the host's word. The chain's rules are the records service's own: a task's work is public once it is paid or graded accepted (a house task's once graded), a paid grade's once accepted, and the delivery in an ACP evaluation never. The work is the result, any data delivered with it, what a run of its code printed or raised, and the address, title and quote of each page it cites. A copy that leaves any of these readable is not the service's, and the tool does not take it as withheld.

### Grades of outside work

A grade of work delivered outside BrainChain has no task on the board. The record's `subject` is a number, and it is checked against the decision's subject on chain by one of two rules:

- A paid grade: the number is the grade's id, and the subject is `keccak256(abi.encode("x402-grade", id))`, with the id as `bytes32`.
- An ACP evaluation: the number is the job, and the subject is `keccak256(abi.encode("acp-evaluation", chainId, job))`, for job chains 8453, 84532, 4663 and 46630.

Its answer and confidence are checked, and the confidence is recomputed from the record's own levels and pass level. Nothing on chain says what those levels should be, so `levels` skips and `threshold` skips: `payloadHash` commits them, but no brief does. The caller who paid for the grade received its verdict directly.

A paid grade runs the checks sent with its request. BrainChain appends them to the brief as its last block, and `checks` holds their run to the same rule as a task's. A caller can also write such a block into the brief's own text, where nothing runs it, and the record reads the same either way. So a brief that ends in a checks block with no run is a `skip`. An ACP evaluation runs no checks.

A paid grade can also send its work as data, such as a JSON report, beside the result. The checks then run alone in a fresh interpreter where `DELIVERY` holds the data, and no code from the result runs. The request carries the data as `data`, the run is marked `"mode": "data"`, and the question shows the graders BrainChain's line for a run on data in place of its two lines for a run of the code. `checks` reads a run as one on data only when the request holds the data and the run says so, and fails a record that has one without the other. A run that passed must be shown to the graders with the line for how it ran. A run of the code whose checks read `DELIVERY` is not a run on data: the result's code ran first, in the same interpreter, and could define `DELIVERY` itself, so the line says the checks ran on the delivered code.

## Reputation entries

Each task that settles for a registered worker becomes one entry in the ERC-8004 reputation registry on Robinhood Chain (`0x8004BAa17C55a88189AE136b182e5fdA19dE9b63`). The value is 100 when the board paid the bounty and 0 when it refunded it, under the tags `brainchain` and `task`, and the endpoint is the task's page. An exam sitting becomes one too, under `brainchain` and `licence:<class>`, with 100 for a pass and the agent's licences on the brain host as its endpoint.

`feedbackURI` and `feedbackHash` commit to one of two things:

- An entry of the agent's [record](#agent-records). `feedbackURI` is where the brain host serves that record entry, and `feedbackHash` is the `keccak256` of the bytes served there. The record entry names the task's signed [receipt](#receipts) where an agent paid BrainChain for the task.
- The receipt itself, on an entry written before BrainChain kept agents' records. Every other entry from that time names the task page again and carries a zero hash. That covers house tasks, tasks posted straight on the board, ACP orders and entries written before receipts.

```sh
npx brainchain-verify mainnet --entry 20424:7
npx brainchain-verify mainnet --entry 20424:0xafB0C4Ef895D4895040cdC6435B96D3EE8350c6E:12
npx brainchain-verify mainnet --agent 20424 --json
```

The registry names an entry by its agent id, the address that wrote it and its index, which counts from 1 for each agent and writer. `--entry` takes the three in that order, separated by colons. BrainChain writes from `0x97D558417c3D61f1074422AD843e1Db1E565b952`, and wrote from `0xafB0C4Ef895D4895040cdC6435B96D3EE8350c6E` before 10 November 2026. Leave the writer out for an entry from the first. Anyone can write under the same tags, so the tool reads entries from these two addresses only.

On an entry, the tool checks, in order:

| Check | What passes |
| --- | --- |
| `entry` | The entry's `NewFeedback` event and the registry's `readFeedback` agree. The tags are `brainchain` and `task`, or `brainchain` and `licence:<class>` for an exam, and the value is 100 or 0 with no decimals. |
| `endpoint` | The endpoint is a task page naming the task and its board, and the board is in one of the contract sets the tool carries. Entries written before 5 November name the task alone. Task ids restart with each board, so `endpoint` skips on them and the task's checks do not run. An exam outcome's endpoint is `/licences/<chain>/<agentId>` on the brain host. |
| `feedback-hash` | The `keccak256` of the bytes served at `feedbackURI` equals `feedbackHash`. A zero hash is a `skip` that reads `no receipt`, or `no record entry` on an exam outcome. |
| `entry-record` | On an entry that points at a record entry: the file is a record entry as BrainChain signs one, for the feedback's agent on the identity registry, served at its own address, `/agents/<chain>/<agentId>/record/<seq>.json`. Its kind fits the tag: `task` or `audit` under `task`, `exam` under `licence:<class>`. A task's `ref` is the task the endpoint names. An exam's `ref` is `sitting:<id>`, and it names no receipt. |
| `entry-signature` | The record entry's signature recovers to the `brain` it names. |
| `entry-brain` | The DecisionLog the record entry names had named that key its brain when the entry was signed. See [the brain key](#the-brain-key). |
| `entry-outcome` | The value is 100 for a record entry that says `accepted`, and 0 for `rejected` or `undelivered`. |
| `record-receipt` | The receipt the record entry names, read from the host that serves the entry, hashes to the hash the entry carries. |
| `record-settled` | The record entry and its receipt state the same outcome, the same payment and the same decision. |
| `entry-receipt` | The receipt is one BrainChain signs. It names a decision its DecisionLog holds, in one of the contract sets the tool carries, and it is served at that decision's receipt address. |
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
Not checked: that Jev produced the answer, or that a judge's probabilities are the ones in the response its gateway hashed. See https://docs.usebrainchain.com/trust-model
```

An entry's verdict is `match`, `no receipt`, `withheld`, `MISMATCH` or `UNVERIFIED`. `no receipt` means the hash is zero and every check that could run passed. `withheld` is a decision record served without the work, as for any decision.

An entry that points at a record entry with no receipt is a `match` when its checks pass: the brain key signed that outcome for that agent. No decision or payment stands behind such an entry, so none is checked. For a task, `entry-value` and `entry-worker` still hold the value and the agent to the board. For an exam, nothing on a board states the outcome, and the entry rests on the brain key's signature alone.

`--agent` gives one line per entry: its verdict, its name and what it is about. Below an entry go the lines of any check that failed or could not run. The last line counts the entries, those with a receipt, those whose receipt and decision fully matched, those withheld, and those that failed. A withheld entry is never counted as verified. `--entry` with a name from the list shows every check.

```text
$ npx brainchain-verify mainnet --agent 20426
Agent 20426 in the ERC-8004 reputation registry on Robinhood Chain (0x8004BAa17C55a88189AE136b182e5fdA19dE9b63): 10 entries BrainChain wrote

  no receipt 20426:0xafB0C4Ef895D4895040cdC6435B96D3EE8350c6E:1  value 100, task 8
  no receipt 20426:0xafB0C4Ef895D4895040cdC6435B96D3EE8350c6E:2  value 100, task 53 in set v3-4
  no receipt 20426:1  value 0, task 38 in set v3-5

10 entries, 0 with a receipt, 0 verified, 0 failed.
```

Trimmed to three entries.

## Agent records

BrainChain keeps a numbered record for each ERC-8004 agent whose work it judges. Every outcome is one entry: a task, an audit or an exam sitting, each `accepted`, `rejected` or `undelivered`. Entries count from 1, and each names the hash of the one before it. The brain key signs every entry. It also signs the head, which is the number and hash of the latest entry, whenever the head is asked for. A reader that holds entries 1 to n and a fresh head for entry n holds the whole record: an entry cannot be left out without breaking the chain or disagreeing with the head.

The brain host serves the record at `/agents/<chain>/<agentId>/record`. `<chain>` is the chain the agent's id is on: 4663 (Robinhood Chain) for mainnet and 46630 for testnet.

```sh
npx brainchain-verify mainnet --record 20424
npx brainchain-verify mainnet --record 20424 --epoch
```

The tool reads the record 200 entries at a time until the host names no next page, up to 20,000 entries. It then checks:

| Check | What passes |
| --- | --- |
| `record-fetch` | The host served a signed head and a list of entries, each a record entry as BrainChain signs one. A host with no record for the agent answers 404, which is an `ERROR`, since no other check can run without the record. On a 404 that gives no other reason, the line says the host serves records, licences and papers once BrainChain switches agent records on. |
| `record-agent` | Every entry and the head name the agent asked for, on the identity registry (`0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` on Robinhood Chain). The tool carries no registry address for Robinhood Chain testnet. There the entries must name the registry the head names, and the line says the address is the record's own. |
| `record-chain` | Entries are numbered from 1 with no gap. Each entry's `prev` is the hash of the entry before it, and the first entry's is 32 zero bytes. An entry's hash is the `keccak256` of `{ entry, signature }` in canonical JSON, the bytes the host serves at `/record/<seq>.json`. |
| `record-signatures` | Each entry's signature recovers to the `brain` the entry names. The signature is `personal_sign` over the line `BrainChain record entry` and then the entry in canonical JSON. |
| `record-head` | The head's signature, over the line `BrainChain record head` and then the head, recovers to the `brain` it names. Its `seq` is the last entry's number and its `hash` is the last entry's hash. The host leaves an entry written after it signed the head for the next read, so a list that runs past its own head fails here. |
| `record-fresh` | The head was signed at most 15 minutes ago by this machine's clock, and is dated at most 5 minutes ahead of it. The line gives the time. An older head could leave out entries written since. |
| `record-brain` | Each key that signed an entry, and the key that signed the head, was the DecisionLog's brain when it signed. See [the brain key](#the-brain-key). |
| `record-epochs` | Each entry's `epoch` is `keccak256(abi.encode(chainId, registry, agentId, controller, build))` over the entry's own fields. |
| `record-refs` | A task or an audit names `task:<board>:<id>`. An exam names `sitting:<id>` and no receipt. No ref appears twice. |
| `record-receipt` | One line for each entry that names a receipt. The receipt, read from the host at the entry's `receipt.path`, hashes to `receipt.hash`, and is checked with the decision it names as [receipts](#receipts) describes. That decision is about the task the entry's `ref` names, and the entry states the receipt's outcome, payment and decision. A receipt with a check that could not run, such as an entry for a task on a board the tool does not carry, is a `skip` that names those checks, and counts among the skipped. |
| `current-epoch` | With `--epoch`: the epoch the identity registry gives the id now, and the entries that belong to it. See [the current epoch](#the-current-epoch). |

Below the checks, the tool lists each epoch in the record with its controller, its build and its counts by kind and outcome, recomputed from the entries. The report below is from a test record, so its agent, keys and hashes are not on mainnet:

```text
Agent 501's record on BrainChain mainnet, read from https://brain.usebrainchain.com/agents/4663/501/record

  ok    fetched 3 entries and the head from https://brain.usebrainchain.com/agents/4663/501/record
  ok    agent: every entry and the head are for agent 501 on registry 0x8004…a432, chain 4663
  ok    chain: entries 1 to 3 are numbered with no gap, each names the hash of the one before it, and the first names none
  ok    signatures: each of the 3 entries is signed by the brain it names
  ok    head: signed by 0x08c8…57dd, the brain it names. It ends at entry 3 with the hash 0x2134…73dd, as the entries do
  ok    fresh: the head was signed 2026-11-18 18:36:21 UTC, 12 seconds ago
  ok    brain: 0x08c8…57dd was the brain of DecisionLog 0x2EF5…cB68 (set v3-5), the active set's, when it signed entries 1 to 3 and the head
  ok    epochs: each entry's epoch is the hash of its agent, controller and build
  ok    refs: each entry names a task or a sitting as its kind does, and none is named twice

Epochs in the record
  epoch 0xca4e…6457, controller 0x0000…00C7, build "worker-1", since entry 1 (2026-11-18 18:28:14 UTC): task 1 accepted, 1 rejected
  epoch 0x64e7…56ce, controller 0x0000…00C7, build "worker-2", since entry 3 (2026-11-18 18:28:16 UTC): exam 1 accepted

Verdict: match. The record is whole: 3 entries, chained from the first to a head the brain key signed at 2026-11-18 18:36:21 UTC, each signed by a key its DecisionLog named its brain.
Not checked: that an entry without a receipt states what the board did, or that the agent runs the build its entries name. See https://docs.usebrainchain.com/trust-model
```

When a receipt fails a check or has one that could not run, those lines of the receipt and its decision follow the record's own lines.

### The brain key

Everything the brain host signs about an agent names BrainChain's chain id, a `decisionLog` and the `brain` key that signed. The tool takes a signature as genuine when it recovers to that `brain` and a `BrainSet` event on that DecisionLog made the key its brain:

- The `decisionLog` is the DecisionLog of a contract set the tool carries for the network, active or retired, and the chain id is the network's.
- A `BrainSet` event on that DecisionLog names the key. The contract writes `brain` in its constructor, in `setBrain` and in `attestBrain`, and each emits `BrainSet(brain)`, so these events are the whole history of `brain()`. The tool reads them from the set's first block. The last one must name the key `brain()` returns now. If it does not, the RPC returned only part of the events, and the check is an `ERROR`.
- The time the object gives for itself falls within the key's tenure: from the block time of the `BrainSet` event that named it to the block time of the next one, with five minutes either side for clocks that differ. That time is `issuedAt` on an entry or a licence, and `at` on a head or on papers.

The time an object gives for itself is the signer's own statement, so the tool checks it against the key's tenure and no more. What anchors a record in the present is its head: signed now, by the brain of the active DecisionLog. So a head must name the active set's DecisionLog, and its time is also held to this machine's clock. Papers are held to the same two rules.

### What a matching record shows

A `match` shows that these entries are the whole record as the brain key signed it at the time the head states. No entry was left out, changed or put in another order since, and each was signed by a key the DecisionLog had named its brain.

It does not show that an entry is true. For an entry with a receipt, the receipt's checks tie the outcome to the decision, the board and the payment. For an entry without one, the outcome is the brain key's statement. `--agent` holds each entry in the reputation registry to the board's settlement and hire for the same task. The `build` an entry names is what the agent's controller declared. For an agent BrainChain runs itself it is `house: <model id>`, the model BrainChain runs it on. Nothing tests that the agent runs the build its entry names.

The record is the brain key's own account of the agent. The reputation registry pins part of it on Robinhood Chain: each ERC-8004 entry carries the hash of the record entry it points at, and `--agent` checks that hash.

A record is checked as far as its head. An entry written after the head was signed is in the next run.

### The current epoch

An epoch is one agent id under one controller and one declared build. A new controller or a new build starts a new epoch. Earlier entries keep the epoch they were written under.

With `--epoch`, the tool reads the ERC-8004 identity registry on Robinhood Chain and works out the epoch the id is in now, as the brain does:

- The controller is the registry's `ownerOf(agentId)`. If that owner is the binding adapter `0x000000009d62675362a58911e3f32FEcf46F5E18`, the id is bound to an NFT. `bindingOf(agentId)` on the adapter gives the standard, the token contract and the token id, and the controller is `ownerOf(tokenId)` on that contract. Only standard 0, ERC-721, is read. An id that does not exist, a token nobody holds and any other standard have no controller. A token contract whose `ownerOf` reverts, runs out of gas or returns no data or too little holds nothing, as the brain reads it.
- The build is the registry's `getMetadata(agentId, "build")` read as text: printable ASCII on one line, cut to 96 characters, and empty when unset. A declared build never starts with `house:`. That prefix is removed from what the registry holds, in any letter case and however often it is repeated, with the spaces after it.

An agent BrainChain runs itself is the one exception. Its build is `house: <model id>`, the model BrainChain runs it on, which the registry does not hold, whatever its metadata says. Only these agents keep the prefix, so an entry or a licence whose build starts with `house:` came from BrainChain's own list of the agents it runs, never from a controller's metadata. When the newest entry's build starts with `house:`, the tool takes the build from that entry and compares only the controller with the registry. The line says the build is BrainChain's own statement and shows what the registry holds. Every other build is held to the registry's metadata.

`current-epoch` names the entries whose `epoch` is that one, and the epoch's line in the list says so. It fails nothing: an entry belongs to the epoch it was written under, whatever the id's epoch is now. A registry RPC that does not answer is an `ERROR`.

`--epoch` is opt-in because it reads a second chain: a registry RPC that does not answer would turn a matching record into `UNVERIFIED`. On testnet it reads the registry the record names, since the tool carries none.

## Licences

An agent earns a licence by passing an exam sitting. The brain key signs it: the agent, the class, the epoch it was earned in, the sitting, and when it was issued and when it expires. The brain host lists an agent's licences at `/licences/<chain>/<agentId>` with the state it gives each: `valid`, `lapsed`, `suspended` or `expired`. The host reads the registry at most a minute before each reply, and says in `registry` whether it could: `read` or `unreadable`. The reply's `epoch` is the id's epoch by that reading, as its `id`, `controller` and `build`, or `null` when no single account controls the id. With `registry: read`, every state in the reply is held to that epoch. With `unreadable`, `epoch` is `null` and the states are those of the host's last own reading, at most ten minutes old.

```sh
npx brainchain-verify mainnet --licence 20424
```

The tool first holds the reply to the registry:

| Check | What passes |
| --- | --- |
| `licences-fetch` | The host served a list of licences. |
| `licences-epoch` | The controller the host gives is the registry's, and the id it names is the hash of the controller and build it gives. Its build is the registry's too, unless it starts with `house:`, which is BrainChain's own statement of the model it runs the agent on. A host that gives no epoch passes when no single account controls the id on the registry. The host's reading can be up to a minute older than the tool's, so where the two differ the line says to run the command again, and the reply is stale, as below. A reply that says `unreadable` is an `ERROR` here, since the host could not read the registry. A reply without `epoch`, as an earlier host sends, gets no line, and its licences are checked as before. |

Then, for each licence the host lists:

| Check | What passes |
| --- | --- |
| `licence` | It is a licence as BrainChain signs one, for the agent asked for, under the class the host lists it under. Its `epoch` is the hash of its agent, controller and build. |
| `licence-signature` | The signature, over the line `BrainChain licence` and then the licence in canonical JSON, recovers to the `brain` it names. |
| `licence-brain` | That key was the DecisionLog's brain at `issuedAt`. See [the brain key](#the-brain-key). |
| `licence-expiry` | Always `ok`. The line says when the licence expires or expired, by this machine's clock. |
| `licence-epoch` | `ok` once the registry is read. The line says whether the epoch the identity registry gives the id now is the one the licence names, worked out as [the current epoch](#the-current-epoch) describes. A registry RPC that does not answer is an `ERROR`, and `licence-state` does not run. |
| `licence-state` | The state the host gives is the one its own order gives. A licence is `expired` once past `expiresAt`, whatever else was true of it. Before that it is `suspended` when the host says so. Before that it is `lapsed` while the id is in another epoch. Otherwise it is `valid`. On a reply that read the registry, the id's epoch is the one the reply gives, and the state must follow it exactly. On any other reply it is the epoch the tool reads from the registry. |

Where the state is less plain:

- `suspended` is the host's word. A suspension follows two failed audits in the last three, which only the host counts. Before the expiry the tool reports it as given, and the line says what the state would be without it. Past the expiry only `expired` passes.
- A reply that could not read the registry, or one from an earlier host that does not say, gives the states of the host's own reading, made every ten minutes. `valid` or `lapsed` can then trail the registry by that long. That is a `FAIL`, and the line says why. Run the command again after ten minutes. A reply that read the registry does not trail.
- For an agent BrainChain runs itself, the licence's build is `house: <model id>`, which the registry does not hold. The registry says whether the controller is still the licence's, and the epoch the host gives says whether the model is, so `valid` and `lapsed` are both checked. A reply that gives no epoch, because the host could not read the registry or is an earlier one, leaves the model unknown. The tool then takes `valid` or `lapsed` as given while the controller is unchanged, and the line says that a change of model does not show.

A reply that read the registry just before the id changed hands, or before its controller declared a new build, gives the epoch the id has since left, and every state in it follows that epoch. `licences-epoch` fails on it, and the verdict is `STALE` rather than `MISMATCH` when no other check failed. A stale verdict exits 1, and in JSON each licence's verdict is `stale` too. Run the command again a minute later for the states of the new epoch. An epoch that is not the hash of the controller and build the host gives is a `MISMATCH`, however old the reading.

A `match` shows that the brain key signed each licence, and that the state the host lists is the one the licence's expiry and the registry give now. It does not show that the exam's judgments were right. The licence lists the decision behind each item in `decisions`, and each can be checked by its id once its item is retired and its record is public.

If the host lists no licence for the agent, the tool says so and exits 1, whatever the reply's epoch line says. On testnet the registry is read at the address the licence names.

## Papers

An agent's papers are an ERC-8004 registration file the brain host serves at `/papers/<chain>/<agentId>`, where an agent can point its id. The file's `brainchain` field holds `papers`, `signed` and `signature`. `signed` is the exact text the brain key signed: the line `BrainChain papers` and then the papers in canonical JSON. The papers state the agent, the epoch its id is in, the head of its record with this epoch's counts, its licences and its ceiling.

```sh
npx brainchain-verify mainnet --papers 20424
```

| Check | What passes |
| --- | --- |
| `papers-fetch` | The file holds a signed text and a signature under `brainchain`. |
| `papers-signed` | `signed` starts with the line `BrainChain papers`, and the JSON after it equals `brainchain.papers`, field for field. Every later check reads the signed text. |
| `papers-signature` | The signature over `signed` recovers to the `brain` the papers name. |
| `papers-agent` | The papers are for the agent asked for, on the identity registry, and the epoch id they state is the hash of the agent, controller and build they state. |
| `papers-brain` | That key was the active DecisionLog's brain when it signed the papers. See [the brain key](#the-brain-key). |
| `papers-fresh` | The papers were signed at most 15 minutes ago. The host signs them anew when asked, at most once a minute. |
| `papers-epoch` | The epoch the papers state is the one the identity registry gives the id now, worked out as [the current epoch](#the-current-epoch) describes. For a build BrainChain states itself, the controller alone is compared. A registry RPC that does not answer is an `ERROR`. |
| `papers-record` | The head the papers name is an entry of the agent's record. |

The papers name the record's length and head as they were when the papers were signed, and the record may have grown since. So `papers-record` reads the record from the entry the papers name. That entry must hash to the head the papers state, and lead entry by entry to a fresh head the active brain signed, as for `--record`. Every entry after it must be issued no more than a minute before the papers were signed. An older one is an entry the papers left out. Papers that name no record pass when the host serves none for the agent, or when every entry it serves was issued after the papers were signed.

The host keeps the papers it signed for up to a minute. Papers signed just before the id changed hands, or before its controller declared a new build, are still signed and fresh, and state an epoch the id has left. `papers-epoch` fails on them, and the verdict is `STALE` rather than `MISMATCH` when no other check failed. A stale verdict exits 1. Run the command again a minute later for the papers of the new epoch.

A `match` shows that the active DecisionLog's brain key signed these papers within the last 15 minutes, that the identity registry gives the id the epoch they state, and that the record head they name is the record's.

It does not check the licences the papers list, this epoch's counts or the ceiling. `--licence` and `--record` check those at their source. The file's fields outside `brainchain`, such as its name, image and services, are not signed by anyone.

## Exam items

An exam item in use is known only by its commitment: the `keccak256` of the item without its `id`, as canonical JSON, salt included. That hash is the item's id. An item is drawn three times at most. It is then retired and published in full at `/exams/items/<id>.json`, with its brief, hidden inputs, expected answers and reference answer.

```sh
npx brainchain-verify mainnet --item <itemId>
```

| Check | What passes |
| --- | --- |
| `item-fetch` | The host served a published item. An item still in use, or an id the host does not know, answers 404, which is an `ERROR`. |
| `item-commitment` | The item without its `id`, as canonical JSON, hashes to its `id`, and that is the id asked for. |

A `match` shows that the published item is the one its id committed to. It does not show which sittings drew the item, or that the id was listed before the item was used: the tool does not see when the host first listed it. `--item` hashes a file and reads no chain.

## Desk orders

BrainChain's desks trade tokenized stocks on Robinhood Chain through 0x. Every order goes out from DeskMandateV2, [`0x1CEb9aeeEab74eEf65A3E5DED14b59BecfBCfc16`](https://repo.sourcify.dev/4663/0x1CEb9aeeEab74eEf65A3E5DED14b59BecfBCfc16), the contract that holds the desks' money, on a quote 0x signed for that order. The brain publishes each quote as it arrived from 0x, and `desk-order` holds the order to it:

```sh
npx brainchain-verify desk-order 0x4829f77f52142de55f083691099fdfb5bf13ca97bbf15e1a7dc3881b74ea869f
```

The tool reads the transaction from Robinhood Chain's public RPC, and finds the order's quote record in the desk log at `https://brain.usebrainchain.com/desks`, which takes 10 to 25 seconds to answer. The log lists its latest 200 entries, so an order drops out of it within days. The record stays at its address, `https://brain.usebrainchain.com/records/<keccak256>.json`, which the order's entry gives as `quote.uri`. Pass that address, or a saved copy of the record, with `--quote`; do the same where the desk log is not served.

```text
$ npx brainchain-verify desk-order 0x4829f77f52142de55f083691099fdfb5bf13ca97bbf15e1a7dc3881b74ea869f
Desk order 0x4829f77f52142de55f083691099fdfb5bf13ca97bbf15e1a7dc3881b74ea869f on Robinhood Chain (DeskMandateV2 0x1CEb9aeeEab74eEf65A3E5DED14b59BecfBCfc16)
Desk 2 bought 0.007840391599978831 SPY for 5.672886 USDG in block 123730329, 2026-11-26 20:22:26 UTC

  ok    desk 2 bought SPY with 5672886 of USDG on DeskMandateV2 0x1CEb…fc16, sent by 0x97D5…b952 and mined in block 123730329 at 2026-11-26 20:22:26 UTC
  ok    the desk log names the quote record https://brain.usebrainchain.com/records/0xac8869a3b4bf435451c1e3db7b1b9fae6f34fa8cf6d379a6a716485c32a04582.json, which hashes to the name it is published under
  ok    the SHA-256 of the body 0x signed, 0x3bf9…12aa, is the digest the order sent and its Order event carries
  ok    signed with Ed25519 under the tag 0x-swap-api
  ok    key 0x-signing-key-prod-24092026
  ok    0x signed at 2026-11-26 20:22:22 UTC, 4 seconds before the order was mined, within 60
  ok    covers @status, content-type, content-digest, @method;req, @authority;req, @path;req, @query;req
  ok    the body's sha-256 matches Content-Digest
  ok    0x signed this answer to GET api.0x.org/swap/allowance-holder/quote with this exact query
  ok    the intent sells exactly 5672886 for at least 7761987683979043 on chain 4663
  ok    the query 0x answered asks for this trade and nothing else
  ok    an exact-in quote selling 0x5fc5…d168 for 0x117c…4C0C
  ok    the transaction calls AllowanceHolder 0x0000…2734
  ok    the approval it asks for is to AllowanceHolder
  ok    AllowanceHolder lets the Settler take 5672886 of 0x5fc5…d168 and no more
  ok    Settler 0xE885…EFb0 is the registry's previous Settler on chain 4663, as of the order's block
  ok    the transaction sends no ETH
  ok    the Settler pays what is bought to 0x1CEb…fc16
  ok    it buys 0x117c…4C0C
  ok    the Settler reverts unless at least 7761987683979043 is bought, at or above the 7761987683979043 asked for
  ok    the order handed AllowanceHolder the quote's transaction data byte for byte, 1636 bytes, and its Order event names the Settler that runs it, 0xE885…EFb0
  ok    the mandate sent exactly the 5672886 of USDG the quote sells
  ok    the mandate received 7840391599978831 of SPY, the amount its Order event books, at or above the quote's minimum of 7761987683979043 and the mandate's floor of 7795974976614430; 0x expected 7840391599978831

Verdict: match. 0x signed the quote this order was sent on, and the chain settled the order as quoted.
Not checked: whether the order was a good trade. The mandate holds each fill to its price feed on chain, and this check holds it to the quote 0x signed.
```

| Check | What passes |
| --- | --- |
| `order` | The transaction called `trade` on DeskMandateV2, went through and emitted the mandate's `Order` event. A transaction that is not a desk order, or one the mandate reverted, has nothing to check: the tool says so and exits 1. |
| `quote-record` | The record is a 0x answer as the brain keeps it: the AllowanceHolder quote request 0x signed, and the response as it arrived. Read from an address or file named `<hash>.json`, its keccak256 is that hash, and the one the desk log gives. |
| `quote-digest` | The SHA-256 of the response body is the digest the order passed to `trade` and its `Order` event carries, so this is the quote the order was sent on. |
| `calldata` | The bytes the order handed AllowanceHolder are the quote's `transaction.data`, byte for byte, and the `Order` event names the Settler they run. |
| `spent` | The mandate's transfers of the token sold come to exactly the amount the quote sells and the order books. |
| `received` | The transfers of the token bought into the mandate come to the amount its `Order` event books, at or above the quote's `minBuyAmount` and the floor the mandate set from its price feed. |

Between `quote-digest` and `calldata` come the checks of [0x quotes](#0x-quotes), from `zerox-signed` to `quote-min-out`, held to the order: the mandate as taker, the order's sender as `txOrigin`, the tokens and amount it trades, its `minOut` as the least it takes, and the `slippageBps` the query names. Three read differently here:

- `zerox-fresh` holds 0x's signature to the time the order was mined, not to your clock: 0x signed at most 60 seconds before.
- `quote-settler` takes the registry's Settlers as of the order's block, from the registry's own transfer events, since public RPCs keep no state that old. An RPC that cannot serve those events makes it an `ERROR`.
- On a route where 0x leaves the Settler's own terms empty and puts the minimum in the route's last step, `quote-recipient`, `quote-buy-token` and `quote-min-out` skip. The mandate takes such a quote because it measures what it receives, and `received` holds that to the order.

A `match` shows that 0x signed this quote for this order, and that the chain moved what the quote said out of the mandate and into it. It does not show that the order was a good trade: the mandate holds each fill to its price feed, and this check holds it to the quote 0x signed. The desk's reasoning is kept at the hash the order carries as `reasoning`, which this check does not read.

## What it cannot check

That Jev produced the answer. Jev's answers carry no signature from the service that runs Jev: BrainChain records them, and the contracts bound what a recorded answer can do. A decision that passes every check has the question, answer and probabilities the chain acted on. The [trust model](https://docs.usebrainchain.com/trust-model) explains what the chain relies on and what bounds it.

That a judge's probabilities are the ones it answered with. Each judge's receipt shows that Phala's gateway received the request in the record and served it from a verified TEE upstream. The record keeps the probabilities BrainChain read from the response, not the response the receipt hashes, so the tool cannot hold one to the other.

For an agent's record, licences and papers, the tool shows whose key signed and that nothing was left out or changed since. It cannot show that an outcome without a receipt is what the board did, that an exam's judgments were right, or that an agent runs the build it declares.

## Known history

On set v3-5, decision 972 and every decision after it until the switch to set v3-6 on 2026-11-21 fail `versions` by design. A recovery build made them from 2026-11-20 21:22 UTC, and its app, `0x97156bc84458d1c54427f217c4211ff0d66b43f6d6e42a243d26086946046aff`, is one the DecisionLog never attested for its key. Every other check on them that can run passes, but for the two receipt cases below. The `versions` line points here whenever a record names an app the log never attested for its key.

While BrainChain is switching sets, `receipt-payment` fails until the switch completes. The host's `/network.json` is then signed by a brain other than the active set's, as [receipts](#receipts) describes.

The host signs a receipt with the brain key that is live when it issues the receipt, and the tool holds a receipt to the key that recorded its decision. So a receipt issued after a brain switch, for a decision made before it, is signed by the newer key and fails `receipt`. Outside a switch of sets, the decision itself and its payment still verify. Entry 20425:9 is one: `0xeEA7b082103A9018FD5fC6ac820553a3FdE4B772` recorded decision 689 on set v3-5, and its receipt is signed by `0x95C7AfD81973F0c24b4AEAC75E4A6FFD8cC31C76`, the brain from 2026-11-18 13:46 UTC. A future release will accept a receipt signed by the brain that was live when it was issued.

Phala's gateway moved to a new app on 2026-11-05 (Pacific time), with a new receipt key, and every replica served from it by 2026-11-06 03:39 UTC ([gateway-prod-2026-11-05](https://github.com/Dstack-TEE/private-ai-gateway/releases/tag/gateway-prod-2026-11-05)). Phala does not publish the receipt key the gateway used before. So the judges' receipts on decisions recorded before then, all of set v3-3 and decisions 1 to 149 on set v3-4, skip their signatures. Their requests and upstreams are still checked.

Testnet's brain was replaced on 2026-11-20 and its records started fresh, so the host no longer serves the records of testnet decisions made before that day. The `fetch` line on such a decision points here.

## Exit status

| Code | Meaning |
| --- | --- |
| 0 | Every check that could run passed. Skips do not fail a decision. A `withheld` verdict also exits 0, so read the verdict if you need to tell it from a full match. |
| 1 | A check failed, a check could not run (an `ERROR` line, such as a record, brief or receipt the host did not serve), or the decision or entry could not be read: an unknown id, a task with no decisions, an entry the registry does not hold, an RPC error, a `--receipt` that cannot be read or is not a receipt. An agent with no record on the brain host, an item the host has not published, an agent with no licence, and stale papers or licences exit 1 too, and so does a `desk-order` transaction that is not a desk order, reverted, or has no quote record the tool can read. |
| 2 | Bad arguments, or an RPC that serves another chain. |

## JSON

`--json` prints one object. `decisions` holds one entry, or one per decision with `--task`. `verdict` is `match`, `withheld`, `mismatch` or `unverified` (a check could not run). With `withheld`, `withheldNotChecked` says what was left out, and the decision carries `withheld: true`. A decision about a task whose brief was read carries `title`, as the header shows it. A grade of outside work carries `outside: true`. A grade or ruling that holds a run of its brief's checks carries `run`, with the run's `language` and `outcome`, and `mode: "data"` when the checks ran alone on delivered data. A grade or ruling on a brief with a JSON schema carries `shape`, the tool's own check of the result: its `outcome` and, when it failed, its `problems`. A grade or ruling decided by a panel carries `panel`: its `rule`, `judges` with each judge that answered by `model` and `paid`, Jev first, and `degraded`. A degraded panel also carries `missing` and `bar`, and a panel whose record carries weights carries `weights`, Jev first. These are the record's own values, and the `judge` and `panel` checks say whether they recompute. A decision whose record matched the evidence hash on chain carries it as `evidence`. A decision whose receipt was checked carries `receipt`: where it was read as `from`, and the `job` and `outcome` it states. Each check keeps its `name` across releases, and its `status` is `ok`, `fail`, `skip` or `error`. When the tool cannot run, it prints `{ "error": "..." }` and exits 1, or 2 for bad arguments or an RPC that serves another chain. Trimmed to one check:

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
      "title": "Compare the rule of 72 with the exact doubling time",
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
  "notChecked": "That Jev produced the answer, or that a judge's probabilities are the ones in the response its gateway hashed. BrainChain records Jev's answers and the judges' probabilities, and the contracts bound what a recorded answer can do.",
  "trustModel": "https://docs.usebrainchain.com/trust-model"
}
```

With `--entry` or `--agent`, the object holds `registry`, `verdict`, `summary` and `entries` instead of `set` and `decisions`, and `agentId` with `--agent`. `verdict` is `match`, `no-receipt`, `withheld`, `mismatch` or `unverified`. It is `no-receipt` only when every check passed and every entry's hash was zero. `summary` counts `entries`, `withReceipt`, `verified`, `withheld`, `failed` and `unverified`. `withReceipt` counts an entry that points at a record entry only when that record entry names a receipt. `verified` counts only entries with a receipt whose verdict is `match`, so it never exceeds `withReceipt`. Each entry carries its name as `entry`, the fields of its `NewFeedback` event, the `task`, `board` and `set` its endpoint names, the `decision` its receipt names with its `id`, `set` and `kind`, its own `verdict` and its `checks`. An entry that points at a record entry carries `record`: that entry's `seq`, `kind`, `outcome` and `ref`, and its receipt's path as `receipt` when it names one.

With `--record`, `--licence`, `--papers` or `--item`, the object holds `network`, `chainId`, `verdict`, `failed`, `errors`, `skipped`, the brain host as `service`, the address read as `url`, the `checks`, and `notChecked` for that command. `verdict` is `match`, `withheld`, `mismatch` or `unverified`, or `stale` for `--papers` and `--licence`.

- `--record` adds `agentId`, the `agent` the record names once it is the one asked for, the number of `entries`, and the `head` with its `seq`, `hash`, `brain`, `at`, `signedAt` and `ageSeconds`. `epochs` lists each epoch with its `id`, `controller`, `build`, first entry as `from`, that entry's time as `since`, its `entries` and its `counts` under keys such as `task:accepted`. `receipts` holds one object for each entry with a receipt: its `seq`, `path`, the `decision` it names, its own `verdict` and every check on it. With `--epoch`, `current` holds the epoch's `id`, `controller` and `build`, `bound` for an id bound to an NFT, and `entries` as runs of `from` and `to`. `buildFrom` is `registry`, or `record` when the build is read from the newest entry of an agent BrainChain runs itself, and `registryBuild` is then what the registry holds. `current` is `null` when no single account controls the id.
- `--licence` adds `agentId`, `registry` and the `epoch` the host gives for the id where its reply carries them, and `licences`. Each licence carries its `class`, the state the host gives as `claimed`, the `state` the checks give, its `sitting`, `accepted`, `of`, `issuedAt` and `expiresAt`, the host's `audits` counts, its own `verdict` and its `checks`. The top-level `checks` hold the fetch and `licences-epoch`. A stale reply carries `stale: true`, and its `verdict` and each licence's are `stale`, or `unverified` where a check could not run.
- `--papers` adds `agentId` and what the papers state: `at`, `signedAt`, `brain`, `epoch`, `record` and each licence's `class` and `state`. These are the papers' own values, and the checks say whether the brain key signed them. `current` is the epoch the identity registry gives the id now, as its `id`, `controller` and `build`, with `bound` for an id bound to an NFT, or `null` when no single account controls it. Stale papers carry `stale: true`, and their `verdict` is `stale`.
- `--item` adds the item's `id`, its `title` and `template`, and `retired` with the host's `uses`, `passed` and `retiredAt`.

With `desk-order`, the object holds `chain`, `chainId`, `verdict`, `failed`, `errors`, `skipped`, the transaction as `tx`, the `mandate`, the `order`, the `record` read, the `checks` and `notChecked`. `order` is the order as the chain records it: `desk`, `token`, `buy`, `amountIn`, `amountOut`, `minOut`, `floor`, `feedPrice`, `reasoning`, the quote's digest as `quote`, `settler`, `sender`, `block` and `minedAt` in seconds since the epoch, with the token's `symbol` and `decimals` where it gives them. Amounts are strings in the token's smallest units. `record` holds the `uri` read and `listed`, true when the desk log named it.

## 0x quotes

`brainchain-verify/zerox` checks an answer from 0x's Swap API before anything in it is signed. It is a library: `brainchain-worker buy-stake` uses it, and [`desk-order`](#desk-orders) runs its checks on a desk's order. It needs `node:crypto` and viem 2, which it takes as a peer dependency so that your own viem client fits its types. Its one chain read is 0x's Settler registry.

The examples buy each answer from 0x's keyless gateway. The gateway speaks x402 version 2 and charges 0.01 USDC on Base for each request, paid from your key with a signed USDC authorization, so the key needs a little USDC on Base and no ETH there. A request is charged even when it is refused, and even when it carries no `Accept-Signature`; an answer without 0x's signature cannot be checked, so always send the header. The same request to `https://api.0x.org/swap/allowance-holder/quote` with your own 0x API key is free and checks the same way; it needs the headers `0x-api-key: <your key>` and `0x-version: v2` beside `Accept-Signature`.

The examples pay with the x402 client packages, tested with these versions:

```sh
npm install brainchain-verify viem @x402/fetch@2.30.0 @x402/evm@2.30.0
```

They read the paying key from a file that only its owner can read, never from the environment or the command line, where other processes and the shell's history can see it.

```ts
import { readFileSync, statSync } from "node:fs";

import { wrapFetchWithPayment, x402Client } from "@x402/fetch";
import { ExactEvmScheme } from "@x402/evm/exact/client";
import { ACCEPT_SIGNATURE, NATIVE, readSettlers, verifyQuote, type QuoteIntent } from "brainchain-verify/zerox";
import { createPublicClient, http, parseEther, parseUnits, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { robinhood } from "viem/chains";

const keyFile = process.env.PAYER_KEY_FILE ?? "payer.key";
if (process.platform !== "win32" && (statSync(keyFile).mode & 0o077) !== 0) throw new Error(`Other accounts can read ${keyFile}. Run chmod 600 on it first.`);
const account = privateKeyToAccount(`0x${readFileSync(keyFile, "utf8").trim().replace(/^0x/, "")}` as Hex);
const client = createPublicClient({ chain: robinhood, transport: http() });
const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const pay = wrapFetchWithPayment(
  fetch,
  x402Client.fromConfig({
    schemes: [{ network: "eip155:8453", client: new ExactEvmScheme(account) }],
    // Pay only the gateway's own price: 0.01 USDC on Base.
    policies: [(_version, offers) => offers.filter((o) => o.network === "eip155:8453" && o.asset.toLowerCase() === BASE_USDC.toLowerCase() && BigInt(o.amount) <= 10_000n)],
  }),
);

const BRAIN = "0x42b96dbc55e79E930d866c1eE486A342366546BC";
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";

async function checkedQuote(query: Record<string, string>, intent: QuoteIntent) {
  const url = `https://agent.api.0x.org/v1/x402/swap-allowance-holder-quote/?${new URLSearchParams(query)}`;
  const response = await pay(url, { headers: { "Accept-Signature": ACCEPT_SIGNATURE } });
  // The signature covers the bytes 0x sent, so keep them before anything reads the body.
  const received = { status: response.status, headers: response.headers, body: new Uint8Array(await response.arrayBuffer()) };
  const report = await verifyQuote(received, url, intent, { settlers: () => readSettlers(client, robinhood.id) });
  if (!report.ok) throw new Error(report.checks.find((c) => c.status === "fail")?.message ?? "the quote was refused");
  return report;
}

// Exact out, selling ETH: exactly 312,500 BRAIN, for at most the ETH you set from your own price.
const stake = 312_500n * 10n ** 18n;
const exactOut = await checkedQuote(
  { chainId: "4663", sellToken: NATIVE, buyToken: BRAIN, buyAmount: stake.toString(), taker: account.address },
  { chainId: 4663, taker: account.address, sellToken: NATIVE, buyToken: BRAIN, buyAmount: stake, maxSellAmount: parseEther("0.05") },
);

// Exact in, selling an ERC-20: exactly 10 USDG, for at least the BRAIN you set, at the slippage the query names.
const exactIn = await checkedQuote(
  { chainId: "4663", sellToken: USDG, buyToken: BRAIN, sellAmount: parseUnits("10", 6).toString(), taker: account.address, slippageBps: "100" },
  { chainId: 4663, taker: account.address, sellToken: USDG, buyToken: BRAIN, sellAmount: parseUnits("10", 6), minBuyAmount: 45_000n * 10n ** 18n, slippageBps: 100 },
);
console.log(exactOut.decoded?.amount, exactIn.decoded?.minAmountOut);
```

`url` is the URL the request went to: `https://api.0x.org/swap/allowance-holder/quote?...`, or the same request through the gateway, `https://agent.api.0x.org/v1/x402/swap-allowance-holder-quote/?...`. The gateway forwards it to the Swap API, and 0x signs the request it received there, so the check rebuilds that one: host `api.0x.org`, path `/swap/allowance-holder/quote`, and the query exactly as sent. Pass the URL you sent, not one rebuilt from the same parameters: a query in another order fails, and the check says so.

`body` is the bytes 0x sent, as a `Uint8Array`. Read them once with `new Uint8Array(await response.arrayBuffer())`, or take `response.clone()` first if something else reads the body. Anything else, a parsed or decoded body or a bare `ArrayBuffer`, throws a `TypeError` that says to pass the raw bytes.

`maxSellAmount` (exact out, with `buyAmount`) and `minBuyAmount` (exact in, with `sellAmount`) are required, both from the caller's own price: on exact out the Settler pays the recipient exactly the minimum, so the amount `exec` lets it take is the only bound on what is spent, and on exact in the minimum is the only bound on what comes back.

That price is yours to choose: a price feed you trust, an oracle on the chain, or 0x's own price for the same trade (`/swap/allowance-holder/price`, whose `estimatedNetSellAmount` or `buyAmount` you can then hold within a margin).

Amounts are bigints in the token's smallest units. A plain number fails `quote-intent`, which says so.

`slippageBps` says what the query asked 0x for, so it must be in the query too, with the same value: give it in both or in neither.

`txOrigin` is the account that sends the transaction when the taker is a contract, which 0x asks for then. A BrainChain desk's quote names its mandate contract as the taker and the desk key that sends the order as `txOrigin`. Like `slippageBps`, give it in both the query and the intent, or in neither.

`maxGasCost` is optional and holds the quote's `gas` times its `gasPrice` to a limit. Those two are 0x's estimate, and `report.quote.transaction` carries both: send the transaction with fee fields of your own.

`settlers` is the chain's Settlers, or a function that reads them. `readSettlers(client, chainId)` reads them from 0x's registry and throws when the client is on another chain. When the read throws, as an RPC that does not answer does, the report fails `quote-settler` with its error rather than throwing, so `verifyQuote` throws only for arguments it cannot use: an unknown URL, a body that is not bytes, or missing options.

The signature checks run in order and stop at the first that fails. The quote's checks run only once the signature holds. A report from `verifyQuote` names every check below that ran, passed or failed; `quote-gas` runs only with `maxGasCost`.

| Check | What passes |
| --- | --- |
| `zerox-signed` | The response carries `Signature-Input` and `Signature` (RFC 9421), Ed25519, tagged `0x-swap-api`. |
| `zerox-key` | The signature names a key this package pins (`ZEROX_KEYS`). |
| `zerox-fresh` | 0x signed it at most 60 seconds from the caller's clock, either way. A clock or age limit that is not a finite number fails. |
| `zerox-covers` | It covers the status, `content-digest`, and the request's method, authority, path and query. |
| `zerox-digest` | The body's SHA-256 is the one in `Content-Digest`. |
| `zerox-signature` | The signature verifies over the rebuilt signature base. When it would verify with the same parameters in another order, the line says so. |
| `quote-intent` | The intent is one the checks can hold a quote to: exactly one of `sellAmount` and `buyAmount`, the caller's limit for it, bigint amounts, addresses, and a known AllowanceHolder. |
| `quote-request` | The query 0x answered asks for this trade and nothing else: `chainId`, `sellToken`, `buyToken`, `taker` and one of `sellAmount` and `buyAmount`, each once with the intent's value, plus `recipient`, `txOrigin` and `slippageBps` only when the intent names them. Any other parameter, such as a fee, a surplus recipient or `gasPrice`, fails, and so does a percent-encoded part, since 0x decodes it. |
| `quote-response` | HTTP 200, a route, a transaction, and the mode, tokens and amounts asked for. A refusal names 0x's error. |
| `quote-target` | The transaction calls AllowanceHolder (`0x0000000000001fF3684f28c67538d4D072C22734` on Ethereum, Base and Robinhood Chain, pinned here; `allowanceHolder` in the intent names it on other chains). |
| `quote-spender` | `allowanceTarget` is null or AllowanceHolder, and so is the spender in `issues.allowance` when 0x asks for an approval. Never approve the Settler. |
| `quote-exec` | AllowanceHolder's `exec`, in the standard ABI encoding, lets the Settler take the token sold, and no more than the amount sold, or on an exact-out quote its `maxSellAmount` and at most the caller's. |
| `quote-settler` | The Settler is the one 0x's registry (`0x00000000000004533Fe15556B1E086BB1A72cEae`) returns for taker-sent swaps, `ownerOf(2)`, or the one before it, `prev(2)`, which 0x's API can still use for a while after a new Settler is deployed. A registry that reverts means 0x paused Settler on that chain, and one that could not be read fails with the reason. |
| `quote-value` | The transaction sends the amount sold when it sells the native token, and nothing otherwise. |
| `quote-recipient` | Settler's slippage check pays what is bought to the taker, or to the recipient the caller named. |
| `quote-buy-token` | That check counts the token the caller buys. |
| `quote-min-out` | It reverts unless the recipient gets at least the caller's floor: `minBuyAmount`, or `buyAmount` on an exact-out quote. |
| `quote-gas` | Only with `maxGasCost`: the quote's `gas` times its `gasPrice` is at most that. |

`checkQuote` runs `quote-intent` and the quote's checks on a body already trusted, without `quote-request`, and `verifyResponse` runs the signature's alone, for any Swap API answer.

### When 0x changes its key

0x rotates its signing key, and lists a new key on [its docs](https://docs.0x.org/docs/developer-resources/response-signatures.md) beside the old one before it signs with it.

- `ACCEPT_SIGNATURE` names no key, and 0x signs with whichever key is active.
- The key is picked by the signature's `keyid`, never by position, from `ZEROX_KEYS`, the keys pinned in this package. Nothing is read from the network.
- A signature by any other key fails `zerox-key`, and the line says a newer version of this package is needed. Each new key ships in a patch release.

## Building

```sh
npm install
npm run build
npm test
```

`build` reads `deployments/*.json` at the repository root into `src/deployments.ts` and compiles to `dist/`. `npm run abi` regenerates `src/abi.ts` from a `forge build` at the root.

## License

MIT
