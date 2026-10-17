// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {ForecastBounty} from "src/ForecastBounty.sol";
import {BountySubsidy} from "src/BountySubsidy.sol";
import {ResolverBootstrap} from "src/ResolverBootstrap.sol";
import {ResolverStake} from "src/ResolverStake.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {DonationPool} from "src/lib/DonationPool.sol";
import {TokenPool} from "src/lib/TokenPool.sol";
import {DeploymentConfig as C} from "src/DeploymentConfig.sol";

/// @dev Donors and permissionless sync callers differ. Uncredited transfers may coexist with
/// pull-deposits and grants: syncing must credit only that surplus, exactly once.
contract DonationLedgerHandler is Test {
    LaunchToken internal token;
    ForecastBounty internal bounty;
    BountySubsidy internal subsidy;
    ResolverBootstrap internal bootstrap;
    ResolverStake internal stake;
    DonationPool[2] internal pools;
    address[4] internal actors;
    uint256[4] internal openIds;
    uint256[4] internal deadlines;
    uint256[4] internal resolvedIds;
    bool[4] internal subsidised;
    bool[4] internal bootstrapped;
    uint256[2] public credited;
    uint256[2] public uncredited;
    uint256[2] public received;
    uint256[2] public released;
    uint256 public rotations;

    constructor(
        LaunchToken t,
        ForecastBounty b,
        BountySubsidy s,
        ResolverBootstrap r,
        address[4] memory users,
        uint256[4] memory open,
        uint256[4] memory finalized
    ) {
        token = t;
        bounty = b;
        subsidy = s;
        bootstrap = r;
        stake = b.resolverStake();
        pools = [DonationPool(address(s)), DonationPool(address(r))];
        actors = users;
        openIds = open;
        resolvedIds = finalized;
        for (uint256 a; a < 4; ++a) {
            deadlines[a] = b.getBounty(open[a]).deadline;
        }
    }

    function deposit(uint256 poolIndex, uint256 donor, uint256 raw) external {
        poolIndex %= 2;
        donor %= 4;
        uint256 balance = token.balanceOf(actors[donor]);
        uint256 amount = bound(raw, 0, balance < 1_000e18 ? balance : 1_000e18);
        vm.prank(actors[donor]);
        if (amount == 0) vm.expectRevert(TokenPool.ZeroAmount.selector);
        pools[poolIndex].deposit(amount);
        if (amount == 0) return;
        credited[poolIndex] += amount;
        received[poolIndex] += amount;
    }

    function transferDirectly(uint256 poolIndex, uint256 donor, uint256 raw) external {
        poolIndex %= 2;
        donor %= 4;
        uint256 balance = token.balanceOf(actors[donor]);
        uint256 amount = bound(raw, 0, balance < 1_000e18 ? balance : 1_000e18);
        vm.prank(actors[donor]);
        assertTrue(token.transfer(address(pools[poolIndex]), amount));
        uncredited[poolIndex] += amount;
        received[poolIndex] += amount;
    }

    function sync(uint256 poolIndex, uint256 caller) external {
        poolIndex %= 2;
        vm.prank(actors[caller % 4]);
        if (uncredited[poolIndex] == 0) vm.expectRevert(TokenPool.ZeroAmount.selector);
        pools[poolIndex].deposit();
        credited[poolIndex] += uncredited[poolIndex];
        uncredited[poolIndex] = 0;
    }

    function subsidize(uint256 a) external {
        a %= 4;
        bytes4 reason;
        if (vm.getBlockTimestamp() >= deadlines[a]) reason = BountySubsidy.IneligibleBounty.selector;
        else if (subsidised[a]) reason = BountySubsidy.AlreadySubsidised.selector;
        else if (credited[0] - released[0] < C.SUBSIDY_AMOUNT) reason = DonationPool.InsufficientPool.selector;
        vm.prank(actors[a]);
        if (reason != bytes4(0)) vm.expectRevert(reason);
        subsidy.subsidize(openIds[a]);
        if (reason != bytes4(0)) return;
        subsidised[a] = true;
        released[0] += C.SUBSIDY_AMOUNT;
    }

    function bootstrapResolver(uint256 a, uint256 caller) external {
        a %= 4;
        bytes4 reason;
        if (bootstrapped[a]) reason = ResolverBootstrap.AlreadyBootstrapped.selector;
        else if (credited[1] - released[1] < C.BOOTSTRAP_AMOUNT) reason = DonationPool.InsufficientPool.selector;
        vm.prank(actors[caller % 4]);
        if (reason != bytes4(0)) vm.expectRevert(reason);
        bootstrap.bootstrap(resolvedIds[a]);
        if (reason != bytes4(0)) return;
        bootstrapped[a] = true;
        released[1] += C.BOOTSTRAP_AMOUNT;
    }

    /// @dev Close the previous grant's bounty and open another, allowing repeated subsidy releases
    /// without discarding the one-open-bounty rule. Time moves only through the EVM cheatcode.
    function replaceOpenBounty(uint256 a) external {
        a %= 4;
        if (rotations >= 32) return;
        if (vm.getBlockTimestamp() < deadlines[a]) vm.warp(deadlines[a]);
        vm.prank(actors[a]);
        bounty.refundReward(openIds[a]);
        deadlines[a] = vm.getBlockTimestamp() + 1 days;
        vm.prank(actors[a]);
        openIds[a] = bounty.createBounty("Next question", deadlines[a], "Record", C.MIN_REWARD);
        subsidised[a] = false;
        ++rotations;
    }

    function assertLedger() external view {
        for (uint256 p; p < 2; ++p) {
            assertEq(pools[p].totalDeposited(), credited[p], "credited inflows");
            assertEq(pools[p].totalReleased(), released[p], "actual grants");
            assertEq(pools[p].available(), credited[p] - released[p], "spendable balance");
            assertEq(credited[p] + uncredited[p], received[p], "a transfer was counted twice or lost");
            assertEq(token.balanceOf(address(pools[p])) + released[p], received[p], "token conservation");
            assertLe(released[p], credited[p], "grants cannot spend uncredited transfers");
        }
        for (uint256 a; a < 4; ++a) {
            assertEq(bootstrap.bootstrapped(actors[a]), bootstrapped[a]);
            assertEq(subsidy.subsidised(openIds[a]), subsidised[a]);
            assertEq(
                stake.stakeOf(address(bounty), actors[a]),
                C.RESOLVER_STAKE + (bootstrapped[a] ? C.BOOTSTRAP_AMOUNT : 0),
                "bootstrap must credit the resolver, never the triggering caller"
            );
        }
    }
}

contract DonationLedgerInvariantTest is StdInvariant, ProtocolTestBase {
    DonationLedgerHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[4] memory actors = [creator, alice, bob, carol];
        uint256[4] memory resolved;
        uint256[4] memory open;
        for (uint256 a; a < 4; ++a) {
            uint256 id = _createAs(actors[a]);
            _forecast(id, challenger, int256(a));
            vm.prank(actors[a]);
            stake.deposit(address(bounty), C.RESOLVER_STAKE);
            vm.warp(bounty.getBounty(id).deadline);
            vm.prank(actors[a]);
            bounty.resolve(id, int256(a));
            _finalize(id);
            resolved[a] = id;
        }
        for (uint256 a; a < 4; ++a) {
            open[a] = _createAs(actors[a]);
        }
        handler = new DonationLedgerHandler(token, bounty, subsidy, bootstrap, actors, open, resolved);
        // Begin with both available funds and unsynced surplus; neither pool is vacuous.
        handler.deposit(0, 0, 2 * C.SUBSIDY_AMOUNT);
        handler.deposit(1, 1, 2 * C.BOOTSTRAP_AMOUNT - 1);
        handler.transferDirectly(0, 2, 1);
        handler.transferDirectly(1, 3, 1);
        handler.subsidize(0);
        handler.bootstrapResolver(0, 1);
        targetContract(address(handler));
        targetSender(address(this));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.transferDirectly.selector;
        selectors[2] = handler.sync.selector;
        selectors[3] = handler.subsidize.selector;
        selectors[4] = handler.bootstrapResolver.selector;
        selectors[5] = handler.replaceOpenBounty.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariantDonationsCannotBeDoubleCreditedOrReleasedWithoutBacking() public view {
        handler.assertLedger();
    }
}
