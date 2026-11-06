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

In scope: the contracts in `src/` that are deployed on mainnet, as listed in `deployments/mainnet.json`, and their documented behaviour in `docs/`; the brain service and its API; the x402 desk and the payments it takes and returns; and any bug in BrainChain's tools that could take or lock funds or expose a key.

Out of scope:

- contracts and code that are not deployed on mainnet;
- issues that require a compromised guardian key, or a compromised brain key (the key that records Jev's decisions) beyond what the contracts bound;
- issues where the only funds at risk are the caller's own;
- scanner findings without a demonstrated impact;
- third-party services.

## Bounty

What a report earns depends on what its proof shows.

| What the report proves | Award |
| --- | --- |
| A fork test or a testnet script that takes or locks someone else's funds | Up to $1,000 |
| A confirmed vulnerability in scope, with no working exploit | Up to $250 |
| Hardening: a missing check or an edge case with no path to funds | Credit in the advisory, no payment |

Funds include anything a BrainChain tool sends, signs or approves without its user asking, and a key it exposes. Bugs in the tools, docs and site that cannot take or lock funds go through the [bug hunt](https://docs.usebrainchain.com/bug-hunt).

We pay at most $1,500 in awards in a calendar month. Awards confirmed beyond that are paid in the following months, in the order we confirmed them.

The first private report of each root cause earns the award. A vulnerability we already know about, or one already made public, does not earn one. We decide whether a report qualifies and what it pays. These terms apply to reports received after 6 November 2026.

We pay in USDC on Base or USDG on Robinhood Chain, to a wallet you name, once the fix is live or 90 days after we confirm the report, whichever comes first. The [bug hunt's rules](https://docs.usebrainchain.com/bug-hunt#rules) on eligibility, sanctions, tax, use of reports and good-faith testing apply here too.

## Status

BrainChain mainnet holds user funds in escrow. The contracts are open source and have not had an external audit.
