// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DonationPool} from "./lib/DonationPool.sol";
import {IERC20, SafeERC20} from "./lib/TokenPool.sol";
import {ForecastBounty} from "./ForecastBounty.sol";
import {BountyRegistry} from "./BountyRegistry.sol";
import {ResolverStake} from "./ResolverStake.sol";
import {DeploymentConfig} from "./DeploymentConfig.sol";

/// @notice A one-time, donation-funded stake top-up after a resolver's first eligible final resolution.
contract ResolverBootstrap is DonationPool {
    using SafeERC20 for IERC20;

    ForecastBounty public immutable bounty;
    ResolverStake public immutable resolverStake;
    uint256 public constant BOOTSTRAP_AMOUNT = DeploymentConfig.BOOTSTRAP_AMOUNT;
    mapping(address resolver => bool) public bootstrapped;

    error IneligibleResolver();
    error AlreadyBootstrapped();
    error ComponentMismatch();

    event Bootstrapped(uint256 indexed bountyId, address indexed resolver, uint256 amount);

    constructor(address token_, address bounty_, address resolverStake_) DonationPool(token_) {
        if (bounty_ == address(0) || resolverStake_ == address(0)) revert ZeroAddress();
        bounty = ForecastBounty(bounty_);
        resolverStake = ResolverStake(resolverStake_);
    }

    /// @notice Anyone may trigger the grant, but it is always credited to the eligible creator's stake.
    function bootstrap(uint256 bountyId) external nonReentrant {
        if (
            address(bounty.token()) != address(token) || address(resolverStake.token()) != address(token)
                || address(bounty.resolverStake()) != address(resolverStake)
        ) revert ComponentMismatch();
        ForecastBounty.Bounty memory item = bounty.getBounty(bountyId);
        if (
            item.state != BountyRegistry.State.Finalized || item.resolutionOverturned
                || bounty.entryCount(bountyId) == 0
                || resolverStake.stakeOf(address(bounty), item.creator) < resolverStake.RESOLVER_STAKE()
        ) revert IneligibleResolver();
        if (bootstrapped[item.creator]) revert AlreadyBootstrapped();
        bootstrapped[item.creator] = true;
        _release(BOOTSTRAP_AMOUNT);
        token.forceApprove(address(resolverStake), BOOTSTRAP_AMOUNT);
        resolverStake.depositFor(address(bounty), item.creator, BOOTSTRAP_AMOUNT);
        emit Bootstrapped(bountyId, item.creator, BOOTSTRAP_AMOUNT);
    }
}
