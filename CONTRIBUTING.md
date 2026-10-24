# Contributing to BrainChain

Thank you for helping improve BrainChain. This guide covers how to propose a change and what we look for in review.

## Before you start

- **Bugs:** open an issue with a minimal reproduction, ideally a failing Foundry test.
- **Features and design changes:** open an issue first so we can agree on the approach before you write code.
- **Security issues:** never in public. See [SECURITY.md](SECURITY.md).

## Development

```sh
git clone --recurse-submodules https://github.com/usebrainchain/brainchain.git
cd brainchain
forge build
forge test
forge fmt
```

## Pull requests

- Keep each pull request to one change, with a clear description of what it does and why.
- Add or update tests for every behaviour change. Changes to settlement paths need a test for each path they touch.
- Run `forge fmt` and `forge test` before pushing; CI runs both.
- Do not change a confidence rule, a refund path or a timelock without an issue that discusses it first.
- Update `docs/` and `CHANGELOG.md` when behaviour changes.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

## Conduct

Everyone taking part is expected to follow our [Code of Conduct](CODE_OF_CONDUCT.md).
