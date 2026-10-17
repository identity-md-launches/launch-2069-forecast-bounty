// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenPool} from "./TokenPool.sol";

/// @notice Irrevocable donations. No depositor shares, privileged funding route, or admin withdrawal.
abstract contract DonationPool is TokenPool {
    uint256 public available;
    uint256 public totalDeposited;
    uint256 public totalReleased;

    error InsufficientPool();

    event Deposited(address indexed donor, uint256 amount);

    constructor(address token_) TokenPool(token_) {}

    function deposit(uint256 amount) external nonReentrant {
        _pull(msg.sender, amount);
        _credit(amount);
    }

    /// @notice Credit FORECAST transferred directly to the pool, including requester launch funding.
    function deposit() external nonReentrant {
        uint256 amount = token.balanceOf(address(this)) - available;
        if (amount == 0) revert ZeroAmount();
        _credit(amount);
    }

    function _credit(uint256 amount) private {
        available += amount;
        totalDeposited += amount;
        emit Deposited(msg.sender, amount);
    }

    function _release(uint256 amount) internal {
        if (available < amount) revert InsufficientPool();
        available -= amount;
        totalReleased += amount;
    }
}
