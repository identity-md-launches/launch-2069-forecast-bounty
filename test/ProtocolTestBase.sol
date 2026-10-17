// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ForecastToken} from "../src/ForecastToken.sol";
import {ForecastBounty} from "../src/ForecastBounty.sol";
import {BountyRegistry} from "../src/BountyRegistry.sol";
import {ResolverStake} from "../src/ResolverStake.sol";
import {DisputeWindow} from "../src/DisputeWindow.sol";
import {BountySubsidy} from "../src/BountySubsidy.sol";
import {ResolverBootstrap} from "../src/ResolverBootstrap.sol";
import {TokenPool} from "../src/lib/TokenPool.sol";
import {DonationPool} from "../src/lib/DonationPool.sol";
import {DeploymentConfig as C} from "../src/DeploymentConfig.sol";

abstract contract ProtocolTestBase is Test {
    LaunchToken internal token;
    ForecastBounty internal bounty;
    BountyRegistry internal registry;
    ResolverStake internal stake;
    DisputeWindow internal disputes;
    BountySubsidy internal subsidy;
    ResolverBootstrap internal bootstrap;
    address internal creator;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal challenger;
    uint256 internal constant ALLOCATION = 1_000_000e18;

    function setUp() public virtual {
        creator = makeAddr("creator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        challenger = makeAddr("challenger");
        token = new LaunchToken();
        registry = new BountyRegistry();
        disputes = new DisputeWindow(
            address(token), C.BOND, C.DISPUTE_WINDOW, C.disputeSigner1, C.disputeSigner2, C.disputeSigner3
        );
        stake = new ResolverStake(address(token), C.RESOLVER_STAKE, C.SLASH_BPS);
        bounty = new ForecastBounty(
            address(token), address(registry), address(stake), address(disputes), C.MIN_REWARD, C.BOND, C.MAX_ENTRIES
        );
        subsidy = new BountySubsidy(address(token), address(bounty), C.MIN_REWARD);
        bootstrap = new ResolverBootstrap(address(token), address(bounty), address(stake));
        _fund(creator);
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(challenger);
    }

    function _fund(address who) internal {
        token.transfer(who, ALLOCATION);
        vm.startPrank(who);
        token.approve(address(bounty), ALLOCATION);
        token.approve(address(stake), ALLOCATION);
        token.approve(address(disputes), ALLOCATION);
        token.approve(address(subsidy), ALLOCATION);
        token.approve(address(bootstrap), ALLOCATION);
        vm.stopPrank();
    }

    function _create() internal returns (uint256 id) {
        return _createAs(creator);
    }

    function _createAs(address who) internal returns (uint256 id) {
        vm.prank(who);
        return bounty.createBounty(
            "Temperature in millikelvin?", vm.getBlockTimestamp() + 1 days, "Published station record", C.MIN_REWARD
        );
    }

    function _forecast(uint256 id, address who, int256 value) internal {
        vm.prank(who);
        bounty.forecast(id, value);
    }

    function _stakeCreator() internal {
        vm.prank(creator);
        stake.deposit(address(bounty), C.RESOLVER_STAKE);
    }

    function _resolve(uint256 id, int256 value) internal {
        vm.warp(bounty.getBounty(id).deadline);
        vm.prank(creator);
        bounty.resolve(id, value);
    }

    function _resolved() internal returns (uint256 id) {
        id = _create();
        _forecast(id, alice, 10);
        _forecast(id, bob, 20);
        _forecast(id, carol, -10);
        _stakeCreator();
        _resolve(id, 11);
    }

    function _challenge(uint256 id, int256 corrected) internal {
        vm.prank(challenger);
        disputes.dispute(address(bounty), id, corrected);
    }

    function _vote(uint256 id, address signer, bool accept) internal {
        vm.prank(signer);
        disputes.vote(address(bounty), id, accept);
    }

    function _finalize(uint256 id) internal {
        vm.warp(disputes.getCase(address(bounty), id).endsAt);
        bounty.finalize(id);
    }

    function _assertSolvent() internal view {
        assertEq(token.balanceOf(address(bounty)), bounty.rewardLiability() + bounty.bondLiability());
        assertEq(token.balanceOf(address(stake)), stake.totalStaked());
        assertEq(token.balanceOf(address(disputes)), disputes.totalEscrow() + disputes.totalCredits());
        assertEq(token.balanceOf(address(subsidy)), subsidy.available());
        assertEq(token.balanceOf(address(bootstrap)), bootstrap.available());
        assertEq(subsidy.totalDeposited(), subsidy.available() + subsidy.totalReleased());
        assertEq(bootstrap.totalDeposited(), bootstrap.available() + bootstrap.totalReleased());
    }
}
