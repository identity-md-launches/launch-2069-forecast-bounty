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

The lifecycle fuzz properties run 1,000 examples each. The additional invariant campaigns run 256 sequences
at depths 96 (stake) and 64 (donation pools), with settings carried in the test source.

All tests use local deployments and can also run under `forge test --fork-url <mainnet RPC URL>`.
A mainnet fork run was not performed in this environment. Factory allocation and Uniswap pool creation
are outside these additional application tests; the actual factory is not deployed by these fixtures.

## Reported, then fixed

The previous round reported two slash-routing defects in `ForecastBounty._finalize`'s third-value rule:
the slash went back to the resolver when the creator's own entry was the corrected winner, and an empty,
overturned bounty was never slashed. The current implementation fixes both.
`LifecycleProperties.testFuzzOverturnSlashRoutingAndConservation` now locks the rule in over 1,000 panel
decisions with random entrant sets, ties and creator entries. Every overturn slashes exactly `SLASH_BPS`.
The slash goes to the disputer when the panel matched the disputer's value. Otherwise it goes to the
forecaster who wins under the panel value, checked independently, or to the disputer when that winner is
the resolver or nobody. No other wallet's balance moves. This property fails on the pre-fix code
(counterexample: every entry 0, creator entering, proposed 17, disputer 25, panel 0).

Still reported in `.imd-findings.json` as low: a refunded or expired subsidised bounty holds the creator's
subsidy slot forever, which is stricter than the brief's "no other subsidised bounty open". The
implementation documents this as deliberate anti-farming, and `DonationLedgerInvariant` models it as it is.
