// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {ResolverStake} from "src/ResolverStake.sol";
import {DeploymentConfig as C} from "src/DeploymentConfig.sol";
import {TokenPool} from "src/lib/TokenPool.sol";

/// @dev Independent ledger: successful inputs update ghosts; contract getters never set expectations.
/// Multiple markets deliberately reuse bounty ids and resolvers to exercise namespace isolation.
contract StakeLedgerHandler is Test {
    struct ExpectedLock {
        uint256 actor;
        uint256 penalty;
        bool active;
    }

    LaunchToken public immutable token;
    ResolverStake public immutable stake;
    address[4] public actors;
    address[3] public markets;
    uint256[4] public wallet;
    uint256[4][3] public principal;
    uint256[4][3] public reserved;
    uint256[4][3] public lockCount;
    uint256[3] public issued;
    mapping(uint256 market => mapping(uint256 id => ExpectedLock)) public positions;
    uint256 public donated;
    uint256 public deposited;
    uint256 public withdrawn;
    uint256 public slashed;

    constructor(LaunchToken t, ResolverStake s, address[4] memory users, address[3] memory namespaces) {
        token = t;
        stake = s;
        actors = users;
        markets = namespaces;
        for (uint256 a; a < users.length; ++a) {
            wallet[a] = t.balanceOf(users[a]);
        }
    }

    function deposit(uint256 m, uint256 donor, uint256 recipient, uint256 raw, bool forOther) external {
        m %= 3;
        donor %= 4;
        recipient = forOther ? recipient % 4 : donor;
        uint256 amount = bound(raw, 0, wallet[donor] < 50_000e18 ? wallet[donor] : 50_000e18);
        vm.prank(actors[donor]);
        token.approve(address(stake), amount);
        vm.prank(actors[donor]);
        if (amount == 0) vm.expectRevert(TokenPool.ZeroAmount.selector);
        if (forOther) stake.depositFor(markets[m], actors[recipient], amount);
        else stake.deposit(markets[m], amount);
        if (amount == 0) return;
        wallet[donor] -= amount;
        principal[m][recipient] += amount;
        deposited += amount;
    }

    function lock(uint256 m, uint256 a) external {
        m %= 3;
        a %= 4;
        if (issued[m] >= 48) return;
        uint256 id = issued[m] + 1;
        uint256 penalty = principal[m][a] * C.SLASH_BPS / 10_000;
        bool eligible = principal[m][a] >= C.RESOLVER_STAKE && penalty <= principal[m][a] - reserved[m][a];
        vm.prank(markets[m]);
        if (!eligible) vm.expectRevert(ResolverStake.InsufficientStake.selector);
        stake.lock(id, actors[a]);
        if (!eligible) return;
        issued[m] = id;
        positions[m][id] = ExpectedLock(a, penalty, true);
        ++lockCount[m][a];
        reserved[m][a] += penalty;
    }

    function settle(uint256 m, uint256 rawId, bool slash, uint256 recipient) external {
        m %= 3;
        uint256 id = bound(rawId, 1, issued[m] + 1);
        recipient %= 4;
        if (!positions[m][id].active) {
            vm.prank(markets[m]);
            vm.expectRevert(ResolverStake.UnknownLock.selector);
            stake.settle(id, slash, actors[recipient]);
            return;
        }
        _settle(m, id, slash, recipient);
    }

    function _settle(uint256 m, uint256 id, bool slash, uint256 recipient) private {
        ExpectedLock storage p = positions[m][id];
        vm.prank(markets[m]);
        uint256 paid = stake.settle(id, slash, actors[recipient]);
        assertEq(paid, slash ? p.penalty : 0, "settle return value");
        p.active = false;
        --lockCount[m][p.actor];
        reserved[m][p.actor] -= p.penalty;
        if (slash) {
            principal[m][p.actor] -= p.penalty;
            wallet[recipient] += p.penalty;
            slashed += p.penalty;
        }
    }

    function withdraw(uint256 m, uint256 a, uint256 raw, bool full) external {
        m %= 3;
        a %= 4;
        uint256 amount = full ? principal[m][a] : bound(raw, 0, principal[m][a] + 1);
        bytes4 reason;
        if (amount == 0) reason = TokenPool.ZeroAmount.selector;
        else if (lockCount[m][a] != 0) reason = ResolverStake.StakeLocked.selector;
        else if (amount > principal[m][a]) reason = ResolverStake.InsufficientStake.selector;
        vm.prank(actors[a]);
        if (reason != bytes4(0)) vm.expectRevert(reason);
        stake.withdraw(markets[m], amount);
        if (reason != bytes4(0)) return;
        principal[m][a] -= amount;
        wallet[a] += amount;
        withdrawn += amount;
    }

    function donate(uint256 a, uint256 raw) external {
        a %= 4;
        uint256 amount = bound(raw, 0, wallet[a] < 1_000e18 ? wallet[a] : 1_000e18);
        vm.prank(actors[a]);
        assertTrue(token.transfer(address(stake), amount));
        wallet[a] -= amount;
        donated += amount;
    }

    /// @dev Reusing an id must fail even after settlement; a foreign namespace must not settle it.
    function replayOrCrossMarket(uint256 m, uint256 rawId, uint256 a, bool foreign) external {
        m %= 3;
        if (issued[m] == 0) return;
        uint256 id = bound(rawId, 1, issued[m]);
        if (foreign) {
            // Every actor is disjoint from the three market namespaces.
            vm.prank(actors[a % 4]);
            vm.expectRevert(ResolverStake.UnknownLock.selector);
            stake.settle(id, true, actors[a % 4]);
        } else {
            vm.prank(markets[m]);
            vm.expectRevert(ResolverStake.ExistingLock.selector);
            stake.lock(id, actors[a % 4]);
        }
    }

    function assertLedger() external view {
        uint256 total;
        for (uint256 m; m < 3; ++m) {
            uint256[4] memory counts;
            uint256[4] memory penalties;
            for (uint256 id = 1; id <= issued[m]; ++id) {
                ExpectedLock memory p = positions[m][id];
                (address resolver, uint256 amount, bool active) = stake.locks(markets[m], id);
                assertEq(resolver, actors[p.actor]);
                assertEq(amount, p.penalty);
                assertEq(active, p.active);
                if (p.active) {
                    ++counts[p.actor];
                    penalties[p.actor] += p.penalty;
                }
            }
            for (uint256 a; a < 4; ++a) {
                assertEq(stake.stakeOf(markets[m], actors[a]), principal[m][a], "principal");
                assertEq(stake.activeLocks(markets[m], actors[a]), counts[a], "lock count");
                assertEq(counts[a], lockCount[m][a]);
                assertEq(stake.reserved(markets[m], actors[a]), penalties[a], "reserved penalty");
                assertEq(penalties[a], reserved[m][a]);
                assertLe(penalties[a], principal[m][a]);
                total += principal[m][a];
            }
        }
        for (uint256 a; a < 4; ++a) {
            assertEq(token.balanceOf(actors[a]), wallet[a], "wallet ledger");
        }
        assertEq(stake.totalStaked(), total);
        assertEq(total + withdrawn + slashed, deposited, "no principal created or lost");
        assertEq(token.balanceOf(address(stake)), total + donated, "donations cannot become principal");
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    /// @dev Uncontested closure must restore every remaining principal, including one-wei deposits.
    function closeAll() external {
        for (uint256 m; m < 3; ++m) {
            for (uint256 id = 1; id <= issued[m]; ++id) {
                if (positions[m][id].active) _settle(m, id, false, 0);
            }
            for (uint256 a; a < 4; ++a) {
                uint256 amount = principal[m][a];
                if (amount == 0) continue;
                vm.prank(actors[a]);
                stake.withdraw(markets[m], amount);
                principal[m][a] = 0;
                withdrawn += amount;
                wallet[a] += amount;
            }
        }
        assertEq(stake.totalStaked(), 0);
        assertEq(token.balanceOf(address(stake)), donated);
    }
}

contract StakeLedgerInvariantTest is StdInvariant, Test {
    StakeLedgerHandler internal handler;

    function setUp() public {
        LaunchToken token = new LaunchToken();
        ResolverStake stake = new ResolverStake(address(token), C.RESOLVER_STAKE, C.SLASH_BPS);
        address[4] memory actors =
            [makeAddr("ledger alice"), makeAddr("ledger bob"), makeAddr("ledger carol"), makeAddr("ledger donor")];
        address[3] memory markets = [makeAddr("market one"), makeAddr("market two"), makeAddr("market three")];
        for (uint256 a; a < 4; ++a) {
            token.transfer(actors[a], 1_000_000e18);
        }
        handler = new StakeLedgerHandler(token, stake, actors, markets);
        // Seed non-vacuous locks sharing id 1 and the same resolver in separate namespaces.
        for (uint256 m; m < 3; ++m) {
            handler.deposit(m, 0, 0, C.RESOLVER_STAKE, false);
            handler.lock(m, 0);
        }
        handler.deposit(0, 1, 2, 1, true);
        handler.lock(0, 0);
        handler.settle(0, 2, true, 2);
        targetContract(address(handler));
        targetSender(address(this));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.lock.selector;
        selectors[2] = handler.settle.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.replayOrCrossMarket.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariantIndependentLedgerAcrossMarketsAndActors() public view {
        handler.assertLedger();
    }

    function afterInvariant() public {
        handler.closeAll();
        handler.assertLedger();
    }
}
