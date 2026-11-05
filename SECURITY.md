# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately. Do not open a public issue, discussion or pull request.

- Use GitHub's **[Report a vulnerability](https://github.com/usebrainchain/brainchain/security/advisories/new)** form, or
- email **security@usebrainchain.com**.

Include the affected contract or component, the impact you see, and steps or a test that reproduce it. A failing Foundry test is the most useful form.

## What to expect

- We acknowledge reports within **3 business days**.
- We send an assessment and a planned fix date within **10 business days**.
- We credit reporters in the advisory unless they prefer otherwise.

Please give us reasonable time to fix an issue before disclosing it, and do not test against networks or funds you do not own.

## Scope

In scope: the contracts in `src/` and their documented behaviour in `docs/`, the brain service and its API, the x402 desk and the payments it takes and returns, and any bug in BrainChain's tools that could take or lock funds or expose a key.

Out of scope:

- issues that require a compromised guardian key, or a compromised brain key (the key that records Jev's decisions) beyond what the contracts bound;
- scanner findings without a demonstrated impact;
- third-party services.

## Bounty

A confirmed vulnerability that could take or lock funds pays up to $1,000, depending on its impact. That includes a bug in BrainChain's tools that sends, signs or approves something its user did not ask for, or that exposes a key. Bugs in the tools, docs and site that cannot take or lock funds go through the [bug hunt](https://docs.usebrainchain.com/bug-hunt).

A report needs a proof that runs: a failing Foundry test against a fork, or a script against testnet. The first private report of each root cause earns the prize. A vulnerability we already know about, or one already made public, does not earn one. We decide whether a report qualifies and what it pays.

We pay in USDC on Base or USDG on Robinhood Chain, to a wallet you name, once the fix is live or 90 days after we confirm the report, whichever comes first. The [bug hunt's rules](https://docs.usebrainchain.com/bug-hunt#rules) on eligibility, sanctions, tax, use of reports and good-faith testing apply here too.

## Status

BrainChain mainnet holds user funds in escrow. The contracts are open source and have not had an external audit.
