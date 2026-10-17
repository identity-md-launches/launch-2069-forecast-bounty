// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {DeployForecast} from "../script/DeployForecast.s.sol";
import {ForecastBounty} from "../src/ForecastBounty.sol";
import {ResolverStake} from "../src/ResolverStake.sol";
import {DisputeWindow} from "../src/DisputeWindow.sol";
import {BountySubsidy} from "../src/BountySubsidy.sol";
import {ResolverBootstrap} from "../src/ResolverBootstrap.sol";
import {TokenPool} from "../src/lib/TokenPool.sol";
import {DeploymentConfig as C} from "../src/DeploymentConfig.sol";

contract DeploymentTest is ProtocolTestBase {
    function testAtomicConstructionPreservesSupplyAndUsesCanonicalConfig() public {
        DeployForecast rehearsal = new DeployForecast();
        DeployForecast.Deployment memory d = rehearsal.run();
        assertEq(d.token.balanceOf(address(rehearsal)), 1_000_000_000e18);
        assertEq(d.token.totalSupply(), 1_000_000_000e18);
        assertEq(address(d.bounty.token()), address(d.token));
        assertEq(address(d.bounty.registry()), address(d.registry));
        assertEq(address(d.bounty.disputeWindow()), address(d.disputes));
        assertEq(address(d.bounty.resolverStake()), address(d.stake));
        assertEq(address(d.subsidy.bounty()), address(d.bounty));
        assertEq(address(d.bootstrap.bounty()), address(d.bounty));
        assertEq(address(d.bootstrap.resolverStake()), address(d.stake));
        assertEq(d.bounty.MIN_REWARD(), 5_000e18);
        assertEq(d.bounty.BOND(), 100e18);
        assertEq(d.bounty.MAX_ENTRIES(), 500);
        assertEq(d.stake.RESOLVER_STAKE(), 25_000e18);
        assertEq(d.stake.SLASH_BPS(), 2_000);
        assertEq(d.disputes.DISPUTE_WINDOW(), 48 hours);
        assertEq(d.subsidy.available(), 0);
        assertEq(d.bootstrap.available(), 0);
        assertEq(C.poolBps, 5_000);
        assertEq(C.pairedCurrency, address(0));
        assertEq(C.remainderTo, 0xBB85C1b7540d9e7b56F7a595FC1ff7Dd07Cb0823);
        uint256 supply = d.token.totalSupply();
        uint256 pool = supply * C.poolBps / 10_000;
        uint256 factorySwarmAllocation = supply / 10;
        assertEq(pool, 500_000_000e18);
        assertEq(factorySwarmAllocation, 100_000_000e18);
        assertEq(supply - pool - factorySwarmAllocation, 400_000_000e18);
    }

    function testConstructorsWorkBeforeDependenciesExist() public {
        // These are local fixture identities, not launch signers. Well-known test-wallet keys may
        // already have EIP-7702 delegations on a real fork, so explicitly model an empty chain here.
        vm.etch(creator, hex"");
        vm.etch(alice, hex"");
        vm.etch(bob, hex"");
        vm.etch(carol, hex"");
        assertEq(creator.code.length, 0);
        assertEq(alice.code.length, 0);
        assertEq(bob.code.length, 0);
        assertEq(carol.code.length, 0);
        // Test-only undeployed dependencies demonstrate that constructors do not call external code.
        ResolverStake emptyStake = new ResolverStake(creator, C.RESOLVER_STAKE, C.SLASH_BPS);
        DisputeWindow emptyWindow =
            new DisputeWindow(creator, C.BOND, C.DISPUTE_WINDOW, C.disputeSigner1, C.disputeSigner2, C.disputeSigner3);
        ForecastBounty emptyBounty = new ForecastBounty(creator, alice, bob, carol, C.MIN_REWARD, C.BOND, C.MAX_ENTRIES);
        BountySubsidy emptySubsidy = new BountySubsidy(creator, alice, C.MIN_REWARD);
        ResolverBootstrap emptyBootstrap = new ResolverBootstrap(creator, alice, bob);
        assertGt(address(emptyStake).code.length, 0);
        assertGt(address(emptyWindow).code.length, 0);
        assertGt(address(emptyBounty).code.length, 0);
        assertGt(address(emptySubsidy).code.length, 0);
        assertGt(address(emptyBootstrap).code.length, 0);
    }

    function testAllApplicationRuntimesBoundedAndWithoutEscapeOpcodes() public view {
        address[7] memory contracts_ = [
            address(token),
            address(registry),
            address(disputes),
            address(stake),
            address(bounty),
            address(subsidy),
            address(bootstrap)
        ];
        for (uint256 i; i < contracts_.length; ++i) {
            bytes memory runtime = contracts_[i].code;
            assertGt(runtime.length, 0);
            assertLe(runtime.length, 24_576);
            for (uint256 j; j < runtime.length; ++j) {
                uint8 op = uint8(runtime[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            }
        }
    }

    function testNoApplicationOwnerPauseOrUpgrade() public {
        address[6] memory apps = [
            address(registry), address(disputes), address(stake), address(bounty), address(subsidy), address(bootstrap)
        ];
        for (uint256 i; i < apps.length; ++i) {
            (bool success,) = apps[i].call(abi.encodeWithSignature("owner()"));
            assertFalse(success);
            (success,) = apps[i].call(abi.encodeWithSignature("pause()"));
            assertFalse(success);
            (success,) = apps[i].call(abi.encodeWithSignature("upgradeTo(address)", challenger));
            assertFalse(success);
            (success,) = apps[i].call(abi.encodeWithSignature("transferOwnership(address)", challenger));
            assertFalse(success);
        }
    }

    /// @dev The same test checks the supplied signers against live state when run with --fork-url.
    function testPinnedPanelAddressesAreDistinctNonzeroAndHaveNoCode() public view {
        assertTrue(C.disputeSigner1 != address(0) && C.disputeSigner2 != address(0) && C.disputeSigner3 != address(0));
        assertTrue(
            C.disputeSigner1 != C.disputeSigner2 && C.disputeSigner1 != C.disputeSigner3
                && C.disputeSigner2 != C.disputeSigner3
        );
        assertEq(C.disputeSigner1.code.length, 0);
        assertEq(C.disputeSigner2.code.length, 0);
        assertEq(C.disputeSigner3.code.length, 0);
    }

    function testInvalidConstructorParametersFailClearly() public {
        vm.expectRevert(TokenPool.ZeroAddress.selector);
        new ResolverStake(address(0), C.RESOLVER_STAKE, C.SLASH_BPS);
        vm.expectRevert(TokenPool.InvalidParameters.selector);
        new ResolverStake(address(token), 0, C.SLASH_BPS);
        vm.expectRevert(TokenPool.InvalidParameters.selector);
        new ResolverStake(address(token), C.RESOLVER_STAKE, 10_001);
        vm.expectRevert(TokenPool.InvalidParameters.selector);
        new DisputeWindow(address(token), 0, C.DISPUTE_WINDOW, C.disputeSigner1, C.disputeSigner2, C.disputeSigner3);
        vm.expectRevert(TokenPool.InvalidParameters.selector);
        new DisputeWindow(address(token), C.BOND, 0, C.disputeSigner1, C.disputeSigner2, C.disputeSigner3);
        vm.expectRevert(TokenPool.InvalidParameters.selector);
        new ForecastBounty(
            address(token), address(registry), address(stake), address(disputes), C.MIN_REWARD, C.BOND, 501
        );
        vm.expectRevert(TokenPool.ZeroAddress.selector);
        new ForecastBounty(address(token), address(0), address(stake), address(disputes), C.MIN_REWARD, C.BOND, 500);
        vm.expectRevert(TokenPool.InvalidParameters.selector);
        new BountySubsidy(address(token), address(bounty), 0);
        vm.expectRevert(TokenPool.ZeroAddress.selector);
        new BountySubsidy(address(token), address(0), C.MIN_REWARD);
        vm.expectRevert(TokenPool.ZeroAddress.selector);
        new ResolverBootstrap(address(token), address(bounty), address(0));
    }
}
