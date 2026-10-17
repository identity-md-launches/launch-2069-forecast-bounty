// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {ResolverStake} from "../src/ResolverStake.sol";
import {TokenPool} from "../src/lib/TokenPool.sol";
import {DeploymentConfig as C} from "../src/DeploymentConfig.sol";

contract ResolverStakeTest is ProtocolTestBase {
    function testPermissionlessDepositsForSelfAndOthersAndPartialWithdrawals() public {
        vm.prank(alice);
        stake.deposit(address(bounty), 11e18);
        vm.prank(bob);
        stake.depositFor(address(bounty), alice, 7e18);
        assertEq(stake.stakeOf(address(bounty), alice), 18e18);
        assertEq(stake.stakeOf(address(bounty), bob), 0);
        vm.prank(alice);
        stake.withdraw(address(bounty), 5e18);
        assertEq(stake.stakeOf(address(bounty), alice), 13e18);
        vm.prank(bob);
        vm.expectRevert(ResolverStake.InsufficientStake.selector);
        stake.withdraw(address(bounty), 1);
        vm.prank(alice);
        vm.expectRevert(ResolverStake.InsufficientStake.selector);
        stake.withdraw(address(bounty), 13e18 + 1);
        vm.prank(alice);
        stake.withdraw(address(bounty), 13e18);
        assertEq(token.balanceOf(alice), ALLOCATION + 7e18);
        assertEq(token.balanceOf(bob), ALLOCATION - 7e18);
        _assertSolvent();
    }

    function testBadDepositsAndZeroWithdrawalsRevert() public {
        vm.expectRevert(TokenPool.ZeroAmount.selector);
        stake.deposit(address(bounty), 0);
        vm.expectRevert(TokenPool.ZeroAddress.selector);
        stake.deposit(address(0), 1);
        vm.expectRevert(TokenPool.ZeroAddress.selector);
        stake.depositFor(address(bounty), address(0), 1);
        vm.expectRevert(TokenPool.ZeroAmount.selector);
        stake.withdraw(address(bounty), 0);
        _assertSolvent();
    }

    function testUntrustedMarketCannotLockReleaseOrSlashCanonicalStake() public {
        uint256 id = _resolved();
        vm.prank(challenger);
        vm.expectRevert(ResolverStake.InsufficientStake.selector);
        stake.lock(id, creator);
        vm.prank(challenger);
        vm.expectRevert(ResolverStake.UnknownLock.selector);
        stake.settle(id, true, challenger);
        vm.prank(challenger);
        vm.expectRevert(ResolverStake.UnknownLock.selector);
        stake.settle(id, false, challenger);
        assertEq(stake.activeLocks(address(bounty), creator), 1);
        assertEq(stake.stakeOf(address(bounty), creator), C.RESOLVER_STAKE);
        _assertSolvent();
    }

    function testConcurrentResolutionsReserveFullSlashAndCannotOvercommit() public {
        uint256[6] memory ids;
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = _create();
        }
        _stakeCreator();
        for (uint256 i; i < 5; ++i) {
            _resolve(ids[i], int256(i));
        }
        assertEq(stake.activeLocks(address(bounty), creator), 5);
        assertEq(stake.reserved(address(bounty), creator), C.RESOLVER_STAKE);
        vm.prank(creator);
        vm.expectRevert(ResolverStake.InsufficientStake.selector);
        bounty.resolve(ids[5], 5);
        for (uint256 i; i < 5; ++i) {
            _challenge(ids[i], 100);
            _vote(ids[i], C.disputeSigner1, true);
            _vote(ids[i], C.disputeSigner2, true);
        }
        uint256 before = token.balanceOf(challenger);
        // Resolve in reverse order: each reserved penalty remains fully funded.
        for (uint256 i = 5; i > 0; --i) {
            bounty.finalize(ids[i - 1]);
        }
        assertEq(token.balanceOf(challenger), before + C.RESOLVER_STAKE);
        assertEq(stake.reserved(address(bounty), creator), 0);
        assertEq(stake.stakeOf(address(bounty), creator), 0);
        assertEq(stake.activeLocks(address(bounty), creator), 0);
        _assertSolvent();
    }

    function testAllLocksMustFinishEvenWhenOneWindowIsAlreadyFinal() public {
        uint256 id1 = _create();
        uint256 id2 = _create();
        _stakeCreator();
        _resolve(id1, 0);
        _resolve(id2, 0);
        _challenge(id1, 1);
        _vote(id1, C.disputeSigner1, false);
        _vote(id1, C.disputeSigner2, false);
        bounty.finalize(id1);
        vm.prank(creator);
        vm.expectRevert(ResolverStake.StakeLocked.selector);
        stake.withdraw(address(bounty), 1);
        _finalize(id2);
        vm.prank(creator);
        stake.withdraw(address(bounty), C.RESOLVER_STAKE);
        _assertSolvent();
    }

    function testTopUpDoesNotChangePreviouslyReservedSlash() public {
        uint256 id = _resolved();
        vm.prank(bob);
        stake.depositFor(address(bounty), creator, C.RESOLVER_STAKE);
        _challenge(id, 21);
        _vote(id, C.disputeSigner1, true);
        _vote(id, C.disputeSigner2, true);
        bounty.finalize(id);
        assertEq(stake.stakeOf(address(bounty), creator), 45_000e18);
        assertEq(token.balanceOf(challenger), ALLOCATION - C.BOND + 5_000e18);
        _assertSolvent();
    }

    function testFuzzSnapshotSlashRoundsDownAndPreservesBacking(uint96 raw) public {
        uint256 amount = bound(raw, C.RESOLVER_STAKE, ALLOCATION);
        uint256 id = _create();
        vm.prank(bob);
        stake.depositFor(address(bounty), creator, amount);
        _resolve(id, 0);
        _challenge(id, 1);
        _vote(id, C.disputeSigner1, true);
        _vote(id, C.disputeSigner2, true);
        bounty.finalize(id);
        uint256 penalty = amount * C.SLASH_BPS / 10_000;
        assertEq(stake.stakeOf(address(bounty), creator), amount - penalty);
        assertEq(token.balanceOf(challenger), ALLOCATION - C.BOND + penalty);
        _assertSolvent();
    }
}
