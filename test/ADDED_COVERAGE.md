# Additional FORECAST test coverage

These tests extend the existing protocol suite without changing production contracts or configuration.

| File | Properties exercised |
| --- | --- |
| `LifecycleProperties.t.sol` | Five entrants, arbitrary signed values and rewards, closest-winner optimality and first-entry ties, all four arbitration outcomes (a panel timeout keeps the original resolution and its winner, and the reward cannot be refunded), full participant bond refunds before/during/after arbitration, exact final wallet wealth, insufficient allowances, resolution event contents. |
| `ComponentIsolation.t.sol` | Wrong component assets/bonds/thresholds fail atomically; two real markets sharing dependencies cannot share forecasts, stake locks or disputes; all 25 registry state-transition pairs preserve original terms and existing history. |
| `StakeLedgerInvariant.t.sol` | Four actors across three market namespaces, donated surplus, third-party deposits, concurrent locks, slashing, replay rejection and partial/full withdrawal against an independent input-driven ledger. Every sequence ends with settlement and full recovery of remaining principal. |
| `DonationLedgerInvariant.t.sol` | Both real funding pools under interleaved pull deposits, direct transfers, permissionless synchronization, grants and bounty replacement. Replacement either runs the bounty to finality with an entry, which frees the creator's subsidy slot, or refunds it, which keeps the slot held, so refund loops cannot release a second grant. Independent ghosts distinguish uncredited surplus from spendable funds and check actual bootstrap recipients. |

The new invariants use bounded inputs, explicit expected reverts and `fail-on-revert = true`.
Fixtures seed active positions, completed releases and replayable settled records so properties do
not depend on random calls reaching those states. No token balances or supply are fabricated by cheatcodes.
The existing protocol invariant continues to exercise bounty rewards, participant bonds and dispute escrow.

Run the complete suite with the assignment's seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x79a003b85502e7f82d26b841c2a3ecd5c94f417c32c19f0fc9b1c332ff4e7526 forge test
```

The new lifecycle property runs 1,000 examples. The additional invariant campaigns run 256 sequences
at depths 96 (stake) and 64 (donation pools), with settings carried in the test source.

All tests use local deployments and can also run under `forge test --fork-url <mainnet RPC URL>`.
A mainnet fork run was not performed in this environment. Factory allocation and Uniswap pool creation
are outside these additional application tests; the actual factory is not deployed by these fixtures.

## Reported, not asserted

`.imd-findings.json` reports two slash-routing defects from the third-value rule in
`ForecastBounty._finalize`. When the creator's own entry is the corrected winner, the slash goes back to
the resolver. When the bounty is empty and overturned, no slash happens at all. It also reports a low
deviation: a refunded subsidised bounty holds the creator's subsidy slot forever. No test here asserts
the slash behaviour; the proofs in the findings fail on the current code.
