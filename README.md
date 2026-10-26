<p align="center">
  <img src="docs/banner.png" alt="BrainChain: a chain with a brain" width="100%" />
</p>

<h1 align="center">BrainChain</h1>

<p align="center">
  A blockchain run by an AI agent, settled on Robinhood Chain.
</p>

<p align="center">
  <a href="https://github.com/usebrainchain/brainchain/actions/workflows/ci.yml"><img src="https://github.com/usebrainchain/brainchain/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-f386a1" alt="MIT license" /></a>
  <img src="https://img.shields.io/badge/solidity-0.8.24-1d1d1d" alt="Solidity 0.8.24" />
  <a href="https://usebrainchain.com"><img src="https://img.shields.io/badge/site-usebrainchain.com-f8f7f4" alt="Website" /></a>
  <a href="https://usebrainchain.com/docs"><img src="https://img.shields.io/badge/docs-usebrainchain.com%2Fdocs-f386a1" alt="Documentation" /></a>
</p>

---

BrainChain is a network where one AI agent makes every decision the chain acts on. **Jev**, a decision model from TypeSafe, hires one of five frontier models for each task, grades the delivered work, rules on disputes and decides on changes to the chain's own settings. The bounty sits in escrow throughout, and a model is paid only when Jev accepts its work.

Every decision carries a confidence score. **When Jev is unsure, the chain takes the safe default**: no hire, no payment for ungraded or rejected work, and a grade that stands when a dispute ruling is unsure. That rule is enforced by the contracts in this repository, not by the agent. The brain service that records Jev's answers is trusted to record them faithfully; the contracts bound what a recorded answer can do (see [docs/architecture.md](docs/architecture.md#trust-model)).

> **Status:** BrainChain testnet is live on Robinhood Chain testnet (chain ID `274630`, RPC `https://rpc.testnet.usebrainchain.com`), with bounties in test USDG. Addresses are in [`deployments/testnet.json`](deployments/testnet.json). The contracts have not been audited.

## Contents

Full documentation: **[usebrainchain.com/docs](https://usebrainchain.com/docs)**.


- [How it works](#how-it-works)
- [The confidence rule](#the-confidence-rule)
- [Architecture](#architecture)
- [Contracts](#contracts)
- [Getting started](#getting-started)
- [Verifying a decision](#verifying-a-decision)
- [Security](#security)
- [Contributing](#contributing)
- [License](#license)

## How it works

```mermaid
flowchart LR
    P([Poster]) -->|bounty in USDG| B[TaskBoard<br/>escrow]
    J{{Jev}} -->|hire| B
    B -->|task| M[Hired model<br/>Claude · GPT · Gemini · Grok · DeepSeek]
    M -->|result hash| B
    J -->|grade| B
    B -->|accepted| M
    B -->|not accepted| P
```

1. **A task is posted** with a bounty in USDG and a deadline. The `TaskBoard` holds the bounty.
2. **Jev hires** one of the registered models, weighing fit, price and track record. The decision is recorded in the `DecisionLog` and applied to the task.
3. **The model delivers.** It commits a hash of its result on chain before the deadline.
4. **Jev grades** the result against the quality levels in the brief. After a short dispute window, accepted work is paid to the model and anything else is refunded.
5. **Disputes.** The poster or the model can dispute a grade once. Jev rules to pay or refund.

A full task, end to end:

```mermaid
sequenceDiagram
    autonumber
    actor Poster
    participant Board as TaskBoard
    participant Log as DecisionLog
    participant Brain as Brain (calls Jev)
    participant Model as Hired model

    Poster->>Board: post(bounty, deadline, brief)
    Brain->>Log: record(Hire, task, model, confidence)
    Brain->>Board: hire(task, decision)
    Board-->>Model: task assigned
    Model->>Board: submit(task, resultHash, resultURI)
    Brain->>Log: record(Grade, task, accept, confidence)
    Brain->>Board: grade(task, decision)
    Note over Board: dispute window
    Board->>Model: bounty paid (or refunded to the poster)
```

## The confidence rule

Each contract that acts on a decision applies its own threshold. A decision below it never moves funds toward a model, and every path that stalls ends in a refund.

| Decision | Jev answers with | Below the threshold |
| --- | --- | --- |
| Hire | A choice among the models | No one is hired; the task stays open and refunds at its deadline |
| Grade | A score against the brief's quality levels | The poster is refunded |
| Ruling | A choice of pay or refund | The grade stands |
| Chain change | A choice of adopt or keep | The current setting stays |

If no decision arrives at all, anyone can call `finalize` once the step's window has closed: an ungraded or unhired task returns the bounty to the poster, and a grade, disputed or not, stands. A decision counts only for the task, board and chain it names, only if it is the latest of its kind about that task, and only if it was recorded after the event it judges.

## Architecture

```mermaid
flowchart TB
    subgraph RH[Robinhood Chain]
        S[(Settlement and bridge)]
    end
    subgraph BC[BrainChain]
        DL[DecisionLog]
        TB[TaskBoard]
        MR[ModelRegistry]
        DE[DecisionExecutor<br/>timelock · guardian veto]
    end
    BR[Brain service] -->|records decisions| DL
    BR -->|applies decisions| TB
    BR -->|queues adopted changes| DE
    BR <-->|typed questions| JEV[(Jev API)]
    W[Worker services] <-->|official APIs| LLM[(Model providers)]
    W -->|submit results| TB
    TB --> MR
    DE -->|owns settings| TB
    DE -->|owns settings| MR
    AD[Admin timelock<br/>owners' Safe] -->|replaces brain and guardian| DL
    AD -->|replaces guardian| DE
    BC -->|batches and state| RH
```

BrainChain is an Arbitrum Orbit chain with Robinhood Chain as its parent. Gas is paid in ETH and bounties in USDG. See [docs/architecture.md](docs/architecture.md) for roles, trust boundaries and what each party can and cannot do.

## Contracts

| Contract | Responsibility |
| --- | --- |
| [`DecisionLog`](src/DecisionLog.sol) | Append-only record of every decision the chain acts on: kind, subject, input hash, answer and confidence, with the latest decision per subject and kind. Only the brain can record; only the admin timelock can replace the brain. |
| [`TaskBoard`](src/TaskBoard.sol) | Escrows bounties and settles tasks only on recorded decisions above its own thresholds, under the terms fixed when each task was posted. Pays the account that delivered the work. |
| [`ModelRegistry`](src/ModelRegistry.sol) | Maps each worker model to the account that submits its work. |
| [`DecisionExecutor`](src/DecisionExecutor.sol) | Owns the chain's settings and the house treasury. Runs a change only after Jev adopts it above the change threshold and a timelock passes, and only on the executor, board or registry. The guardian can veto during the timelock, for good. House tasks are capped per task and per day. |

### $BRAIN fee rewards (Robinhood Chain)

| Contract | Responsibility |
| --- | --- |
| [`FeeSplitter`](src/rewards/FeeSplitter.sol) | The creator fee recipient for $BRAIN on Pons. Splits ETH fees 50/50 between the reward distributor and the treasury and sends any ERC-20 fees to the treasury. Binds only a curve that pays it. The owner can move the fee stream or change the buyback setting three days after announcing it. |
| [`RewardDistributor`](src/rewards/RewardDistributor.sol) | Weekly Merkle rounds of ETH for accepted work. A round never pays more than its total; claims open 24 hours after publishing, during which the owner can revoke the round, and close after 12 weeks. |

## Testnet

| Contract | Address |
| --- | --- |
| TaskBoard | `0x686633c82F81b99B1Ae9bAAE458Aa8280F158367` |
| DecisionLog | `0x814936Ddb508385fe46285618B271B35FbcD1d96` |
| ModelRegistry | `0xf1599642DEb9F41E4D9Bc4D4457c0D333C8C5C0F` |
| DecisionExecutor | `0xe5901d1A62938E2d03bf2d89FF0893A5e0a55df5` |
| WorkerStaking | `0x942840737560AC602f78b63C506c8996aCB4C79E` |
| FeeRouter | `0xAC1964Af981567DbB41d6AE941f5bB8a6FD05839` |
| ProposalBonds | `0x40190374ef40Ac647546288FF68cEb9033Ee3c4e` |
| TestUSDG | `0x609e58dB19603b74208c86CCc64275c026C2a83A` |
| TestBRAIN | `0xaF815F0B5E9c3706928eB4A8f8FdF8B4690E0f43` |
| TestSwap | `0xDA308F4CE7c80e52665f6D74590A2c0d61C437c3` |

Add the network, bridge ETH and claim test tokens at [usebrainchain.com/network](https://usebrainchain.com/network). [`script/DeployTestnet.s.sol`](script/DeployTestnet.s.sol) reproduces the deployment.

## The $BRAIN flywheel

$BRAIN is BrainChain's token. It is not launched yet; on testnet, tBRAIN stands in for it.

| Contract | Responsibility |
| --- | --- |
| [`FeeRouter`](src/flywheel/FeeRouter.sol) | Takes the protocol fee on paid bounties (3% on testnet) and buys $BRAIN through a swap adapter. Half is burned, half goes to the house treasury. The $BRAIN address is set once, at launch. |
| [`WorkerStaking`](src/flywheel/WorkerStaking.sol) | Any agent stakes $BRAIN to be hireable alongside the house models, once governance allow-lists it on the board. A worker that disputes a grade and loses is slashed. Stake cannot be withdrawn while the worker has a task in flight. |
| [`ProposalBonds`](src/flywheel/ProposalBonds.sol) | Anyone bonds $BRAIN to propose a chain change. The bond is returned if Jev's latest decision adopts it and burned if not. |

The fee router never buys below a floor rate set by governance, so the keeper cannot sell fees at an arbitrary price.

Refunds never pay the fee. See [usebrainchain.com/docs/brain-token](https://usebrainchain.com/docs/brain-token).

## Getting started

Requirements: [Foundry](https://getfoundry.sh).

```sh
git clone --recurse-submodules https://github.com/usebrainchain/brainchain.git
cd brainchain
forge build
forge test
```

The suite covers every settlement path, access control and the confidence rule, plus fuzzed invariants:

- the board always holds exactly the bounties of unsettled tasks, and money is conserved;
- no model is paid without an accepted grade or a ruling above threshold, and the account that delivered is the one paid;
- fees follow each task's own terms, and nothing settles twice;
- a staked worker's stake is held for every task in flight, and house spending stays under its daily cap;
- a reward round never pays more than its total, and the distributor always holds what open rounds owe.

The flywheel suite covers fees, buybacks, staking, slashing and proposal bonds; a coverage suite asserts every event, access rule and time-window boundary; and [`test/Regressions.t.sol`](test/Regressions.t.sol) reproduces each finding of the October 2026 review against the fixed contracts.

Run the invariants longer with `FOUNDRY_INVARIANT_RUNS=1000 forge test --match-contract Invariants`. Fork suites run against real chain state and are skipped without one: [`test/fork/PonsLifecycle.t.sol`](test/fork/PonsLifecycle.t.sol) launches a token on Pons with the `FeeSplitter` as its fee recipient and follows the fees through graduation, and [`test/fork/AdminHandover.t.sol`](test/fork/AdminHandover.t.sol) replays the admin handover.

## Verifying a decision

Every decision is published as a JSON record whose hash is stored on chain with it, so anyone can check that the published record is the one the chain acted on. See [docs/decisions.md](docs/decisions.md) for the record format and a step-by-step check.

## Security

Please do not open public issues for vulnerabilities. Report them privately as described in [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request, and follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE).

Model and company names identify which model made a decision or did a job. BrainChain is not affiliated with or endorsed by TypeSafe, Anthropic, OpenAI, Google, xAI, DeepSeek or Robinhood.
