// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {ForecastBounty} from "src/ForecastBounty.sol";
import {BountyRegistry} from "src/BountyRegistry.sol";
import {DisputeWindow} from "src/DisputeWindow.sol";
import {DeploymentConfig as C} from "src/DeploymentConfig.sol";

contract LifecyclePropertiesTest is ProtocolTestBase {
    /// @notice All participants recover their entire bond, regardless of forecast, payout order,
    /// or panel outcome. Only reward and resolution/dispute collateral can change final wealth.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFiveEntrantsAllBondsRecoverAndFinalWealthIsConserved(
        int256[5] memory values,
        int256 proposed,
        int256 corrected,
        uint96 rawReward,
        uint8 rawOutcome,
        uint8 rotation
    ) public {
        uint256 reward = bound(rawReward, C.MIN_REWARD, ALLOCATION / 2);
        uint256 outcome = uint256(rawOutcome) % 4; // uncontested, upheld, overturned, panel timeout
        if (corrected == proposed) corrected = ~proposed;
        address[5] memory entrants = [creator, alice, bob, carol, challenger];
        vm.prank(creator);
        uint256 id = bounty.createBounty("A signed numeric observation?", vm.getBlockTimestamp() + 1, "record", reward);
        for (uint256 i; i < 5; ++i) {
            _forecast(id, entrants[i], values[i]);
            vm.expectRevert(ForecastBounty.ForecastsHidden.selector);
            bounty.forecastOf(id, entrants[i]);
            vm.prank(entrants[i]);
            vm.expectRevert(ForecastBounty.NotResolved.selector);
            bounty.withdrawBond(id);
        }
        _stakeCreator();
        _resolve(id, proposed);
        _assertWinner(id, entrants, values, proposed);
        // Withdraw two bonds before any challenge, two while it is pending, and one after closing.
        _withdrawRotated(id, entrants, rotation, 0, 2);
        if (outcome != 0) _challenge(id, corrected);
        _withdrawRotated(id, entrants, rotation, 2, 4);
        if (outcome == 0) {
            vm.warp(disputes.getCase(address(bounty), id).endsAt);
        } else if (outcome == 3) {
            // A single vote is insufficient, even when it proposes a different winning entry.
            _vote(id, C.disputeSigner1, true);
            vm.warp(disputes.getCase(address(bounty), id).panelEndsAt);
        } else {
            _vote(id, C.disputeSigner1, outcome == 2);
            _vote(id, C.disputeSigner3, outcome == 2);
        }
        bounty.finalize(id);
        _withdrawRotated(id, entrants, rotation, 4, 5);
        ForecastBounty.Bounty memory item = bounty.getBounty(id);
        // A panel without quorum leaves the original resolution standing; it never voids the winner.
        assertEq(uint8(item.state), uint8(BountyRegistry.State.Finalized));
        int256 truth = outcome == 2 ? corrected : proposed;
        _assertWinner(id, entrants, values, truth);
        assertEq(item.trueValue, truth);
        vm.prank(creator);
        vm.expectRevert(ForecastBounty.NotRefundable.selector);
        bounty.refundReward(id);
        vm.prank(item.winner);
        bounty.claim(id);
        // Credits may accumulate independently of reward/bond withdrawal.
        if (outcome != 2) {
            vm.prank(creator);
            disputes.withdrawPayout();
        }
        if (outcome == 2 || outcome == 3) {
            vm.prank(challenger);
            disputes.withdrawPayout();
        }
        uint256 penalty = outcome == 2 ? C.RESOLVER_STAKE / 5 : 0;
        vm.prank(creator);
        stake.withdraw(address(bounty), C.RESOLVER_STAKE - penalty);
        for (uint256 i; i < 5; ++i) {
            uint256 expected = ALLOCATION;
            if (entrants[i] == creator) expected -= reward;
            if (entrants[i] == item.winner) expected += reward;
            if (outcome == 1) {
                if (entrants[i] == creator) expected += C.BOND;
                if (entrants[i] == challenger) expected -= C.BOND;
            } else if (outcome == 2) {
                if (entrants[i] == creator) expected -= penalty + C.BOND;
                if (entrants[i] == challenger) expected += penalty + C.BOND;
            }
            assertEq(token.balanceOf(entrants[i]), expected, "participant wealth differs from economic obligation");
            vm.prank(entrants[i]);
            vm.expectRevert(ForecastBounty.AlreadyWithdrawn.selector);
            bounty.withdrawBond(id);
        }
        assertEq(token.balanceOf(address(bounty)), 0);
        assertEq(token.balanceOf(address(stake)), 0);
        assertEq(token.balanceOf(address(disputes)), 0);
        _assertSolvent();
    }

    /// @notice An overturned resolution is always slashed by exactly SLASH_BPS of the required stake, the slash
    /// never returns to the resolver, and it goes to the disputer when the panel agreed with the disputer, otherwise
    /// to the forecaster who wins under the panel's value (falling back to the disputer when that is the resolver
    /// or nobody). Small values make ties, creator wins and panel-equals-disputer decisions frequent.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzzOverturnSlashRoutingAndConservation(
        int8[4] memory raw,
        uint8 entrantMask,
        int8 rawProposed,
        int8 rawCorrected,
        int8 rawPanel
    ) public {
        int256 proposed = rawProposed;
        int256 corrected = rawCorrected == rawProposed ? proposed + 1 : int256(rawCorrected);
        int256 panel = rawPanel == rawProposed ? corrected : int256(rawPanel);
        address[4] memory who = [creator, alice, bob, challenger];
        uint256 id = _create();
        for (uint256 i; i < 4; ++i) {
            if (entrantMask & (1 << i) != 0) _forecast(id, who[i], raw[i]);
        }
        _stakeCreator();
        _resolve(id, proposed);
        _challenge(id, corrected);
        uint256[4] memory before;
        for (uint256 i; i < 4; ++i) {
            before[i] = token.balanceOf(who[i]);
        }
        uint256 supplyHeld = _held();
        vm.prank(C.disputeSigner2);
        disputes.voteValue(address(bounty), id, panel);
        vm.prank(C.disputeSigner3);
        disputes.voteValue(address(bounty), id, panel);
        bounty.finalize(id);

        _assertOverturnRouting(id, raw, entrantMask, who, before, supplyHeld, corrected, panel);
    }

    function _assertOverturnRouting(
        uint256 id,
        int8[4] memory raw,
        uint8 entrantMask,
        address[4] memory who,
        uint256[4] memory before,
        uint256 supplyHeld,
        int256 corrected,
        int256 panel
    ) private view {
        ForecastBounty.Bounty memory item = bounty.getBounty(id);
        assertTrue(item.resolutionOverturned);
        assertEq(item.trueValue, panel);
        address expectedWinner = _closestOf(raw, entrantMask, who, panel);
        assertEq(item.winner, expectedWinner);
        address expectedTo = challenger;
        if (panel != corrected && expectedWinner != address(0) && expectedWinner != creator) {
            expectedTo = expectedWinner;
        }
        uint256 slash = (C.RESOLVER_STAKE * C.SLASH_BPS) / 10_000;
        assertEq(stake.stakeOf(address(bounty), creator), C.RESOLVER_STAKE - slash, "overturn must slash exactly");
        for (uint256 i; i < 4; ++i) {
            uint256 expected = before[i] + (who[i] == expectedTo ? slash : 0);
            assertEq(token.balanceOf(who[i]), expected, "slash paid to the wrong wallet");
        }
        assertEq(disputes.credit(challenger), 2 * C.BOND);
        assertEq(disputes.credit(creator), 0);
        assertEq(_held() + slash, supplyHeld, "slash must leave the protocol only to its recipient");
        _assertSolvent();
    }

    /// @dev Independent check of the corrected winner: closest under the panel value, earliest entry on ties.
    function _closestOf(int8[4] memory raw, uint8 entrantMask, address[4] memory who, int256 truth)
        private
        pure
        returns (address winner)
    {
        uint256 best = type(uint256).max;
        for (uint256 i; i < 4; ++i) {
            if (entrantMask & (1 << i) == 0) continue;
            uint256 err = _error(raw[i], truth);
            if (err < best) (best, winner) = (err, who[i]);
        }
    }

    function testEveryForecastIdenticalIncludingSignedMinimumStillHasAWinner() public {
        uint256 id = _create();
        address[5] memory entrants = [creator, alice, bob, carol, challenger];
        int256[5] memory values;
        for (uint256 i; i < 5; ++i) {
            values[i] = type(int256).min;
            _forecast(id, entrants[i], values[i]);
        }
        _stakeCreator();
        _resolve(id, type(int256).max);
        _assertWinner(id, entrants, values, type(int256).max);
        assertEq(bounty.getBounty(id).winner, creator, "even maximal error ties choose first entry");
        _finalize(id);
        vm.prank(creator);
        bounty.claim(id);
        _withdrawRotated(id, entrants, 0, 0, 5);
        _assertSolvent();
    }

    function testOneWeiShortRewardAndBondAllowancesFailAtomically() public {
        vm.prank(creator);
        token.approve(address(bounty), C.MIN_REWARD - 1);
        vm.prank(creator);
        vm.expectRevert();
        bounty.createBounty("q", vm.getBlockTimestamp() + 1 days, "s", C.MIN_REWARD);
        assertEq(bounty.bountyCount(), 0);
        assertEq(registry.count(address(bounty)), 0);
        assertEq(token.balanceOf(creator), ALLOCATION);
        vm.prank(creator);
        token.approve(address(bounty), C.MIN_REWARD);
        uint256 id = _create();
        vm.prank(alice);
        token.approve(address(bounty), C.BOND - 1);
        vm.prank(alice);
        vm.expectRevert();
        bounty.forecast(id, type(int256).max);
        assertEq(bounty.entryCount(id), 0);
        assertFalse(bounty.hasForecast(id, alice));
        assertEq(token.balanceOf(alice), ALLOCATION);
        vm.prank(alice);
        token.approve(address(bounty), C.BOND);
        _forecast(id, alice, type(int256).min);
        assertEq(bounty.entryCount(id), 1, "a failed forecast must not consume the address slot");
        _assertSolvent();
    }

    function testResolutionEventIncludesTruthAndCorrectIndexedWinner() public {
        uint256 id = _create();
        _forecast(id, alice, -42);
        _stakeCreator();
        vm.warp(bounty.getBounty(id).deadline);
        vm.expectEmit(true, true, false, true, address(bounty));
        emit ForecastBounty.BountyResolved(id, -42, alice);
        vm.prank(creator);
        bounty.resolve(id, -42);
    }

    function _held() private view returns (uint256) {
        return token.balanceOf(address(bounty)) + token.balanceOf(address(stake)) + token.balanceOf(address(disputes));
    }

    function _withdrawRotated(uint256 id, address[5] memory entrants, uint256 rotation, uint256 start, uint256 end)
        private
    {
        for (uint256 i = start; i < end; ++i) {
            address who = entrants[(i + rotation) % 5];
            uint256 beforeBalance = token.balanceOf(who);
            vm.prank(who);
            bounty.withdrawBond(id);
            assertEq(token.balanceOf(who), beforeBalance + C.BOND, "bond must return in full");
        }
    }

    /// @dev Check the optimality condition against every entry, without copying the running-minimum
    /// algorithm or its signed-order XOR transformation. Unchecked modular subtraction is exact
    /// because the nonnegative difference between two int256 values fits in uint256.
    function _assertWinner(uint256 id, address[5] memory entrants, int256[5] memory values, int256 truth) private view {
        address winner = bounty.getBounty(id).winner;
        uint256 winnerIndex = 5;
        for (uint256 i; i < 5; ++i) {
            if (entrants[i] == winner) winnerIndex = i;
            assertEq(bounty.forecastOf(id, entrants[i]), values[i], "revealed value changed");
            ForecastBounty.Entry memory entry = bounty.entryAt(id, i);
            assertEq(entry.forecaster, entrants[i]);
            assertEq(entry.value, values[i]);
        }
        assertLt(winnerIndex, 5, "winner must have submitted a forecast");
        uint256 winningError = _error(values[winnerIndex], truth);
        for (uint256 i; i < 5; ++i) {
            if (i < winnerIndex) assertGt(_error(values[i], truth), winningError, "earlier tied entry must win");
            else assertGe(_error(values[i], truth), winningError, "a closer entry exists");
        }
    }

    function _error(int256 value, int256 truth) private pure returns (uint256) {
        unchecked {
            return value >= truth ? uint256(value) - uint256(truth) : uint256(truth) - uint256(value);
        }
    }
}
