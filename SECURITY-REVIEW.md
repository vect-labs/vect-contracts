# Security review: EXEC-01 VectExecutor

**No external audit.** The contract was reviewed internally by VECT LABS. It has **not** been audited by an external firm.

- **Reviewed source:** `exec01/` at this repository's tag (the private source SHA is in `PUBLISHED_FROM.txt`).
- **Date:** November 2026.
- **Scope:** `exec01/src/VectExecutor.sol` and `exec01/src/Interfaces.sol`.
- **Methods:**
  - an independent manual review of the source;
  - adversarial tests (hostile pools, tokens, callbacks, Permit2 signatures, deadlines, re-entry, donations);
  - fork tests on real Robinhood Chain pools of every supported family;
  - wei-exact differential tests against the Uniswap Universal Router;
  - fuzzing (at least 10,000 runs per property) and handler-based invariants (at least 100,000 calls per invariant);
  - mutation testing of the callback authentication and minimum-output checks;
  - static analysis with Slither and Aderyn.
- **Result:** no defect requiring a change to the contract's behaviour remained open at the reviewed source.
- **Limits:** an internal review is not a guarantee. The contract interacts with third-party pools, hooks and tokens whose behaviour can change; the minimum output signed by the user is the protection against such changes.

The tests in `exec01/test/` reproduce the review's test campaign.
