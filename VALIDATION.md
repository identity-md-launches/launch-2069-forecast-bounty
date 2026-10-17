# Validation record

Checked on 2026-10-17 with Foundry 1.8.5 and the repository's pinned Solidity 0.8.26 configuration.

| Check | Result |
| --- | --- |
| `forge build` | Pass |
| `forge build --sizes` | Pass; every production runtime is below 24,576 bytes |
| `forge fmt --check` | Pass |
| Local project tests | 64 passed, 0 failed, 0 skipped |
| Ethereum mainnet fork project tests | 64 passed, 0 failed, 0 skipped, at block **26,211,237** |
| Stateful invariant campaign, in each suite | 128 runs, 8,192 generated calls, all three invariants and terminal fund-recovery checks passed |
| Supplied mainnet panel addresses | All three had empty code at the tested fork block; distinct and nonzero checks passed |

Both test runs used the assignment seed:

```sh
forge test --fuzz-seed 0x79a003b85502e7f82d26b841c2a3ecd5c94f417c32c19f0fc9b1c332ff4e7526
forge test --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26211237 --fuzz-seed 0x79a003b85502e7f82d26b841c2a3ecd5c94f417c32c19f0fc9b1c332ff4e7526
```

Five parameterized fuzz tests use 256 cases each. Foundry reports the three grouped stateful invariants as one test entry in the 64-test total. The handler randomizes protocol actors, operations, amounts, values, and time; its external caller is fixed because it has no role in the modeled protocol and random caller addresses would cause unnecessary mainnet RPC reads.

| Production artifact | Runtime bytes |
| --- | ---: |
| `LaunchToken` / `ForecastToken` implementation | 1,722 |
| `BountyRegistry` | 2,518 |
| `DisputeWindow` | 5,458 |
| `ResolverStake` | 3,781 |
| `ForecastBounty` | 10,919 |
| `BountySubsidy` | 3,570 |
| `ResolverBootstrap` | 4,279 |

The empty-chain constructor test clears only its local fixture accounts to model absent dependencies; it does not clear the supplied panel addresses. The separate signer test reads their actual fork code.

These are reproducible implementer checks, not independent acceptance or an audit. The external protected suite, production factory allocation, pool creation, deployed-bytecode verification, manifest review, and independent security review remain the launch workflow's responsibilities. See [README.md](README.md) and [SECURITY.md](SECURITY.md) for behavior and limitations.
