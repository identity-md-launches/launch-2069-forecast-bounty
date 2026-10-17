// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {ForecastBounty} from "src/ForecastBounty.sol";
import {ResolverStake} from "src/ResolverStake.sol";
import {DisputeWindow} from "src/DisputeWindow.sol";
import {BountyRegistry} from "src/BountyRegistry.sol";
import {BountySubsidy} from "src/BountySubsidy.sol";
import {ResolverBootstrap} from "src/ResolverBootstrap.sol";
import {DeploymentConfig as C} from "src/DeploymentConfig.sol";

contract ComponentIsolationTest is ProtocolTestBase {
    function testRegistryCompleteTransitionMatrixPreservesHistoryAndOriginalTerms() public {
        for (uint256 previous; previous < 5; ++previous) {
            for (uint256 next; next < 5; ++next) {
                address namespace = makeAddr(string.concat("registry matrix ", vm.toString(previous * 5 + next)));
                vm.startPrank(namespace);
                uint256 id = registry.append(
                    creator, keccak256("original question"), C.MIN_REWARD, vm.getBlockTimestamp() + 1 days
                );
                if (previous == uint256(BountyRegistry.State.Refunded)) {
                    registry.transition(id, BountyRegistry.State.Refunded, 0);
                } else if (previous != uint256(BountyRegistry.State.Open)) {
                    registry.transition(id, BountyRegistry.State.Resolved, -1);
                    if (previous != uint256(BountyRegistry.State.Resolved)) {
                        registry.transition(id, BountyRegistry.State(previous), -2);
                    }
                }
                BountyRegistry.Record memory original = registry.getRecord(namespace, id);
                uint256 length = registry.historyLength(namespace, id);
                bytes32[] memory prefix = new bytes32[](length);
                for (uint256 i; i < length; ++i) {
                    prefix[i] = keccak256(abi.encode(registry.getTransition(namespace, id, i)));
                }
                bool legal = (previous == 0 && (next == 1 || next == 4))
                    || (previous == 1 && (next == 2 || next == 3 || next == 4))
                    || (previous == 2 && (next == 3 || next == 4));
                if (!legal) vm.expectRevert(BountyRegistry.InvalidTransition.selector);
                registry.transition(id, BountyRegistry.State(next), type(int256).min);
                vm.stopPrank();
                BountyRegistry.Record memory afterRecord = registry.getRecord(namespace, id);
                assertEq(registry.count(namespace), 1);
                assertEq(registry.historyLength(namespace, id), length + (legal ? 1 : 0));
                assertEq(afterRecord.id, original.id);
                assertEq(afterRecord.creator, original.creator);
                assertEq(afterRecord.questionHash, original.questionHash);
                assertEq(afterRecord.reward, original.reward);
                assertEq(afterRecord.deadline, original.deadline);
                assertEq(uint8(afterRecord.state), legal ? uint8(next) : uint8(previous));
                assertEq(afterRecord.resolutionValue, legal ? type(int256).min : original.resolutionValue);
                for (uint256 i; i < length; ++i) {
                    assertEq(
                        keccak256(abi.encode(registry.getTransition(namespace, id, i))),
                        prefix[i],
                        "history was rewritten"
                    );
                }
            }
        }
    }

    function testResolutionRejectsForeignAssetOrUnequalArbitrationBondWithoutPartialState() public {
        LaunchToken otherToken = new LaunchToken();
        ResolverStake otherStake = new ResolverStake(address(otherToken), C.RESOLVER_STAKE, C.SLASH_BPS);
        DisputeWindow otherWindow = _window(address(otherToken), C.BOND);
        DisputeWindow unequalBondWindow = _window(address(token), C.BOND + 1);
        ForecastBounty[3] memory markets;
        markets[0] = _market(address(otherStake), address(disputes));
        markets[1] = _market(address(stake), address(otherWindow));
        markets[2] = _market(address(stake), address(unequalBondWindow));
        for (uint256 i; i < markets.length; ++i) {
            ForecastBounty market = markets[i];
            vm.startPrank(creator);
            token.approve(address(market), C.MIN_REWARD + C.BOND);
            uint256 id = market.createBounty("q", vm.getBlockTimestamp() + 1, "s", C.MIN_REWARD);
            vm.stopPrank();
            vm.warp(market.getBounty(id).deadline);
            uint256 beforeBalance = token.balanceOf(creator);
            vm.prank(creator);
            vm.expectRevert(ForecastBounty.ComponentMismatch.selector);
            market.resolve(id, 123);
            ForecastBounty.Bounty memory item = market.getBounty(id);
            assertFalse(item.hasResolved);
            assertEq(uint8(item.state), uint8(BountyRegistry.State.Open));
            assertEq(item.trueValue, 0);
            assertEq(token.balanceOf(creator), beforeBalance);
            assertEq(token.balanceOf(address(market)), C.MIN_REWARD);
            assertEq(market.rewardLiability(), C.MIN_REWARD);
            assertEq(registry.historyLength(address(market), id), 1);
            assertEq(market.resolverStake().activeLocks(address(market), creator), 0);
            DisputeWindow window = market.disputeWindow();
            vm.expectRevert(DisputeWindow.UnknownCase.selector);
            window.getCase(address(market), id);
        }
    }

    function testSubsidyRejectsWrongTokenOrThresholdWithoutConsumingGrant() public {
        uint256 id = _create();
        LaunchToken otherToken = new LaunchToken();
        BountySubsidy foreign = new BountySubsidy(address(otherToken), address(bounty), C.MIN_REWARD);
        BountySubsidy threshold = new BountySubsidy(address(token), address(bounty), C.MIN_REWARD + 1);
        otherToken.approve(address(foreign), C.SUBSIDY_AMOUNT);
        foreign.deposit(C.SUBSIDY_AMOUNT);
        token.approve(address(threshold), C.SUBSIDY_AMOUNT);
        threshold.deposit(C.SUBSIDY_AMOUNT);
        BountySubsidy[2] memory pools = [foreign, threshold];
        for (uint256 i; i < pools.length; ++i) {
            vm.prank(creator);
            vm.expectRevert(BountySubsidy.ComponentMismatch.selector);
            pools[i].subsidize(id);
            assertFalse(pools[i].subsidised(id));
            assertEq(pools[i].openBounty(creator), 0);
            assertEq(pools[i].available(), C.SUBSIDY_AMOUNT);
            assertEq(pools[i].totalReleased(), 0);
        }
    }

    function testBootstrapRejectsWrongAssetOrStakeDestinationWithoutConsumingEligibility() public {
        uint256 id = _resolved();
        _finalize(id);
        LaunchToken otherToken = new LaunchToken();
        ResolverStake otherStake = new ResolverStake(address(otherToken), C.RESOLVER_STAKE, C.SLASH_BPS);
        ResolverStake alternateStake = new ResolverStake(address(token), C.RESOLVER_STAKE, C.SLASH_BPS);
        ResolverBootstrap[3] memory pools;
        pools[0] = new ResolverBootstrap(address(otherToken), address(bounty), address(stake));
        pools[1] = new ResolverBootstrap(address(token), address(bounty), address(otherStake));
        pools[2] = new ResolverBootstrap(address(token), address(bounty), address(alternateStake));
        otherToken.approve(address(pools[0]), C.BOOTSTRAP_AMOUNT);
        pools[0].deposit(C.BOOTSTRAP_AMOUNT);
        for (uint256 i = 1; i < pools.length; ++i) {
            token.approve(address(pools[i]), C.BOOTSTRAP_AMOUNT);
            pools[i].deposit(C.BOOTSTRAP_AMOUNT);
        }
        for (uint256 i; i < pools.length; ++i) {
            vm.prank(challenger);
            vm.expectRevert(ResolverBootstrap.ComponentMismatch.selector);
            pools[i].bootstrap(id);
            assertFalse(pools[i].bootstrapped(creator));
            assertEq(pools[i].available(), C.BOOTSTRAP_AMOUNT);
            assertEq(pools[i].totalReleased(), 0);
        }
        assertEq(stake.stakeOf(address(bounty), creator), C.RESOLVER_STAKE);
        assertEq(otherStake.totalStaked(), 0);
        assertEq(alternateStake.totalStaked(), 0);
    }

    function testTwoRealMarketsShareComponentsButNeverForecastsStakeOrCases() public {
        ForecastBounty second = _market(address(stake), address(disputes));
        uint256 firstId = _create();
        _forecast(firstId, alice, 11);
        vm.startPrank(creator);
        token.approve(address(second), C.MIN_REWARD + C.BOND);
        uint256 secondId =
            second.createBounty("different question", bounty.getBounty(firstId).deadline, "s", C.MIN_REWARD);
        vm.stopPrank();
        assertEq(firstId, secondId, "ids are independently allocated");
        vm.startPrank(alice);
        token.approve(address(second), C.BOND);
        second.forecast(secondId, -99);
        vm.stopPrank();
        _stakeCreator();
        _resolve(firstId, 11);
        vm.prank(creator);
        vm.expectRevert(ResolverStake.InsufficientStake.selector);
        second.resolve(secondId, -99);
        assertFalse(second.getBounty(secondId).hasResolved);
        vm.expectRevert(ForecastBounty.ForecastsHidden.selector);
        second.forecastOf(secondId, alice);
        vm.prank(creator);
        stake.deposit(address(second), C.RESOLVER_STAKE);
        vm.prank(creator);
        second.resolve(secondId, -99);
        assertEq(bounty.forecastOf(firstId, alice), 11);
        assertEq(second.forecastOf(secondId, alice), -99);
        assertEq(registry.count(address(bounty)), 1);
        assertEq(registry.count(address(second)), 1);
        assertEq(registry.getRecord(address(bounty), firstId).questionHash, keccak256("Temperature in millikelvin?"));
        assertEq(registry.getRecord(address(second), secondId).questionHash, keccak256("different question"));
        _challenge(firstId, 12);
        assertEq(disputes.getCase(address(second), secondId).disputer, address(0));
        _vote(firstId, C.disputeSigner1, true);
        _vote(firstId, C.disputeSigner2, true);
        bounty.finalize(firstId);
        assertEq(stake.stakeOf(address(bounty), creator), 20_000e18);
        assertEq(stake.stakeOf(address(second), creator), C.RESOLVER_STAKE);
        assertEq(stake.activeLocks(address(second), creator), 1);
        vm.warp(disputes.getCase(address(second), secondId).endsAt);
        second.finalize(secondId);
        vm.prank(creator);
        stake.withdraw(address(second), C.RESOLVER_STAKE);
        assertEq(stake.activeLocks(address(bounty), creator), 0);
        assertEq(stake.activeLocks(address(second), creator), 0);
        assertEq(disputes.credit(creator), C.BOND);
        assertEq(disputes.credit(challenger), 2 * C.BOND);
    }

    function _window(address asset, uint256 bond) private returns (DisputeWindow) {
        return new DisputeWindow(asset, bond, C.DISPUTE_WINDOW, C.disputeSigner1, C.disputeSigner2, C.disputeSigner3);
    }

    function _market(address stake_, address window_) private returns (ForecastBounty) {
        return
            new ForecastBounty(address(token), address(registry), stake_, window_, C.MIN_REWARD, C.BOND, C.MAX_ENTRIES);
    }
}
