// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ForecastBounty} from "../src/ForecastBounty.sol";
import {BountyRegistry} from "../src/BountyRegistry.sol";
import {ResolverStake} from "../src/ResolverStake.sol";
import {DisputeWindow} from "../src/DisputeWindow.sol";
import {BountySubsidy} from "../src/BountySubsidy.sol";
import {ResolverBootstrap} from "../src/ResolverBootstrap.sol";
import {TokenPool} from "../src/lib/TokenPool.sol";
import {DeploymentConfig as C} from "../src/DeploymentConfig.sol";

/// @dev Test-only hostile token. Production always uses the immutable ForecastToken.
contract AdversarialToken is ERC20 {
    address public target;
    bytes public payload;
    bytes public callbackResult;
    bool public callbackSucceeded;
    bool public falseTransfers;
    bool public shortTransfers;

    constructor() ERC20("Test adversarial token", "TEST") {
        _mint(msg.sender, 1_000_000_000e18);
    }

    function configure(address target_, bytes calldata payload_, bool false_, bool short_) external {
        target = target_;
        payload = payload_;
        falseTransfers = false_;
        shortTransfers = short_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (falseTransfers) return false;
        super.transfer(to, amount);
        _callback();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (falseTransfers) return false;
        super.transferFrom(from, to, shortTransfers ? amount - 1 : amount);
        _callback();
        return true;
    }

    function _callback() private {
        address destination = target;
        if (destination == address(0)) return;
        // One callback per transfer, avoiding recursive mock behavior.
        target = address(0);
        (callbackSucceeded, callbackResult) = destination.call(payload);
    }
}

contract AdversarialTokenTest is Test {
    AdversarialToken internal token;
    ForecastBounty internal bounty;
    BountyRegistry internal registry;
    ResolverStake internal stake;
    DisputeWindow internal disputes;
    BountySubsidy internal subsidy;
    ResolverBootstrap internal bootstrap;

    function setUp() public {
        token = new AdversarialToken();
        registry = new BountyRegistry();
        stake = new ResolverStake(address(token), C.RESOLVER_STAKE, C.SLASH_BPS);
        disputes = new DisputeWindow(
            address(token), C.BOND, C.DISPUTE_WINDOW, C.disputeSigner1, C.disputeSigner2, C.disputeSigner3
        );
        bounty = new ForecastBounty(
            address(token), address(registry), address(stake), address(disputes), C.MIN_REWARD, C.BOND, C.MAX_ENTRIES
        );
        subsidy = new BountySubsidy(address(token), address(bounty), C.MIN_REWARD);
        bootstrap = new ResolverBootstrap(address(token), address(bounty), address(stake));
        token.approve(address(bounty), 1_000_000e18);
        token.approve(address(stake), 1_000_000e18);
        token.approve(address(subsidy), 1_000_000e18);
        token.approve(address(bootstrap), 1_000_000e18);
    }

    function testShortAndFalseIncomingTransfersCannotCreateUnbackedRewards() public {
        token.configure(address(0), "", false, true);
        vm.expectRevert(TokenPool.InexactTransfer.selector);
        bounty.createBounty("q", vm.getBlockTimestamp() + 1 days, "source", C.MIN_REWARD);
        assertEq(bounty.bountyCount(), 0);
        assertEq(bounty.rewardLiability(), 0);
        assertEq(token.balanceOf(address(bounty)), 0);
        token.configure(address(0), "", true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        bounty.createBounty("q", vm.getBlockTimestamp() + 1 days, "source", C.MIN_REWARD);
        assertEq(bounty.bountyCount(), 0);
        assertEq(registry.count(address(bounty)), 0);
    }

    function testReentrantCreateIsRejectedWithoutLosingOriginalDeposit() public {
        bytes memory nested =
            abi.encodeCall(bounty.createBounty, ("nested", vm.getBlockTimestamp() + 1 days, "source", C.MIN_REWARD));
        token.configure(address(bounty), nested, false, false);
        uint256 id = bounty.createBounty("q", vm.getBlockTimestamp() + 1 days, "source", C.MIN_REWARD);
        _assertGuardReverted();
        assertEq(id, 1);
        assertEq(bounty.bountyCount(), 1);
        assertEq(token.balanceOf(address(bounty)), C.MIN_REWARD);
    }

    function testReentrantDonationSyncCannotDoubleCreditPool() public {
        token.configure(address(subsidy), abi.encodeWithSignature("deposit()"), false, false);
        subsidy.deposit(C.BOND);
        _assertGuardReverted();
        assertEq(subsidy.available(), C.BOND);
        assertEq(subsidy.totalDeposited(), C.BOND);
        token.configure(address(bootstrap), abi.encodeWithSignature("deposit()"), false, false);
        bootstrap.deposit(C.BOND);
        _assertGuardReverted();
        assertEq(bootstrap.available(), C.BOND);
        assertEq(bootstrap.totalDeposited(), C.BOND);
    }

    function testReentrantStakeWithdrawalFailsInsideDeposit() public {
        token.configure(address(stake), abi.encodeCall(stake.withdraw, (address(bounty), 1)), false, false);
        stake.deposit(address(bounty), C.RESOLVER_STAKE);
        _assertGuardReverted();
        assertEq(stake.stakeOf(address(bounty), address(this)), C.RESOLVER_STAKE);
        assertEq(stake.totalStaked(), C.RESOLVER_STAKE);
    }

    function testRewardTransferFailureRollsBackFinalizationAndCanBeRetried() public {
        uint256 id = bounty.createBounty("q", vm.getBlockTimestamp() + 1 days, "source", C.MIN_REWARD);
        bounty.forecast(id, 7);
        stake.deposit(address(bounty), C.RESOLVER_STAKE);
        vm.warp(bounty.getBounty(id).deadline);
        bounty.resolve(id, 7);
        vm.warp(disputes.getCase(address(bounty), id).endsAt);
        token.configure(address(0), "", true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        bounty.claim(id);
        assertFalse(bounty.getBounty(id).rewardPaid);
        assertEq(uint8(bounty.getBounty(id).state), uint8(BountyRegistry.State.Resolved));
        assertEq(stake.activeLocks(address(bounty), address(this)), 1);
        assertEq(disputes.credit(address(this)), 0);
        assertEq(bounty.rewardLiability(), C.MIN_REWARD);
        token.configure(address(bounty), abi.encodeCall(bounty.claim, (id)), false, false);
        bounty.claim(id);
        _assertGuardReverted();
        assertTrue(bounty.getBounty(id).rewardPaid);
        assertEq(stake.activeLocks(address(bounty), address(this)), 0);
        assertEq(bounty.rewardLiability(), 0);
        assertEq(token.balanceOf(address(bounty)), C.BOND);
        bounty.withdrawBond(id);
        assertEq(token.balanceOf(address(bounty)), 0);
    }

    function testReentrantDisputeDuringOpeningCannotEnterWindow() public {
        token.approve(address(disputes), C.BOND);
        token.configure(address(disputes), abi.encodeCall(disputes.finalize, (address(this), 1)), false, false);
        disputes.open(1, address(this), 0);
        _assertGuardReverted();
        assertEq(disputes.totalEscrow(), C.BOND);
        assertEq(disputes.totalCredits(), 0);
    }

    function _assertGuardReverted() private view {
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }
}
