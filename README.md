# Forecast Bounty Protocol · FORECAST

An immutable, ownerless forecasting bounty protocol for Ethereum mainnet. Creators escrow FORECAST rewards, participants post fully refundable FORECAST bonds, and a staked creator resolves each question. The closest numeric forecast receives the reward after arbitration is final.

## Build and test

Run from this repository's root:

```sh
forge build
forge test --fuzz-seed 0x79a003b85502e7f82d26b841c2a3ecd5c94f417c32c19f0fc9b1c332ff4e7526
forge fmt --check
```

The same suite runs on a mainnet fork, including checking that the three supplied panel addresses have no deployed code:

```sh
forge test --fork-url https://ethereum-rpc.publicnode.com --fuzz-seed 0x79a003b85502e7f82d26b841c2a3ecd5c94f417c32c19f0fc9b1c332ff4e7526
```

An explicit `--fork-block-number` can pin a reproducible mainnet snapshot. No test reads environment variables, requires a funded account, broadcasts, or creates its own network fork. The ordinary suite is entirely local. Solidity **0.8.26**, Cancun EVM, optimizer settings, and `bytecode_hash = "none"` are pinned in [foundry.toml](foundry.toml). Necessary libraries are vendored as ordinary files under `lib/`; see [DEPENDENCIES.md](DEPENDENCIES.md).

The tests cover successful and failed payouts, exact deadlines, duplicate entry/claim/vote rejection, all 500 entries, signed integer extremes, both arbitration outcomes, unavailable panels, reserved slash backing, hostile-token callbacks, deployment constraints, and stateful conservation invariants. [VALIDATION.md](VALIDATION.md) records the local and mainnet-fork results. The supplied protected checks are external admission checks; they are not copied into this project or represented as locally executed.

## Contracts and deployment

Deploy **one `LaunchToken`**, which inherits the requested `ForecastToken` implementation unchanged. The factory-facing artifact is `src/LaunchToken.sol:LaunchToken`; `ForecastToken` is also available under its requested Solidity name, but is not a second launch asset. It mints exactly **1,000,000,000 FORECAST**, with 18 decimals, once to its constructor caller. Its name is **Forecast Bounty** and symbol is **FORECAST**. There are no external mint/burn functions, fees, owner, blacklist, pause, or upgrade path.

The six application contracts follow this dependency order. Symbols in the argument column refer to contracts already deployed in that order; they are not literal placeholder addresses.

| Artifact | Static constructor arguments, in order |
| --- | --- |
| `LaunchToken` | None |
| `BountyRegistry` | None |
| `DisputeWindow` | token, BOND, DISPUTE_WINDOW, disputeSigner1, disputeSigner2, disputeSigner3 |
| `ResolverStake` | token, RESOLVER_STAKE, SLASH_BPS |
| `ForecastBounty` | token, registry, resolverStake, disputeWindow, MIN_REWARD, BOND, MAX_ENTRIES |
| `BountySubsidy` | token, bounty, MIN_REWARD |
| `ResolverBootstrap` | token, bounty, resolverStake |

All constructors are nonpayable, use only static arguments, and make no external calls or dependency-code checks. They do not move token supply. Zero dependency addresses and invalid parameters revert; the dispute constructor specifically rejects a zero panel member with `ZeroAddress()` and any duplicate with `DuplicateSigner()`. No initializer or privileged setup transaction is needed. No application contract is owned by its deployer or by the factory.

[DeploymentConfig.sol](src/DeploymentConfig.sol) fixes the launch inputs. [DeployForecast.s.sol](script/DeployForecast.s.sol) is a **local construction rehearsal**, tested through `run()`. It does not broadcast or call the launch factory, and its locally minted supply stays with the rehearsal script. Do not deploy that script as an application contract. The network's ProjectFactory deploys each production artifact and performs its own allocation in one transaction. The separate launch workflow supplies the manifest, factory interaction, pool initialization, deployed addresses, and GitHub/explorer publication; this repository does not contain a `launch.json` or invented deployment addresses.

| Parameter | Value |
| --- | --- |
| `MIN_REWARD` | `5_000e18` FORECAST minor units |
| `BOND` | `100e18` |
| `RESOLVER_STAKE` | `25_000e18` |
| `SLASH_BPS` | `2000` (20%) |
| `DISPUTE_WINDOW` | `48 hours` |
| `MAX_ENTRIES` | `500` |
| Chain | Ethereum mainnet, chain ID `1` |
| Pair | Native ETH; Uniswap v4 Currency encoding `address(0)` |
| `poolBps` | `5000` (50%) |
| `remainderTo` | `0xbb85c1b7540d9e7b56f7a595fc1ff7dd07cb0823` |
| `disputeSigner1` | `0xAF5a05077Da3e3D130d66C1C73362306cc89d899` |
| `disputeSigner2` | `0xC4F6e66C24fDc6Ae0f859c468dd177f8100b4959` |
| `disputeSigner3` | `0xc9b5c6b29F66D526b76e68198F70d66342b0d84c` |

The factory allocates **500,000,000 FORECAST to the v4 pool**, **100,000,000 automatically to its swarm distribution**, and **400,000,000 to `remainderTo`**. There is no swarm address or swarm configuration parameter in this project. Neither funding pool receives a factory allocation. Native ETH's zero Currency encoding is a protocol-defined identifier, not an unset dependency. No application performs swaps or implements pool fee logic. Pool trading uses the launch factory's policy fee (1.25% in the supplied launch policy); the deployment handoff supplies the effective opening price and exact pool key.

## Bounty lifecycle and API

IDs start at 1. Forecasts and true values are `int256`, including both integer extremes. Each question must define its units, scale, observation time, and a clear `resolutionSource` string. Values are not automatically scaled to token decimals. The source is recorded metadata for participants and the panel, not an oracle that the contract calls.

1. The creator approves the bounty contract for `rewardAmount`, then calls `createBounty(question, deadline, resolutionSource, rewardAmount)`. The strings must be nonempty, the deadline must be in the future, and the reward must meet `MIN_REWARD`. The whole reward is escrowed; `BountyCreated` and the registry record publish the terms.
2. Before `deadline`, each address may approve and post exactly one `forecast(bountyId, value)` with a 100 FORECAST bond. Resubmission and a 501st entry revert. Participants may also be creators or panel members; there is no identity gate.
3. Following the brief's creator-resolution wording, **only that bounty's creator may resolve**. The creator approves `ResolverStake`, calls `deposit(bountyAddress, amount)` to stake at least 25,000 FORECAST for this specific market, and separately approves `ForecastBounty` for a 100 FORECAST resolution bond. `resolve(bountyId, trueValue)` is allowed from the deadline until seven days later, unless already refunded. It makes one bounded pass over entries. Smallest absolute error wins; **earliest submitted entry wins an exact tie**. `BountyResolved` announces the provisional value and winner.
4. Immediately after resolution, **every participant may `withdrawBond(bountyId)` in full**, even during a dispute. This includes the winner. The participant bond never funds arbitration or slashing and no panel vote or administrator can block it.
5. The reward remains locked during the dispute window or a pending panel case. Anyone may call `finalize(bountyId)` when eligible. `claim(bountyId)` also attempts finalization and then pays only the final winner, once. A successful dispute recomputes the winner with the panel's accepted value before any reward transfer.
6. The creator may `refundReward(bountyId)` after the deadline if unresolved, or immediately after resolving a bounty with zero entries. An unresolved refund cancels the bounty and unlocks participant bonds. Resolving an empty bounty still carries its independent dispute bond and stake lock until finalization. A finalized bounty with entries cannot be refunded.

**Creator refund discretion is part of the requested behavior:** the creator can reclaim an unresolved reward at the entry deadline rather than resolve. Participation therefore does not guarantee a reward will be distributed. A refund and a resolution compete by transaction order; only the first valid state transition succeeds.

If a creator takes no action, anyone may `expire(bountyId)` at `deadline + 7 days`. A participant's `withdrawBond` automatically expires an unresolved bounty at that point. Expiry makes the reward refundable and prevents later resolution. No keeper is privileged; callers pay gas and receive no maintenance fee.

### Forecast visibility

Entry values are private storage, not public mappings; `entryAt` and `forecastOf` revert with `ForecastsHidden()` until `resolve` has executed. Submission events contain only the bounty ID and forecaster. Expired bounties that never resolved keep these getters closed.

**This provides API-level hiding, not cryptographic secrecy.** Ethereum transaction calldata and storage are public. Someone reading raw transactions/storage can discover and copy a submitted value before resolution. The specified `forecast(id, value)` interface cannot provide confidentiality on a public EVM; a commit/reveal or encryption protocol would require a different interface and additional lifecycle rules. Frontends must not market these forecasts as secret.

## Disputes and resolver stake

The resolver posts a separate **100 FORECAST bond** on resolution; this is what “equal bond” means here. Anyone other than the resolver can call `dispute(bountyAddress, id, suggestedValue)` **strictly before** `resolvedAt + 48 hours`, with a distinct suggested value and another 100 FORECAST bond. Only one dispute is admitted per bounty, and it moves the registry to `Disputed`.

Panel members submit direct transactions; no offchain signature relayer is required:

| Action | Meaning |
| --- | --- |
| `vote(bountyAddress, id, true)` | Vote for the challenger's suggested value |
| `vote(bountyAddress, id, false)` | Vote for the original resolution value |
| `voteValue(bountyAddress, id, actualValue)` | Vote for another value if both suggestions are wrong |

Each immutable signer gets exactly one vote per case, across both methods. **Two signers must agree on the exact same value**, not merely both disagree with the original. This prevents a bogus first challenger from restricting the panel to two incorrect choices. A majority ends the dispute immediately; there is no second challenge or appeal. `valueVotes` and the `Voted` event expose exact votes; `acceptVotes`/`rejectVotes` are informational counts relative to the original value.

| Outcome | Reward | Resolution/challenge bonds | Resolver stake |
| --- | --- | --- | --- |
| No challenge by 48 hours | Original closest forecast | Resolver recovers its 100 | Released on bounty finalization |
| Panel agrees with original | Original closest forecast | Resolver receives both bonds (200) | No slash |
| Panel selects a different value | Recomputed closest forecast | Disputer receives both bonds (200), even if the panel chose a third value | Reserved 20% penalty paid to disputer |
| No exact-value majority within seven days of challenge | Original resolution stands (original winner) | Each side recovers its own 100 | Released, no slash |

The 7-day panel timeout is fixed in `DeploymentConfig`. At its exact boundary, voting stops and permissionless finalization becomes available. This avoids permanent custody if signers disappear or all vote differently. Participants can recover their bonds throughout. The panel has no other contract powers and cannot change its own members.

Window payouts are pull payments: recipients call `DisputeWindow.withdrawPayout()`. Slashing is delivered during `ForecastBounty.finalize`; a panel decision alone does not yet unlock the stake. A winner's eligible claim can finalize automatically.

`ResolverStake.deposit(bountyAddress, amount)` credits the caller; `depositFor(bountyAddress, resolver, amount)` permits third-party funding. Deposits explicitly select the market whose code can lock and slash them. Use the canonical bounty address from the deployment handoff. A counterfeit market cannot touch the canonical market's balances, locks, registry records, or dispute cases.

`withdraw(bountyAddress, amount)` is available only when every lock in that market is settled. A resolution reserves `floor(stakeAtResolution * 2000 / 10000)` and prevents withdrawal of the entire remaining deposit while any resolution remains pending. Top-ups do not change earlier penalty snapshots. Concurrent resolutions may reserve no more than the deposited stake; five resolutions at an unchanged stake exhaust the available reservations. Each reservation remains fully funded even if all disputes succeed. Falling below 25,000 after a slash prevents new resolutions until topped up. Snapshot semantics make the penalty deterministic and prevent top-ups or settlement ordering from changing a pending case's backing.

## Post-launch donation pools

Both pools start at zero. Anyone can approve the pool and call `deposit(amount)`, or transfer FORECAST directly and then call its no-argument `deposit()` to credit the unaccounted balance. The latter can be called by any wallet on behalf of direct donors. Repeated syncs cannot credit the same transfer twice. Donations are irrevocable; they create no depositor shares, refund claim, owner withdrawal, or privileged funding route. Uncredited direct transfers are not available for grants until synced.

The brief does not specify subsidy amounts or bootstrap release rules. This implementation chooses fixed **100 FORECAST** grants for both, defined as `SUBSIDY_AMOUNT` and `BOOTSTRAP_AMOUNT` in `DeploymentConfig`:

| Pool | Release rule |
| --- | --- |
| `BountySubsidy` | The creator calls `subsidize(id)` while entries are open and the funded reward meets 5,000 FORECAST. Pays exactly 100 to that creator once per bounty. A creator cannot have another subsidised bounty pending settlement. Finalization or cancellation frees the slot. |
| `ResolverBootstrap` | Anyone calls `bootstrap(id)` after an eligible final resolution with at least one entry, no successful dispute, and at least 25,000 still staked. Credits exactly 100 into that creator's resolver stake, once per resolver address for the lifetime of this pool. The caller receives nothing. |

Each release requires the full grant amount in credited donations. Insufficient funding reverts without consuming eligibility. Cumulative releases never exceed credited donations. The bootstrap helps retain active resolvers; it does **not** provide the initial 25,000 stake or grant resolution rights to an unfunded address.

These are permissionless incentives with **no Sybil resistance**. A creator's subsidy slot is freed only when the subsidised bounty reaches Finalized with at least one entry; a refunded/expired or empty subsidised bounty keeps the slot permanently, so create/refund loops get at most one grant per address. Self-funded questions and alternate wallets can qualify for grants. Donors should budget these finite pools with that eligibility in mind; no admin can ration or recover donations. There is no invented allowlist or requester-controlled funding override.

## Registry and operational responsibilities

`BountyRegistry` indexes records by **(bounty contract address, bounty ID)**. It stores the original question hash, creator, reward, and deadline plus a current state and resolution value. Every state transition appends an immutable history entry; original terms and earlier resolution values remain readable. Other contracts may use their own namespace but cannot edit the canonical namespace. Indexers must filter on the canonical bounty address rather than trusting unrelated registry events. Panel decisions are reflected in the final registry state when anyone finalizes the bounty.

After launch:

- The requester receives the factory remainder and decides whether and how much to donate to the two pools. No automatic pool funding or admin setup is required.
- Creators specify unambiguous questions/sources, escrow rewards, maintain their own resolver stake and gas, resolve in time, and recover eligible refunds/dispute credits.
- Participants monitor provisional resolutions and challenge mistakes within 48 hours; the contracts do not automatically fetch external truth. Everyone withdraws their own bonds and the winner claims the reward.
- The three panel signers inspect the declared resolution source, coordinate on the exact numeric units/value, and submit matching votes before the 7-day case deadline. Their keys remain theirs; this repository requires no keys.
- Any user or keeper may finalize or expire eligible bounties. Integration code must distinguish provisional and final winners and present timeout/refund states.
- The launch workflow publishes accepted source on GitHub, verifies deployed bytecode, provides the actual deployment/pool addresses, and reconfirms the pinned signer addresses before deployment. No transaction was broadcast by this implementation task.

Two colluding signers can choose a false value; an unattended window accepts the creator's value. The fixed minimum stake does not scale with bounty size. The slash (and both bonds) go to the disputer only when the panel's value equals the disputer's corrected value; when the panel picks a third value, the slash goes to the corrected winner instead, so a resolver's sock wallet filling the single dispute slot with a bogus value cannot recover the slash. An alternate wallet that disputes with the exact true value still can. These are trust/economic limits, not administrative powers or oracle guarantees. See [SECURITY.md](SECURITY.md) for the local adversarial review and remaining review responsibilities.
