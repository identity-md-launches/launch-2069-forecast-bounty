// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply. The launch factory receives the entire supply and performs the allocation.
contract ForecastToken is ERC20 {
    constructor() ERC20("Forecast Bounty", "FORECAST") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}
