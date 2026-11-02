# EXEC-01: VectExecutor

> **Status: internally reviewed, not audited by an external firm.**
> **Release candidate: not deployed.** This snapshot is published for transparency before deployment.
>
> This repository is published by VECT LABS for transparency. The contract is immutable: it has no owner, no admin, no upgrade and no pause, and it holds no funds between transactions. Deployed address and verified source: not deployed yet (the address and the Sourcify link will be added at deployment).
>
> Using this contract directly, outside vect.trade, is at your own risk and is not a service of VECT LABS. For vect.trade users, the vect.trade Terms of Use apply.
>
> Nothing in this repository is an offer or a solicitation to buy or sell any crypto-asset or financial instrument, or investment advice.
>
> The code is provided under the MIT licence, "as is", without warranty of any kind. **VECT is a trademark of VECT LABS (French trademark no. 5315690); the licence grants no right to use the VECT name or logo.**
>
> Security reports: security@vect.trade (see vect.trade/security).

## What it is
A stateless swap executor for Robinhood Chain (chain ID 4663). It executes, in one user-signed transaction, a route across Uniswap v2 and v3 pools, Uniswap v4 pools (hookless or a fixed set of pinned hooks) and five concentrated-liquidity fork factories.
- The input is pulled with a Permit2 SignatureTransfer for the exact amount.
- The recipient is the caller.
- The fee recipient is immutable.
- Every pool address is derived on chain from its factory (CREATE2 or clone) and never taken from the caller.
- Callbacks are bound in transient storage.
- The minimum output is checked on the recipient's balance change.

## Layout
- `src/VectExecutor.sol`: the contract.
- `src/Interfaces.sol`: minimal interfaces declared from public ABIs.
- `manifest.json`: every constructor immutable for Robinhood Chain (4663).
- `test/`: Foundry suites.
  - `Adversarial.t.sol`: hostile pools, tokens, callbacks, permits and deadlines.
  - `BoundaryF3.t.sol`: exact min-out, fee-base and inflating-token boundaries.
  - `Fork.t.sol`: real pools of every family, wei-exact against the pool itself.
  - `Differential.t.sol`: wei-exact against the Uniswap Universal Router.
  - `Fuzz.t.sol`, `Invariant.t.sol`, `InvariantQA.t.sol`: properties and handler-based invariants with hostile actors.
- `lib/forge-std`: the vendored test dependency (forge-std v1.17.0, `src` only; MIT / Apache-2.0).

## Build and test
Toolchain: forge 1.8.7, solc 0.8.38, EVM `cancun`, optimizer 200 runs, via IR, no metadata hash.

```
export ROBINHOOD_RPC=<an archive-capable Robinhood Chain RPC>
forge build
forge test                                    # fork suites need ROBINHOOD_RPC at block 103,505,000
LOCAL_WORLD=1 forge test --match-contract InvariantQATest
```

## Licences of imports
| Import | Licence |
|---|---|
| `src/Interfaces.sol` (own declarations) | MIT |
| `forge-std` (tests only) | MIT / Apache-2.0 |

No Uniswap code is imported or compiled in; Uniswap contracts are only called on chain in the fork tests.
