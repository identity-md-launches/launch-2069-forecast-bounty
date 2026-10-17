// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DonationPool} from "./lib/DonationPool.sol";
import {IERC20, SafeERC20} from "./lib/TokenPool.sol";
import {ForecastBounty} from "./ForecastBounty.sol";
import {BountyRegistry} from "./BountyRegistry.sol";
import {DeploymentConfig} from "./DeploymentConfig.sol";

contract BountySubsidy is DonationPool {
    using SafeERC20 for IERC20;

    ForecastBounty public immutable bounty;
    uint256 public immutable MIN_REWARD;
    uint256 public constant SUBSIDY_AMOUNT = DeploymentConfig.SUBSIDY_AMOUNT;
    mapping(uint256 bountyId => bool) public subsidised;
    mapping(address creator => uint256 bountyId) public openBounty;

    error NotCreator();
    error IneligibleBounty();
    error AlreadySubsidised();
    error OtherSubsidisedBountyOpen();
    error ComponentMismatch();

    event Subsidised(uint256 indexed bountyId, address indexed creator, uint256 amount);

    constructor(address token_, address bounty_, uint256 minReward_) DonationPool(token_) {
        if (bounty_ == address(0)) revert ZeroAddress();
        if (minReward_ == 0) revert InvalidParameters();
        bounty = ForecastBounty(bounty_);
        MIN_REWARD = minReward_;
    }

    /// @notice One fixed grant per qualifying bounty and at most one open subsidised bounty per creator.
    function subsidize(uint256 bountyId) external nonReentrant {
        if (address(bounty.token()) != address(token) || bounty.MIN_REWARD() != MIN_REWARD) revert ComponentMismatch();
        ForecastBounty.Bounty memory item = bounty.getBounty(bountyId);
        if (item.creator != msg.sender) revert NotCreator();
        if (item.reward < MIN_REWARD || item.state != BountyRegistry.State.Open || block.timestamp >= item.deadline) {
            revert IneligibleBounty();
        }
        if (subsidised[bountyId]) revert AlreadySubsidised();
        uint256 other = openBounty[msg.sender];
        if (other != 0 && !bounty.isClosed(other)) revert OtherSubsidisedBountyOpen();
        subsidised[bountyId] = true;
        openBounty[msg.sender] = bountyId;
        _release(SUBSIDY_AMOUNT);
        token.safeTransfer(msg.sender, SUBSIDY_AMOUNT);
        emit Subsidised(bountyId, msg.sender, SUBSIDY_AMOUNT);
    }
}
