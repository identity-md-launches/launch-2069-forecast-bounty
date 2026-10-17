# Security model and local adversarial review

This is the implementer's review, not an independent audit. A separate contributor should review source and the final deployment manifest before release. The launch factory and its v4 pool initialization were not supplied as project source and are not certified by these application tests.

## Custody and authorization

- FORECAST is the only supported asset. The token has fixed supply and no callback, fee, rebase, owner, or upgrade behavior. SafeERC20 checks transfer results; deposits additionally verify the exact balance increase.
- The bounty contract holds unspent rewards and refundable participant bonds. These are separately accounted in `rewardLiability` and `bondLiability`.
- Dispute bonds are held separately in `DisputeWindow`; escrow is converted to recipient credits exactly once. Recipient withdrawals never push funds through unrelated recipient contracts.
- Resolver stake is held separately in `ResolverStake`. Market namespaces prevent one market from locking or slashing another market's deposits. The depositor explicitly selects the market. A successful dispute is the only canonical-market path to a slash; immutable bounty code invokes settlement once.
- Every token-moving application entry point uses a storage reentrancy guard. Payout eligibility is consumed before transfers. A failed transfer reverts the entire cross-contract transaction, including registry changes, credits, and stake unlocks.
- No contract has an owner, proxy, emergency withdrawal, pause, upgrade, arbitrary call, delegatecall, or asset sweep. The only human privileged role is the immutable panel's authority to vote on a disputed value. That role cannot block participant bond withdrawals after resolution.

## State transitions and boundaries

- Entry is allowed strictly before the deadline. Resolution begins at the deadline and ends strictly before the deadline plus seven days. Creator refunds are allowed from the deadline; permissionless expiry starts exactly seven days later.
- The reward cannot be claimed while a resolution is disputable or while its panel case is pending. A majority must agree on the exact numeric value. A challenge with an intentionally wrong suggested value cannot prevent a panel majority from choosing a third, correct value.
- An unchallenged window closes exactly 48 hours after resolution. A challenged case has seven days from the challenge; the original 48-hour expiry does not unlock it. At panel expiry, both case bonds are returned and the bounty becomes refundable rather than inventing a winning value.
- All participants, including a losing forecaster and the provisional winner whose result is overturned, retain a full 100 FORECAST refund. An abandoned unresolved bounty has a permissionless recovery path.
- Each dispute, entry, reward payout, participant refund, grant, panel vote, and slash reservation has explicit replay/duplicate protection. Voting is a direct signer transaction; there are no reusable offchain signatures.

## Arithmetic, backing, and bounded work

- Winner selection visits at most 500 entries. Mapping signed values into ordered unsigned values makes the full `int256.min` to `int256.max` distance representable as `uint256.max`; no signed subtraction/negation overflows. Exact ties select the earlier submission.
- Slash amounts use quotient/remainder arithmetic equivalent to `floor(balance * bps / 10000)` without overflowing the multiplication. Reservations prevent concurrent slashes exceeding the available balance. Top-ups and settlement order do not alter existing penalty snapshots.
- No production path loops over every bounty or every resolver. Registry history is paginated one transition at a time; entries can be accessed individually after resolution.
- Pool grants consume only accounted donations. The no-argument deposit credits the difference between the pool balance and its remaining allocation, so direct transfers can be credited once without fabricating donor entitlements.

## Evidence in the delivered tests

`ForecastBounty.t.sol` and `DisputeWindow.t.sol` exercise winning/losing claims, both dispute outcomes, last-second challenges, exact boundaries, panel failure, duplicate actions, empty bounties, signed extremes, tie order, and all 500 entries. The 500-entry resolution has an explicit 8-million-gas upper bound in the test; the larger reported gas for that whole test includes funding and submitting all 500 separate forecasts.

`ResolverStake.t.sol` verifies concurrent reservations, five simultaneous successful slashes exhausting exactly the snapshot backing, stake top-ups, third-party deposits, and isolation from counterfeit markets. `FundingPools.t.sol` exercises both deposit forms, exhaustion, lifecycle eligibility, lifetime bootstrap grants, and lack of admin withdrawal paths. `BountyRegistry.t.sol` checks namespace isolation and retained original terms/history.

`AdversarialToken.t.sol` uses a test-only hostile asset to attempt callbacks during reward deposits, funding-pool syncs, stake deposits, window opening, and reward payouts. It tests rejection of short/false incoming transfers and rollback/retry of a failed outgoing payout. That mock is never a production launch artifact.

`ProtocolInvariant.t.sol` generates stateful sequences of deposits, bounty creation, forecasts, resolution, challenges, both panel voting methods, expiry, finalization, payouts, subsidies, bootstrap grants, and time advances. It recomputes unpaid reward/bond obligations, active locks/reservations, subsidy slots, credit totals, total supply, and every contract's token backing. After each generated run, the recovery check advances beyond every timeout, settles all bounties, and withdraws every remaining reward, bond, dispute credit, and resolver deposit; only donated pool funds may remain. Invalid actions are caught by the handler; the unit tests assert their specific failure reasons separately. Getter privacy is checked across unresolved states.

`Deployment.t.sol` checks a single-transaction constructor rehearsal, unchanged supply custody, static configuration, empty-chain constructor execution, application runtime limits, absence of forbidden escape opcodes, absence of common owner/pause/upgrade selectors, and the pinned signers' code. The same tests can run under a mainnet fork without environment-dependent test code.

Foundry's build lints include expected timestamp notices (deadlines are intentional), guarded-call/event reentrancy notices, exact-balance comparison notices, and the deliberate signed-to-unsigned distance representation. Quotient/remainder slashing is covered against an independent bounded arithmetic reference. These notices are reviewed in context; they are not hidden by disabling safety checks. Slither and Mythril were not run.

## Explicit limitations to retain in the launch review

- Solidity-private storage and omitted getters/events do not hide transaction calldata or raw storage. This protocol does not provide cryptographic forecast secrecy or protection from forecast copying/ordering.
- The creator can refund an unresolved bounty at its deadline, as requested. Reward payout is conditional on resolution and finality. A panel timeout also refunds the creator instead of distributing a potentially incorrect reward.
- Truth is determined socially by the declared source, monitoring, and the fixed panel. Two colluding signers can choose a false value; no challenge means the submitted value stands. Signer rotation is impossible. Loss of quorum invokes the documented timeout.
- The 25,000 minimum stake and 20% snapshot penalty are fixed, independent of bounty size. They do not guarantee that dishonesty is economically irrational for every bounty.
- Wallet uniqueness is not person uniqueness. A resolver can use a separate wallet to challenge itself and receive its own slash, though a correct panel still corrects the winner. There is no identity-based protection for subsidy/bootstrap grants, self-funded questions, sequential refunds, or Sybil use of the 500 entry slots.
- Donations cannot be reclaimed by any administrator or donor. An eligible grant is not clawed back after later cancellation. Unsupported tokens or ETH sent directly to the contracts cannot be swept.
- A live network can censor transactions; timestamps and first-submission tie ordering are subject to transaction inclusion/order. No randomness is used.
- The manifest step must select the one launch token, six application artifacts, canonical arguments, ETH pair, 50% pool share, and given remainder/signers. Reconfirm deployed bytecode and the signer EOAs at launch. Factory supply allocation and pool creation require their own launch verification.
