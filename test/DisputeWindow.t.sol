// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {ForecastBounty} from "../src/ForecastBounty.sol";
import {BountyRegistry} from "../src/BountyRegistry.sol";
import {ResolverStake} from "../src/ResolverStake.sol";
import {DisputeWindow} from "../src/DisputeWindow.sol";
import {TokenPool} from "../src/lib/TokenPool.sol";
import {DeploymentConfig as C} from "../src/DeploymentConfig.sol";

contract DisputeWindowTest is ProtocolTestBase {
    function testImmutableSignersRejectAllDuplicatesAndZeroPositions() public {
        address[3] memory signers = [C.disputeSigner1, C.disputeSigner2, C.disputeSigner3];
        for (uint256 i; i < 3; ++i) {
            address previous = signers[i];
            signers[i] = address(0);
            vm.expectRevert(TokenPool.ZeroAddress.selector);
            new DisputeWindow(address(token), C.BOND, C.DISPUTE_WINDOW, signers[0], signers[1], signers[2]);
            signers[i] = previous;
        }
        vm.expectRevert(DisputeWindow.DuplicateSigner.selector);
        new DisputeWindow(address(token), C.BOND, C.DISPUTE_WINDOW, signers[0], signers[0], signers[2]);
        vm.expectRevert(DisputeWindow.DuplicateSigner.selector);
        new DisputeWindow(address(token), C.BOND, C.DISPUTE_WINDOW, signers[0], signers[1], signers[0]);
        vm.expectRevert(DisputeWindow.DuplicateSigner.selector);
        new DisputeWindow(address(token), C.BOND, C.DISPUTE_WINDOW, signers[0], signers[1], signers[1]);
        assertEq(disputes.signer1(), signers[0]);
        assertEq(disputes.signer2(), signers[1]);
        assertEq(disputes.signer3(), signers[2]);
    }

    function testSuccessfulDisputeCorrectsWinnerSlashesAndPaysEqualBonds() public {
        uint256 id = _resolved();
        _challenge(id, 21);
        assertEq(uint8(bounty.getBounty(id).state), uint8(BountyRegistry.State.Disputed));
        assertEq(uint8(registry.getRecord(address(bounty), id).state), uint8(BountyRegistry.State.Disputed));
        assertEq(token.balanceOf(challenger), ALLOCATION - C.BOND);
        _vote(id, C.disputeSigner1, true);
        vm.prank(alice);
        vm.expectRevert(DisputeWindow.WindowOpen.selector);
        bounty.claim(id);
        vm.prank(creator);
        vm.expectRevert(ResolverStake.StakeLocked.selector);
        stake.withdraw(address(bounty), 1);
        // Participant bonds stay refundable while the panel considers the dispute.
        vm.prank(carol);
        bounty.withdrawBond(id);
        assertEq(token.balanceOf(carol), ALLOCATION);
        _vote(id, C.disputeSigner2, true);
        assertEq(uint8(disputes.getCase(address(bounty), id).outcome), uint8(DisputeWindow.Outcome.Overturned));
        bounty.finalize(id);
        assertEq(bounty.getBounty(id).trueValue, 21);
        assertEq(bounty.getBounty(id).winner, bob);
        assertTrue(bounty.getBounty(id).resolutionOverturned);
        assertEq(stake.stakeOf(address(bounty), creator), 20_000e18);
        assertEq(token.balanceOf(challenger), ALLOCATION - C.BOND + 5_000e18);
        assertEq(disputes.credit(challenger), 2 * C.BOND);
        vm.prank(challenger);
        disputes.withdrawPayout();
        assertEq(token.balanceOf(challenger), ALLOCATION + C.BOND + 5_000e18);
        vm.prank(alice);
        vm.expectRevert(ForecastBounty.NotWinner.selector);
        bounty.claim(id);
        vm.prank(bob);
        bounty.claim(id);
        vm.prank(alice);
        bounty.withdrawBond(id);
        vm.prank(bob);
        bounty.withdrawBond(id);
        assertEq(token.balanceOf(alice), ALLOCATION);
        assertEq(token.balanceOf(bob), ALLOCATION + C.MIN_REWARD);
        vm.prank(creator);
        stake.withdraw(address(bounty), 20_000e18);
        assertEq(token.balanceOf(creator), ALLOCATION - C.MIN_REWARD - C.BOND - 5_000e18);
        assertEq(registry.historyLength(address(bounty), id), 4);
        assertEq(registry.getTransition(address(bounty), id, 1).resolutionValue, 11);
        assertEq(registry.getTransition(address(bounty), id, 3).resolutionValue, 21);
        _assertSolvent();
    }

    function testRejectedDisputePaysResolverAndDoesNotSlash() public {
        uint256 id = _resolved();
        _challenge(id, 21);
        _vote(id, C.disputeSigner1, true);
        _vote(id, C.disputeSigner2, false);
        assertEq(uint8(disputes.getCase(address(bounty), id).outcome), uint8(DisputeWindow.Outcome.Pending));
        _vote(id, C.disputeSigner3, false);
        bounty.finalize(id);
        assertEq(bounty.getBounty(id).winner, alice);
        assertEq(stake.stakeOf(address(bounty), creator), C.RESOLVER_STAKE);
        assertFalse(bounty.getBounty(id).resolutionOverturned);
        assertEq(disputes.credit(creator), 2 * C.BOND);
        assertEq(disputes.credit(challenger), 0);
        vm.prank(creator);
        disputes.withdrawPayout();
        vm.prank(creator);
        vm.expectRevert(DisputeWindow.NoCredit.selector);
        disputes.withdrawPayout();
        vm.prank(challenger);
        vm.expectRevert(DisputeWindow.NoCredit.selector);
        disputes.withdrawPayout();
        _assertSolvent();
    }

    function testFalseFirstChallengeCannotPreventPanelFromCorrectingActualValue() public {
        uint256 id = _resolved();
        _challenge(id, 9_999);
        vm.prank(C.disputeSigner1);
        disputes.voteValue(address(bounty), id, 21);
        vm.prank(C.disputeSigner2);
        disputes.voteValue(address(bounty), id, 21);
        bounty.finalize(id);
        assertEq(bounty.getBounty(id).trueValue, 21);
        assertEq(bounty.getBounty(id).winner, bob);
        assertEq(disputes.getCase(address(bounty), id).correctedValue, 9_999);
        assertEq(disputes.getCase(address(bounty), id).finalValue, 21);
        assertEq(stake.stakeOf(address(bounty), creator), 20_000e18);
        _assertSolvent();
    }

    function testDifferentCorrectionsRequireTwoVotesForTheSameValue() public {
        uint256 id = _resolved();
        _challenge(id, 21);
        _vote(id, C.disputeSigner1, true);
        vm.prank(C.disputeSigner2);
        disputes.voteValue(address(bounty), id, -10);
        assertEq(disputes.getCase(address(bounty), id).acceptVotes, 2);
        assertEq(uint8(disputes.getCase(address(bounty), id).outcome), uint8(DisputeWindow.Outcome.Pending));
        vm.expectRevert(DisputeWindow.WindowOpen.selector);
        bounty.finalize(id);
        vm.prank(C.disputeSigner3);
        disputes.voteValue(address(bounty), id, -10);
        bounty.finalize(id);
        assertEq(bounty.getBounty(id).trueValue, -10);
        assertEq(bounty.getBounty(id).winner, carol);
        _assertSolvent();
    }

    function testThreeDifferentPanelValuesTimeOutKeepingOriginalResolution() public {
        uint256 id = _resolved();
        _challenge(id, 21);
        _vote(id, C.disputeSigner1, true);
        _vote(id, C.disputeSigner2, false);
        vm.prank(C.disputeSigner3);
        disputes.voteValue(address(bounty), id, -10);
        vm.warp(disputes.getCase(address(bounty), id).panelEndsAt);
        bounty.finalize(id);
        assertEq(uint8(bounty.getBounty(id).state), uint8(BountyRegistry.State.Finalized));
        assertEq(bounty.getBounty(id).winner, alice);
        assertEq(stake.stakeOf(address(bounty), creator), C.RESOLVER_STAKE);
        assertEq(disputes.credit(creator), C.BOND);
        assertEq(disputes.credit(challenger), C.BOND);
        _assertSolvent();
    }

    function testOnlyPanelCanVoteOnceAndDecisionCannotBeReplayed() public {
        uint256 id = _resolved();
        _challenge(id, 21);
        vm.prank(challenger);
        vm.expectRevert(DisputeWindow.NotSigner.selector);
        disputes.vote(address(bounty), id, true);
        _vote(id, C.disputeSigner1, true);
        vm.prank(C.disputeSigner1);
        vm.expectRevert(DisputeWindow.AlreadyVoted.selector);
        disputes.vote(address(bounty), id, false);
        _vote(id, C.disputeSigner2, true);
        vm.prank(C.disputeSigner3);
        vm.expectRevert(DisputeWindow.AlreadyDecided.selector);
        disputes.vote(address(bounty), id, false);
        bounty.finalize(id);
        uint256 balance = token.balanceOf(challenger);
        vm.expectRevert(ForecastBounty.AlreadyFinalized.selector);
        bounty.finalize(id);
        assertEq(token.balanceOf(challenger), balance);
        // Idempotent window finalization cannot mint a second credit.
        disputes.finalize(address(bounty), id);
        disputes.finalize(address(bounty), id);
        assertEq(disputes.credit(challenger), 2 * C.BOND);
        _assertSolvent();
    }

    function testChallengeRulesAndBondTransferRollback() public {
        uint256 id = _resolved();
        vm.prank(creator);
        vm.expectRevert(DisputeWindow.InvalidDispute.selector);
        disputes.dispute(address(bounty), id, 21);
        vm.prank(challenger);
        vm.expectRevert(DisputeWindow.InvalidDispute.selector);
        disputes.dispute(address(bounty), id, 11);
        vm.prank(challenger);
        token.approve(address(disputes), 0);
        vm.prank(challenger);
        vm.expectRevert();
        disputes.dispute(address(bounty), id, 21);
        assertEq(disputes.getCase(address(bounty), id).disputer, address(0));
        assertEq(uint8(bounty.getBounty(id).state), uint8(BountyRegistry.State.Resolved));
        vm.prank(challenger);
        token.approve(address(disputes), C.BOND);
        _challenge(id, 21);
        vm.prank(bob);
        vm.expectRevert(DisputeWindow.AlreadyDisputed.selector);
        disputes.dispute(address(bounty), id, 22);
        vm.prank(challenger);
        vm.expectRevert(ForecastBounty.NotDisputeWindow.selector);
        bounty.onDisputed(id);
        _assertSolvent();
    }

    function testExactWindowBoundaryAndNoUnchallengedPanelVote() public {
        uint256 id = _resolved();
        vm.prank(C.disputeSigner1);
        vm.expectRevert(DisputeWindow.NotDisputed.selector);
        disputes.vote(address(bounty), id, true);
        uint256 endsAt = disputes.getCase(address(bounty), id).endsAt;
        vm.warp(endsAt - 1);
        vm.expectRevert(DisputeWindow.WindowOpen.selector);
        bounty.finalize(id);
        vm.warp(endsAt);
        vm.prank(challenger);
        vm.expectRevert(DisputeWindow.WindowClosed.selector);
        disputes.dispute(address(bounty), id, 21);
        bounty.finalize(id);
        assertEq(disputes.credit(creator), C.BOND);
        assertEq(stake.activeLocks(address(bounty), creator), 0);
        _assertSolvent();
    }

    function testLastSecondChallengeExtendsLockUntilPanelDecision() public {
        uint256 id = _resolved();
        uint256 endsAt = disputes.getCase(address(bounty), id).endsAt;
        vm.warp(endsAt - 1);
        _challenge(id, 21);
        vm.warp(endsAt + 1);
        vm.expectRevert(DisputeWindow.WindowOpen.selector);
        bounty.finalize(id);
        vm.prank(creator);
        vm.expectRevert(ResolverStake.StakeLocked.selector);
        stake.withdraw(address(bounty), 1);
        _vote(id, C.disputeSigner1, false);
        _vote(id, C.disputeSigner2, false);
        bounty.finalize(id);
        assertEq(stake.activeLocks(address(bounty), creator), 0);
    }

    function testPanelTimeoutReturnsBondsKeepsWinnerAndReleasesStake() public {
        uint256 id = _resolved();
        _challenge(id, 21);
        _vote(id, C.disputeSigner1, true);
        vm.prank(alice);
        bounty.withdrawBond(id);
        uint256 endsAt = disputes.getCase(address(bounty), id).panelEndsAt;
        vm.warp(endsAt - 1);
        vm.expectRevert(DisputeWindow.WindowOpen.selector);
        bounty.finalize(id);
        vm.warp(endsAt);
        vm.prank(C.disputeSigner2);
        vm.expectRevert(DisputeWindow.PanelExpired.selector);
        disputes.vote(address(bounty), id, true);
        bounty.finalize(id);
        assertEq(uint8(bounty.getBounty(id).state), uint8(BountyRegistry.State.Finalized));
        assertEq(bounty.getBounty(id).winner, alice);
        assertEq(disputes.credit(creator), C.BOND);
        assertEq(disputes.credit(challenger), C.BOND);
        assertEq(stake.stakeOf(address(bounty), creator), C.RESOLVER_STAKE);
        vm.prank(alice);
        bounty.claim(id);
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.RewardAlreadyPaid.selector);
        bounty.refundReward(id);
        vm.prank(creator);
        disputes.withdrawPayout();
        vm.prank(creator);
        stake.withdraw(address(bounty), C.RESOLVER_STAKE);
        vm.prank(challenger);
        disputes.withdrawPayout();
        vm.prank(bob);
        bounty.withdrawBond(id);
        vm.prank(carol);
        bounty.withdrawBond(id);
        assertEq(token.balanceOf(creator), ALLOCATION - C.MIN_REWARD);
        assertEq(token.balanceOf(challenger), ALLOCATION);
        assertEq(token.balanceOf(alice), ALLOCATION + C.MIN_REWARD);
        assertEq(token.balanceOf(bob), ALLOCATION);
        assertEq(token.balanceOf(carol), ALLOCATION);
        _assertSolvent();
    }

    function testFakeMarketCannotSpendResolverApprovalOrAffectCanonicalCase() public {
        uint256 id = _resolved();
        uint256 creatorBalance = token.balanceOf(creator);
        uint256 attackerBalance = token.balanceOf(challenger);
        vm.prank(challenger);
        disputes.open(id, creator, 100);
        assertEq(token.balanceOf(creator), creatorBalance);
        assertEq(token.balanceOf(challenger), attackerBalance - C.BOND);
        assertEq(disputes.getCase(address(bounty), id).originalValue, 11);
        assertEq(disputes.getCase(challenger, id).originalValue, 100);
        vm.prank(challenger);
        vm.expectRevert(DisputeWindow.AlreadyOpened.selector);
        disputes.open(id, creator, 101);
        vm.expectRevert(DisputeWindow.UnknownCase.selector);
        disputes.finalize(alice, id);
        _assertSolvent();
    }

    function testFuzzPanelOrderAlwaysRequiresTwoDistinctVotes(bool a, bool b, bool c, uint8 order) public {
        uint256 id = _resolved();
        _challenge(id, 21);
        address[3] memory signers = [C.disputeSigner1, C.disputeSigner2, C.disputeSigner3];
        uint256 offset = uint256(order) % 3;
        _vote(id, signers[offset], a);
        assertEq(uint8(disputes.getCase(address(bounty), id).outcome), uint8(DisputeWindow.Outcome.Pending));
        _vote(id, signers[(offset + 1) % 3], b);
        if (a != b) _vote(id, signers[(offset + 2) % 3], c);
        bool accepted = a == b ? a : c;
        bounty.finalize(id);
        assertEq(bounty.getBounty(id).winner, accepted ? bob : alice);
        assertEq(stake.stakeOf(address(bounty), creator), accepted ? 20_000e18 : C.RESOLVER_STAKE);
        _assertSolvent();
    }

    function testThirdValueOverturnPaysSlashToCorrectedWinnerNotWrongDisputer() public {
        uint256 id = _resolved();
        _challenge(id, 99);
        vm.prank(C.disputeSigner1);
        disputes.voteValue(address(bounty), id, -9);
        vm.prank(C.disputeSigner2);
        disputes.voteValue(address(bounty), id, -9);
        uint256 carolBefore = token.balanceOf(carol);
        uint256 challengerBefore = token.balanceOf(challenger);
        bounty.finalize(id);
        assertEq(bounty.getBounty(id).winner, carol);
        uint256 slash = (C.RESOLVER_STAKE * C.SLASH_BPS) / 10_000;
        assertEq(token.balanceOf(carol), carolBefore + slash);
        assertEq(token.balanceOf(challenger), challengerBefore);
        assertEq(stake.stakeOf(address(bounty), creator), C.RESOLVER_STAKE - slash);
        _assertSolvent();
    }

    function testSockDisputerCannotRecoverResolverSlash() public {
        uint256 id = _resolved(); // alice 10 wins at 11
        // The resolver's second wallet takes the slot with a bogus value; the panel picks the real one.
        _challenge(id, 1000);
        vm.prank(C.disputeSigner1);
        disputes.voteValue(address(bounty), id, 21);
        vm.prank(C.disputeSigner3);
        disputes.voteValue(address(bounty), id, 21);
        uint256 challengerBefore = token.balanceOf(challenger);
        bounty.finalize(id);
        assertEq(bounty.getBounty(id).winner, bob);
        assertEq(token.balanceOf(challenger), challengerBefore);
        _assertSolvent();
    }
}
