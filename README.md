<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/vect-lockup-dark.png">
    <img src="assets/vect-lockup-light.png" alt="Vect.trade | VECT LABS" width="380">
  </picture>
</p>

<p align="center">Smart contracts of Vect.trade, published by VECT LABS.</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT">
  <img src="https://img.shields.io/badge/solidity-0.8.38-363636" alt="Solidity 0.8.38">
</p>

## Contracts

| Contract | Chain | Address | Status |
|---|---|---|---|
| [`VectExecutor`](exec01/) | Robinhood Chain (4663) | Not deployed | Release candidate. Internally reviewed, not audited by an external firm. |

`VectExecutor` is a stateless swap executor. When a user submits a signed swap, it routes the user's tokens across Uniswap v2, v3 and v4 pools and five concentrated-liquidity fork factories in one transaction. It has no owner, no admin, no upgrade and no pause, and it holds no funds between transactions. Details: [`exec01/README.md`](exec01/README.md).

Deployed addresses and their verified source (Sourcify) will be listed here at deployment. The source of every contract VECT LABS deploys, or intends to deploy, is published in this repository with its tests.

## Security

- **Review:** internal review only, no external audit. Scope, methods and limits are in [`SECURITY-REVIEW.md`](SECURITY-REVIEW.md).
- **Reporting a vulnerability:** write privately to **security@vect.trade**; see [`SECURITY.md`](SECURITY.md). No bug bounty is offered at this time.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/) and an archive-capable Robinhood Chain RPC for the fork suites.

```
cd exec01
export ROBINHOOD_RPC=<archive RPC URL>
forge build
forge test
```

## License and trademark

The code is provided under the [MIT licence](LICENSE), "as is", without warranty of any kind.

VECT is a trademark of VECT LABS. This licence grants no right to use the VECT name or logo; the logos in `assets/` are not covered by the MIT licence.

Using these contracts directly, outside vect.trade, is at your own risk and is not a service of VECT LABS. For vect.trade users, the vect.trade Terms of Use apply.

Nothing in this repository is an offer or a solicitation to buy or sell any crypto-asset or financial instrument, or investment advice.
