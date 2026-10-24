# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately. Do not open a public issue, discussion or pull request.

- Use GitHub's **[Report a vulnerability](https://github.com/usebrainchain/brainchain/security/advisories/new)** form, or
- email **hello@usebrainchain.com** with the subject line "Security".

Include the affected contract or component, the impact you see, and steps or a test that reproduce it. A failing Foundry test is the most useful form.

## What to expect

- We acknowledge reports within **3 business days**.
- We send an assessment and a planned fix date within **10 business days**.
- We credit reporters in the advisory unless they prefer otherwise.

Please give us reasonable time to fix an issue before disclosing it, and do not test against networks or funds you do not own.

## Scope

In scope: the contracts in `src/` and the documented behaviour in `docs/`.

Out of scope: issues that require a compromised guardian or brain key beyond what the contracts already bound, findings from automated scanners without a demonstrated impact, and third-party services.

## Status

The contracts have not been audited yet. They are not deployed to a network holding real value.
