// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForecastToken} from "./ForecastToken.sol";

/// @notice Factory-compatible artifact name for ForecastToken. Deploy this token only once.
contract LaunchToken is ForecastToken {}
