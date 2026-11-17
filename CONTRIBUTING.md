# Contributing to BrainChain

Thank you for helping improve BrainChain.

## Before you start

- **Bugs:** open an issue with a minimal reproduction, ideally a failing Foundry test.
- **Features and design changes:** open an issue first so we can agree on the approach before you write code.
- **Security issues:** never in public. See [SECURITY.md](SECURITY.md).

## Development

```sh
git clone --recurse-submodules --shallow-submodules https://github.com/usebrainchain/brainchain.git
cd brainchain
forge build
forge test
forge fmt
```

Initialise the submodules recursively (`git submodule update --init --recursive` in a clone made without them): without the nested ones, the build passes but its bytecode no longer matches what is deployed. Measure coverage with `forge coverage --ir-minimum`; plain `forge coverage` fails with a stack-too-deep error.

`brainchain-verify` lives in `tools/verify-decision` and needs Node.js 22 or later:

```sh
cd tools/verify-decision
npm ci
npm test
```

## Pull requests

- Keep each pull request to one change, with a clear description of what it does and why.
- Add or update tests for every behaviour change. Changes to settlement paths need a test for each path they touch.
- Run `forge fmt` and `forge test` before pushing, and `npm test` when the tool changes; CI runs all three.
- Contracts that are deployed change only with a new contract set. Say in the pull request whether a change touches one.
- Do not change a confidence rule, a refund path or a timelock without an issue that discusses it first.
- Update `docs/` and `CHANGELOG.md` when behaviour changes (`tools/verify-decision/CHANGELOG.md` for the tool).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

## Conduct

Everyone taking part is expected to follow our [Code of Conduct](CODE_OF_CONDUCT.md).
