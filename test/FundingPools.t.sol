// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {BountySubsidy} from "../src/BountySubsidy.sol";
import {ResolverBootstrap} from "../src/ResolverBootstrap.sol";
import {TokenPool} from "../src/lib/TokenPool.sol";
import {DonationPool} from "../src/lib/DonationPool.sol";
import {DeploymentConfig as C} from "../src/DeploymentConfig.sol";

contract FundingPoolsTest is ProtocolTestBase {
    function testPoolsStartEmptyAndAnyoneCanFundBothWays() public {
        assertEq(subsidy.available(), 0);
        assertEq(bootstrap.available(), 0);
        vm.prank(alice);
        subsidy.deposit(3e18);
        vm.prank(bob);
        bootstrap.deposit(7e18);
        token.transfer(address(subsidy), 2e18);
        token.transfer(address(bootstrap), 11e18);
        vm.prank(challenger);
        subsidy.deposit();
        vm.prank(carol);
        bootstrap.deposit();
        assertEq(subsidy.available(), 5e18);
        assertEq(bootstrap.available(), 18e18);
        assertEq(subsidy.totalDeposited(), 5e18);
        assertEq(bootstrap.totalDeposited(), 18e18);
        vm.expectRevert(TokenPool.ZeroAmount.selector);
        subsidy.deposit();
        vm.expectRevert(TokenPool.ZeroAmount.selector);
        bootstrap.deposit();
        vm.expectRevert(TokenPool.ZeroAmount.selector);
        subsidy.deposit(0);
        vm.expectRevert(TokenPool.ZeroAmount.selector);
        bootstrap.deposit(0);
        _assertSolvent();
    }

    function testSubsidyNeedsFundingAndOnlyCreatorGetsOneGrant() public {
        uint256 id = _create();
        vm.prank(creator);
        vm.expectRevert(DonationPool.InsufficientPool.selector);
        subsidy.subsidize(id);
        assertFalse(subsidy.subsidised(id));
        vm.prank(alice);
        subsidy.deposit(C.SUBSIDY_AMOUNT);
        vm.prank(challenger);
        vm.expectRevert(BountySubsidy.NotCreator.selector);
        subsidy.subsidize(id);
        uint256 before = token.balanceOf(creator);
        vm.prank(creator);
        subsidy.subsidize(id);
        assertEq(token.balanceOf(creator), before + C.SUBSIDY_AMOUNT);
        assertEq(subsidy.available(), 0);
        assertEq(subsidy.totalReleased(), C.SUBSIDY_AMOUNT);
        vm.prank(creator);
        vm.expectRevert(BountySubsidy.AlreadySubsidised.selector);
        subsidy.subsidize(id);
        _assertSolvent();
    }

    function testCreatorCannotHaveTwoSubsidisedOpenBounties() public {
        uint256 id1 = _create();
        uint256 id2 = _create();
        vm.prank(alice);
        subsidy.deposit(3 * C.SUBSIDY_AMOUNT);
        vm.prank(creator);
        subsidy.subsidize(id1);
        vm.prank(creator);
        vm.expectRevert(BountySubsidy.OtherSubsidisedBountyOpen.selector);
        subsidy.subsidize(id2);
        uint256 otherCreatorId = _createAs(bob);
        vm.prank(bob);
        subsidy.subsidize(otherCreatorId);
        _stakeCreator();
        _resolve(id1, 0);
        uint256 id3 = _create();
        vm.prank(creator);
        vm.expectRevert(BountySubsidy.OtherSubsidisedBountyOpen.selector);
        subsidy.subsidize(id3);
        _finalize(id1);
        uint256 id4 = _create();
        vm.prank(creator);
        subsidy.subsidize(id4);
        assertEq(subsidy.openBounty(creator), id4);
        assertEq(subsidy.totalReleased(), 3 * C.SUBSIDY_AMOUNT);
        _assertSolvent();
    }

    function testRefundedBountyReleasesSubsidySlotButNoDuplicateGrant() public {
        uint256 id = _create();
        vm.prank(alice);
        subsidy.deposit(2 * C.SUBSIDY_AMOUNT);
        vm.prank(creator);
        subsidy.subsidize(id);
        vm.warp(bounty.getBounty(id).deadline);
        vm.prank(creator);
        bounty.refundReward(id);
        vm.prank(creator);
        vm.expectRevert(BountySubsidy.IneligibleBounty.selector);
        subsidy.subsidize(id);
        uint256 next = _create();
        vm.prank(creator);
        subsidy.subsidize(next);
        _assertSolvent();
    }

    function testLateSubsidyAndInsufficientPoolCannotPay() public {
        uint256 id = _create();
        vm.prank(alice);
        subsidy.deposit(C.SUBSIDY_AMOUNT - 1);
        vm.prank(creator);
        vm.expectRevert(DonationPool.InsufficientPool.selector);
        subsidy.subsidize(id);
        assertFalse(subsidy.subsidised(id));
        vm.warp(bounty.getBounty(id).deadline);
        vm.prank(creator);
        vm.expectRevert(BountySubsidy.IneligibleBounty.selector);
        subsidy.subsidize(id);
        _assertSolvent();
    }

    function testBootstrapRequiresFinalizationFundingAndCreditsOnlyResolverStake() public {
        uint256 id = _resolved();
        vm.expectRevert(ResolverBootstrap.IneligibleResolver.selector);
        bootstrap.bootstrap(id);
        _finalize(id);
        vm.expectRevert(DonationPool.InsufficientPool.selector);
        bootstrap.bootstrap(id);
        assertFalse(bootstrap.bootstrapped(creator));
        vm.prank(bob);
        bootstrap.deposit(C.BOOTSTRAP_AMOUNT);
        uint256 recipientBalance = token.balanceOf(creator);
        vm.prank(challenger);
        bootstrap.bootstrap(id);
        assertEq(stake.stakeOf(address(bounty), creator), C.RESOLVER_STAKE + C.BOOTSTRAP_AMOUNT);
        assertEq(token.balanceOf(creator), recipientBalance);
        assertEq(token.balanceOf(challenger), ALLOCATION);
        assertEq(token.allowance(address(bootstrap), address(stake)), 0);
        vm.expectRevert(ResolverBootstrap.AlreadyBootstrapped.selector);
        bootstrap.bootstrap(id);
        uint256 second = _create();
        _forecast(second, alice, 0);
        _resolve(second, 0);
        _finalize(second);
        vm.expectRevert(ResolverBootstrap.AlreadyBootstrapped.selector);
        bootstrap.bootstrap(second);
        _assertSolvent();
    }

    function testBootstrapRejectsOverturnedEmptyCancelledAndWithdrawnStake() public {
        uint256 id = _resolved();
        _challenge(id, 21);
        _vote(id, C.disputeSigner1, true);
        _vote(id, C.disputeSigner2, true);
        bounty.finalize(id);
        vm.prank(creator);
        stake.deposit(address(bounty), 5_000e18);
        vm.expectRevert(ResolverBootstrap.IneligibleResolver.selector);
        bootstrap.bootstrap(id);
        uint256 empty = _create();
        _resolve(empty, 0);
        _finalize(empty);
        vm.expectRevert(ResolverBootstrap.IneligibleResolver.selector);
        bootstrap.bootstrap(empty);
        uint256 cancelled = _create();
        vm.warp(bounty.getBounty(cancelled).deadline);
        vm.prank(creator);
        bounty.refundReward(cancelled);
        vm.expectRevert(ResolverBootstrap.IneligibleResolver.selector);
        bootstrap.bootstrap(cancelled);
        uint256 good = _create();
        _forecast(good, alice, 0);
        _resolve(good, 0);
        _finalize(good);
        vm.prank(creator);
        stake.withdraw(address(bounty), 1);
        vm.expectRevert(ResolverBootstrap.IneligibleResolver.selector);
        bootstrap.bootstrap(good);
        _assertSolvent();
    }

    function testNoDonorOrAdminCanWithdrawEitherPool() public {
        vm.prank(creator);
        subsidy.deposit(1e18);
        vm.prank(creator);
        bootstrap.deposit(1e18);
        address[2] memory targets = [address(subsidy), address(bootstrap)];
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(creator);
            (bool success,) = targets[i].call(abi.encodeWithSignature("withdraw(uint256)", 1e18));
            assertFalse(success);
            vm.prank(creator);
            (success,) = targets[i].call(abi.encodeWithSignature("sweep(address)", creator));
            assertFalse(success);
            (success,) = targets[i].call(abi.encodeWithSignature("owner()"));
            assertFalse(success);
        }
        _assertSolvent();
    }

    function testFuzzDepositsCannotBeCreditedTwice(uint96 rawA, uint96 rawB) public {
        uint256 a = bound(rawA, 1, ALLOCATION);
        uint256 b = bound(rawB, 1, ALLOCATION);
        vm.prank(alice);
        subsidy.deposit(a);
        vm.prank(bob);
        token.transfer(address(subsidy), b);
        vm.prank(carol);
        subsidy.deposit();
        vm.expectRevert(TokenPool.ZeroAmount.selector);
        subsidy.deposit();
        assertEq(subsidy.totalDeposited(), a + b);
        _assertSolvent();
    }
}
