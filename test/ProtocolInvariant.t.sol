// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {ForecastBounty} from "../src/ForecastBounty.sol";
import {BountyRegistry} from "../src/BountyRegistry.sol";
import {ResolverStake} from "../src/ResolverStake.sol";
import {DisputeWindow} from "../src/DisputeWindow.sol";
import {BountySubsidy} from "../src/BountySubsidy.sol";
import {ResolverBootstrap} from "../src/ResolverBootstrap.sol";
import {DeploymentConfig as C} from "../src/DeploymentConfig.sol";

contract ProtocolHandler is Test {
    ForecastBounty internal bounty;
    ResolverStake internal stake;
    DisputeWindow internal disputes;
    BountySubsidy internal subsidy;
    ResolverBootstrap internal bootstrap;
    address[5] internal actors;
    uint256 public successfulActions;

    constructor(ForecastBounty b, BountySubsidy s, ResolverBootstrap r, address[5] memory actors_) {
        bounty = b;
        stake = b.resolverStake();
        disputes = b.disputeWindow();
        subsidy = s;
        bootstrap = r;
        actors = actors_;
    }

    function create(uint256 actor, uint256 duration) external {
        if (bounty.bountyCount() >= 12) return;
        vm.prank(actors[actor % 5]);
        try bounty.createBounty(
            "Invariant question", vm.getBlockTimestamp() + 1 hours + duration % 2 days, "Test record", C.MIN_REWARD
        ) {
            ++successfulActions;
        } catch {}
    }

    function forecast(uint256 rawId, uint256 actor, int256 value) external {
        uint256 id = _id(rawId);
        vm.prank(actors[actor % 5]);
        try bounty.forecast(id, value) {
            ++successfulActions;
        } catch {}
    }

    function depositStake(uint256 actor, uint96 rawAmount) external {
        uint256 amount = uint256(rawAmount) % 50_000e18 + 1;
        vm.prank(actors[actor % 5]);
        try stake.deposit(address(bounty), amount) {
            ++successfulActions;
        } catch {}
    }

    function resolve(uint256 rawId, int256 truth) external {
        uint256 id = _id(rawId);
        address creator = bounty.getBounty(id).creator;
        vm.prank(creator);
        try bounty.resolve(id, truth) {
            ++successfulActions;
        } catch {}
    }

    function challenge(uint256 rawId, uint256 actor, int256 corrected) external {
        uint256 id = _id(rawId);
        vm.prank(actors[actor % 5]);
        try disputes.dispute(address(bounty), id, corrected) {
            ++successfulActions;
        } catch {}
    }

    function vote(uint256 rawId, uint256 signer, bool accept) external {
        uint256 id = _id(rawId);
        address[3] memory panel = [C.disputeSigner1, C.disputeSigner2, C.disputeSigner3];
        vm.prank(panel[signer % 3]);
        try disputes.vote(address(bounty), id, accept) {
            ++successfulActions;
        } catch {}
    }

    function finalize(uint256 rawId) external {
        try bounty.finalize(_id(rawId)) {
            ++successfulActions;
        } catch {}
    }

    function voteValue(uint256 rawId, uint256 signer, int256 value) external {
        uint256 id = _id(rawId);
        address[3] memory panel = [C.disputeSigner1, C.disputeSigner2, C.disputeSigner3];
        vm.prank(panel[signer % 3]);
        try disputes.voteValue(address(bounty), id, value) {
            ++successfulActions;
        } catch {}
    }

    function refund(uint256 rawId) external {
        uint256 id = _id(rawId);
        address creator = bounty.getBounty(id).creator;
        vm.prank(creator);
        try bounty.refundReward(id) {
            ++successfulActions;
        } catch {}
    }

    function expire(uint256 rawId) external {
        try bounty.expire(_id(rawId)) {
            ++successfulActions;
        } catch {}
    }

    function claim(uint256 rawId, uint256 actor) external {
        uint256 id = _id(rawId);
        vm.prank(actors[actor % 5]);
        try bounty.claim(id) {
            ++successfulActions;
        } catch {}
    }

    function withdrawBond(uint256 rawId, uint256 actor) external {
        uint256 id = _id(rawId);
        vm.prank(actors[actor % 5]);
        try bounty.withdrawBond(id) {
            ++successfulActions;
        } catch {}
    }

    function withdrawStake(uint256 actor, uint96 rawAmount) external {
        uint256 amount = uint256(rawAmount) % 50_000e18 + 1;
        vm.prank(actors[actor % 5]);
        try stake.withdraw(address(bounty), amount) {
            ++successfulActions;
        } catch {}
    }

    function withdrawDisputeCredit(uint256 actor) external {
        vm.prank(actors[actor % 5]);
        try disputes.withdrawPayout() {
            ++successfulActions;
        } catch {}
    }

    function fundPools(uint256 actor, uint96 rawAmount, bool which) external {
        uint256 amount = uint256(rawAmount) % 1_000e18 + 1;
        vm.prank(actors[actor % 5]);
        if (which) {
            try subsidy.deposit(amount) {
                ++successfulActions;
            } catch {}
        } else {
            try bootstrap.deposit(amount) {
                ++successfulActions;
            } catch {}
        }
    }

    function subsidize(uint256 rawId) external {
        uint256 id = _id(rawId);
        address creator = bounty.getBounty(id).creator;
        vm.prank(creator);
        try subsidy.subsidize(id) {
            ++successfulActions;
        } catch {}
    }

    function bootstrapResolver(uint256 rawId) external {
        try bootstrap.bootstrap(_id(rawId)) {
            ++successfulActions;
        } catch {}
    }

    function advance(uint256 delta) external {
        vm.warp(vm.getBlockTimestamp() + delta % (3 days + 1));
        ++successfulActions;
    }

    function _id(uint256 raw) private view returns (uint256) {
        return raw % bounty.bountyCount() + 1;
    }
}

contract ProtocolInvariantTest is StdInvariant, ProtocolTestBase {
    ProtocolHandler internal handler;
    address[5] internal actors;

    function setUp() public override {
        super.setUp();
        actors = [creator, alice, bob, carol, challenger];
        // Seed both an open and a challenged bounty so a run explores live custody from its first step.
        uint256 id = _resolved();
        _challenge(id, 21);
        _createAs(alice);
        _createAs(bob);
        for (uint256 i = 1; i < actors.length; ++i) {
            vm.prank(actors[i]);
            stake.deposit(address(bounty), C.RESOLVER_STAKE);
        }
        vm.prank(carol);
        subsidy.deposit(1_000e18);
        vm.prank(carol);
        bootstrap.deposit(1_000e18);
        handler = new ProtocolHandler(bounty, subsidy, bootstrap, actors);
        targetContract(address(handler));
        // Actor selection is fuzzed inside the handler; random external callers add only fork RPC reads.
        targetSender(address(this));
        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = handler.create.selector;
        selectors[1] = handler.forecast.selector;
        selectors[2] = handler.depositStake.selector;
        selectors[3] = handler.resolve.selector;
        selectors[4] = handler.challenge.selector;
        selectors[5] = handler.vote.selector;
        selectors[6] = handler.finalize.selector;
        selectors[7] = handler.refund.selector;
        selectors[8] = handler.expire.selector;
        selectors[9] = handler.claim.selector;
        selectors[10] = handler.withdrawBond.selector;
        selectors[11] = handler.withdrawStake.selector;
        selectors[12] = handler.withdrawDisputeCredit.selector;
        selectors[13] = handler.fundPools.selector;
        selectors[14] = handler.subsidize.selector;
        selectors[15] = handler.bootstrapResolver.selector;
        selectors[16] = handler.advance.selector;
        selectors[17] = handler.voteValue.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantEveryCustodiedTokenHasMatchingLiabilityAndSupplyIsConserved() public view {
        _assertSolvent();
        uint256 balances = token.balanceOf(address(this)) + token.balanceOf(address(bounty))
            + token.balanceOf(address(stake)) + token.balanceOf(address(disputes)) + token.balanceOf(address(subsidy))
            + token.balanceOf(address(bootstrap));
        uint256 accountedStakes;
        uint256 accountedCredits;
        for (uint256 i; i < actors.length; ++i) {
            balances += token.balanceOf(actors[i]);
            accountedStakes += stake.stakeOf(address(bounty), actors[i]);
            accountedCredits += disputes.credit(actors[i]);
            assertLe(stake.reserved(address(bounty), actors[i]), stake.stakeOf(address(bounty), actors[i]));
        }
        assertEq(balances, token.totalSupply());
        assertEq(accountedStakes, stake.totalStaked());
        assertEq(accountedCredits, disputes.totalCredits());
    }

    function invariantBountyLiabilitiesAndLocksMatchActualUnpaidObligations() public view {
        uint256 rewards;
        uint256 bonds;
        uint256[5] memory active;
        uint256[5] memory reserved;
        uint256[5] memory openSubsidised;
        for (uint256 id = 1; id <= bounty.bountyCount(); ++id) {
            ForecastBounty.Bounty memory item = bounty.getBounty(id);
            if (!item.rewardPaid) rewards += item.reward;
            (address resolver, uint256 penalty, bool locked) = stake.locks(address(bounty), id);
            for (uint256 j; j < actors.length; ++j) {
                if (bounty.hasForecast(id, actors[j]) && !bounty.bondWithdrawn(id, actors[j])) bonds += C.BOND;
                if (locked && resolver == actors[j]) {
                    ++active[j];
                    reserved[j] += penalty;
                }
                if (subsidy.subsidised(id) && !bounty.isClosed(id) && item.creator == actors[j]) ++openSubsidised[j];
            }
        }
        assertEq(rewards, bounty.rewardLiability());
        assertEq(bonds, bounty.bondLiability());
        for (uint256 j; j < actors.length; ++j) {
            assertEq(active[j], stake.activeLocks(address(bounty), actors[j]));
            assertEq(reserved[j], stake.reserved(address(bounty), actors[j]));
            assertLe(openSubsidised[j], 1);
        }
    }

    function invariantNoGetterRevealsForecastBeforeResolution() public view {
        for (uint256 id = 1; id <= bounty.bountyCount(); ++id) {
            if (bounty.getBounty(id).hasResolved) continue;
            (bool success, bytes memory data) = address(bounty).staticcall(abi.encodeCall(bounty.entryAt, (id, 0)));
            assertFalse(success);
            assertEq(data, abi.encodeWithSelector(ForecastBounty.ForecastsHidden.selector));
        }
    }

    /// @notice Every generated sequence must permit complete recovery of non-donated funds.
    function afterInvariant() public {
        vm.warp(vm.getBlockTimestamp() + 20 days);
        for (uint256 id = 1; id <= bounty.bountyCount(); ++id) {
            ForecastBounty.Bounty memory item = bounty.getBounty(id);
            if (item.state == BountyRegistry.State.Open) {
                bounty.expire(id);
            } else if (item.state == BountyRegistry.State.Resolved || item.state == BountyRegistry.State.Disputed) {
                bounty.finalize(id);
            }
            item = bounty.getBounty(id);
            if (!item.rewardPaid) {
                if (item.state == BountyRegistry.State.Refunded || bounty.entryCount(id) == 0) {
                    vm.prank(item.creator);
                    bounty.refundReward(id);
                } else {
                    vm.prank(item.winner);
                    bounty.claim(id);
                }
            }
            for (uint256 j; j < actors.length; ++j) {
                if (bounty.hasForecast(id, actors[j]) && !bounty.bondWithdrawn(id, actors[j])) {
                    vm.prank(actors[j]);
                    bounty.withdrawBond(id);
                }
            }
        }
        for (uint256 j; j < actors.length; ++j) {
            if (disputes.credit(actors[j]) > 0) {
                vm.prank(actors[j]);
                disputes.withdrawPayout();
            }
            uint256 balance = stake.stakeOf(address(bounty), actors[j]);
            if (balance > 0) {
                vm.prank(actors[j]);
                stake.withdraw(address(bounty), balance);
            }
        }
        assertEq(token.balanceOf(address(bounty)), 0);
        assertEq(token.balanceOf(address(stake)), 0);
        assertEq(token.balanceOf(address(disputes)), 0);
        invariantEveryCustodiedTokenHasMatchingLiabilityAndSupplyIsConserved();
    }
}
