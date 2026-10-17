// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {ForecastBounty} from "../src/ForecastBounty.sol";
import {BountyRegistry} from "../src/BountyRegistry.sol";
import {ResolverStake} from "../src/ResolverStake.sol";
import {DisputeWindow} from "../src/DisputeWindow.sol";
import {DeploymentConfig as C} from "../src/DeploymentConfig.sol";

contract ForecastBountyTest is ProtocolTestBase {
    function testCreateEscrowsAndIndexesImmutableTerms() public {
        uint256 id = _create();
        ForecastBounty.Bounty memory item = bounty.getBounty(id);
        BountyRegistry.Record memory record = registry.getRecord(address(bounty), id);
        assertEq(id, 1);
        assertEq(item.creator, creator);
        assertEq(item.reward, C.MIN_REWARD);
        assertEq(item.deadline, vm.getBlockTimestamp() + 1 days);
        assertEq(record.questionHash, keccak256(bytes(item.question)));
        assertEq(record.creator, creator);
        assertEq(record.reward, item.reward);
        assertEq(record.deadline, item.deadline);
        assertEq(token.balanceOf(creator), ALLOCATION - C.MIN_REWARD);
        assertEq(registry.historyLength(address(bounty), id), 1);
        _assertSolvent();
    }

    function testCreateRejectsBadTermsAndUnfundedReward() public {
        vm.startPrank(creator);
        vm.expectRevert(ForecastBounty.InvalidDeadline.selector);
        bounty.createBounty("q", vm.getBlockTimestamp(), "s", C.MIN_REWARD);
        vm.expectRevert(ForecastBounty.InvalidDeadline.selector);
        bounty.createBounty("q", type(uint256).max, "s", C.MIN_REWARD);
        vm.expectRevert(ForecastBounty.RewardTooSmall.selector);
        bounty.createBounty("q", vm.getBlockTimestamp() + 1, "s", C.MIN_REWARD - 1);
        vm.expectRevert(ForecastBounty.EmptyQuestion.selector);
        bounty.createBounty("", vm.getBlockTimestamp() + 1, "s", C.MIN_REWARD);
        vm.expectRevert(ForecastBounty.EmptySource.selector);
        bounty.createBounty("q", vm.getBlockTimestamp() + 1, "", C.MIN_REWARD);
        token.approve(address(bounty), 0);
        vm.expectRevert();
        bounty.createBounty("q", vm.getBlockTimestamp() + 1, "s", C.MIN_REWARD);
        vm.stopPrank();
        assertEq(bounty.bountyCount(), 0);
        assertEq(registry.count(address(bounty)), 0);
        _assertSolvent();
    }

    function testForecastPrivacyDuplicateAndDeadline() public {
        uint256 id = _create();
        vm.recordLogs();
        _forecast(id, alice, -123456789);
        // Token transfer and ForecastSubmitted contain no submitted value.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(bounty)) assertEq(logs[i].data.length, 0);
        }
        assertEq(bounty.entryCount(id), 1);
        assertTrue(bounty.hasForecast(id, alice));
        vm.expectRevert(ForecastBounty.ForecastsHidden.selector);
        bounty.forecastOf(id, alice);
        vm.expectRevert(ForecastBounty.ForecastsHidden.selector);
        bounty.entryAt(id, 0);
        vm.prank(alice);
        vm.expectRevert(ForecastBounty.AlreadyForecast.selector);
        bounty.forecast(id, 1);
        vm.warp(bounty.getBounty(id).deadline);
        vm.prank(bob);
        vm.expectRevert(ForecastBounty.EntriesClosed.selector);
        bounty.forecast(id, 1);
        assertEq(token.balanceOf(alice), ALLOCATION - C.BOND);
        _assertSolvent();
    }

    function testUnknownAndUnfundedForecastRollback() public {
        vm.expectRevert(ForecastBounty.UnknownBounty.selector);
        bounty.forecast(77, 1);
        uint256 id = _create();
        vm.prank(alice);
        token.approve(address(bounty), 0);
        vm.prank(alice);
        vm.expectRevert();
        bounty.forecast(id, 1);
        assertFalse(bounty.hasForecast(id, alice));
        assertEq(bounty.entryCount(id), 0);
        _assertSolvent();
    }

    function testResolveRequiresCreatorDeadlineStakeAndBond() public {
        uint256 id = _create();
        _forecast(id, alice, 100);
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.BeforeDeadline.selector);
        bounty.resolve(id, 100);
        vm.warp(bounty.getBounty(id).deadline);
        vm.prank(alice);
        stake.deposit(address(bounty), C.RESOLVER_STAKE);
        vm.prank(alice);
        vm.expectRevert(ForecastBounty.NotCreator.selector);
        bounty.resolve(id, 100);
        vm.prank(creator);
        vm.expectRevert(ResolverStake.InsufficientStake.selector);
        bounty.resolve(id, 100);
        vm.prank(creator);
        stake.deposit(address(bounty), C.RESOLVER_STAKE - 1);
        vm.prank(creator);
        vm.expectRevert(ResolverStake.InsufficientStake.selector);
        bounty.resolve(id, 100);
        vm.prank(creator);
        stake.deposit(address(bounty), 1);
        vm.prank(creator);
        token.approve(address(bounty), 0);
        vm.prank(creator);
        vm.expectRevert();
        bounty.resolve(id, 100);
        assertFalse(bounty.getBounty(id).hasResolved);
        assertEq(stake.activeLocks(address(bounty), creator), 0);
        vm.prank(creator);
        token.approve(address(bounty), C.BOND);
        _resolve(id, 100);
        assertEq(bounty.forecastOf(id, alice), 100);
        assertEq(bounty.getBounty(id).winner, alice);
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.NotOpen.selector);
        bounty.resolve(id, 100);
        _assertSolvent();
    }

    function testWinnerClaimsOnlyAfterWindowAndEveryBondIsRefunded() public {
        uint256 id = _resolved();
        assertEq(bounty.getBounty(id).winner, alice);
        vm.prank(alice);
        vm.expectRevert(DisputeWindow.WindowOpen.selector);
        bounty.claim(id);
        vm.prank(bob);
        bounty.withdrawBond(id);
        vm.prank(alice);
        bounty.withdrawBond(id);
        vm.prank(carol);
        bounty.withdrawBond(id);
        assertEq(token.balanceOf(alice), ALLOCATION);
        assertEq(token.balanceOf(bob), ALLOCATION);
        assertEq(token.balanceOf(carol), ALLOCATION);
        vm.prank(bob);
        vm.expectRevert(ForecastBounty.AlreadyWithdrawn.selector);
        bounty.withdrawBond(id);
        vm.prank(challenger);
        vm.expectRevert(ForecastBounty.NoForecast.selector);
        bounty.withdrawBond(id);
        vm.warp(disputes.getCase(address(bounty), id).endsAt);
        vm.prank(bob);
        vm.expectRevert(ForecastBounty.NotWinner.selector);
        bounty.claim(id);
        // A reverted losing claim cannot consume finalization or the reward.
        vm.prank(alice);
        bounty.claim(id);
        assertEq(token.balanceOf(alice), ALLOCATION + C.MIN_REWARD);
        vm.prank(alice);
        vm.expectRevert(ForecastBounty.RewardAlreadyPaid.selector);
        bounty.claim(id);
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.RewardAlreadyPaid.selector);
        bounty.refundReward(id);
        vm.prank(creator);
        disputes.withdrawPayout();
        vm.prank(creator);
        stake.withdraw(address(bounty), C.RESOLVER_STAKE);
        assertEq(token.balanceOf(creator), ALLOCATION - C.MIN_REWARD);
        assertEq(token.balanceOf(address(bounty)), 0);
        _assertSolvent();
    }

    function testCreatorCanRefundUnresolvedAtDeadlineAndBondsRemainWhole() public {
        uint256 id = _create();
        _forecast(id, alice, 0);
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.BeforeDeadline.selector);
        bounty.refundReward(id);
        vm.prank(alice);
        vm.expectRevert(ForecastBounty.NotResolved.selector);
        bounty.withdrawBond(id);
        vm.warp(bounty.getBounty(id).deadline);
        vm.prank(alice);
        vm.expectRevert(ForecastBounty.NotCreator.selector);
        bounty.refundReward(id);
        vm.prank(creator);
        bounty.refundReward(id);
        vm.prank(alice);
        bounty.withdrawBond(id);
        assertEq(token.balanceOf(creator), ALLOCATION);
        assertEq(token.balanceOf(alice), ALLOCATION);
        assertTrue(bounty.isClosed(id));
        vm.expectRevert(ForecastBounty.ForecastsHidden.selector);
        bounty.forecastOf(id, alice);
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.NotOpen.selector);
        bounty.resolve(id, 0);
        _assertSolvent();
    }

    function testSilentCreatorCannotLockParticipantBondForever() public {
        uint256 id = _create();
        _forecast(id, alice, 0);
        vm.warp(bounty.getBounty(id).deadline + C.RESOLUTION_TIMEOUT - 1);
        vm.expectRevert(ForecastBounty.NotExpired.selector);
        bounty.expire(id);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.ResolutionExpired.selector);
        bounty.resolve(id, 0);
        vm.prank(alice);
        bounty.withdrawBond(id);
        assertTrue(bounty.isClosed(id));
        vm.prank(creator);
        bounty.refundReward(id);
        _assertSolvent();
    }

    function testPermissionlessExpiryAndDuplicateFinalizationFailSafely() public {
        uint256 id = _create();
        vm.warp(bounty.getBounty(id).deadline + C.RESOLUTION_TIMEOUT);
        vm.prank(challenger);
        bounty.expire(id);
        vm.expectRevert(ForecastBounty.NotOpen.selector);
        bounty.expire(id);
        vm.expectRevert(ForecastBounty.AlreadyFinalized.selector);
        bounty.finalize(id);
        vm.prank(creator);
        bounty.refundReward(id);
        _assertSolvent();
    }

    function testResolvedEmptyBountyRefundsWithoutTakingAnyBonds() public {
        uint256 id = _create();
        _stakeCreator();
        _resolve(id, 123);
        assertEq(bounty.getBounty(id).winner, address(0));
        vm.prank(creator);
        bounty.refundReward(id);
        assertEq(token.balanceOf(address(bounty)), 0);
        vm.prank(creator);
        vm.expectRevert(ResolverStake.StakeLocked.selector);
        stake.withdraw(address(bounty), 1);
        _finalize(id);
        vm.prank(creator);
        disputes.withdrawPayout();
        vm.prank(creator);
        stake.withdraw(address(bounty), C.RESOLVER_STAKE);
        assertEq(token.balanceOf(creator), ALLOCATION);
        _assertSolvent();
    }

    function testCannotRefundResolvedBountyWithEntries() public {
        uint256 id = _resolved();
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.NotRefundable.selector);
        bounty.refundReward(id);
        _finalize(id);
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.NotRefundable.selector);
        bounty.refundReward(id);
        vm.expectRevert(ForecastBounty.AlreadyFinalized.selector);
        bounty.finalize(id);
    }

    function testTieGoesToFirstSubmissionAndSignedExtremesWork() public {
        uint256 id = _create();
        _forecast(id, alice, -1);
        _forecast(id, bob, 1);
        _stakeCreator();
        _resolve(id, 0);
        assertEq(bounty.getBounty(id).winner, alice);
        _finalize(id);
        uint256 extreme = _create();
        _forecast(extreme, alice, type(int256).min);
        _forecast(extreme, bob, type(int256).max);
        _resolve(extreme, type(int256).max);
        assertEq(bounty.getBounty(extreme).winner, bob);
        assertEq(bounty.entryAt(extreme, 0).value, type(int256).min);
        assertEq(bounty.entryAt(extreme, 1).value, type(int256).max);
    }

    function testMaximumEntriesSinglePassRemainsBounded() public {
        uint256 id = _create();
        for (uint256 i; i < C.MAX_ENTRIES; ++i) {
            address who = address(uint160(0x100000 + i));
            token.transfer(who, C.BOND);
            vm.startPrank(who);
            token.approve(address(bounty), C.BOND);
            bounty.forecast(id, int256(i));
            vm.stopPrank();
        }
        vm.prank(alice);
        vm.expectRevert(ForecastBounty.MaxEntries.selector);
        bounty.forecast(id, 500);
        _stakeCreator();
        vm.warp(bounty.getBounty(id).deadline);
        vm.prank(creator);
        uint256 beforeGas = gasleft();
        bounty.resolve(id, 499);
        uint256 resolutionGas = beforeGas - gasleft();
        assertLt(resolutionGas, 8_000_000);
        assertEq(bounty.getBounty(id).winner, address(uint160(0x100000 + 499)));
        _assertSolvent();
    }

    function testFuzzClosestSignedValue(int256 first, int256 second, int256 truth) public {
        uint256 id = _create();
        _forecast(id, alice, first);
        _forecast(id, bob, second);
        _stakeCreator();
        _resolve(id, truth);
        uint256 a = _distance(first, truth);
        uint256 b = _distance(second, truth);
        assertEq(bounty.getBounty(id).winner, a <= b ? alice : bob);
        _assertSolvent();
    }

    // Independent reference: subtraction modulo 2^256 yields the exact nonnegative signed distance.
    function _distance(int256 a, int256 b) private pure returns (uint256 distance) {
        unchecked {
            return a >= b ? uint256(a) - uint256(b) : uint256(b) - uint256(a);
        }
    }
}
