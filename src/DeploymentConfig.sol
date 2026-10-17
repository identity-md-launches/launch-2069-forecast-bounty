// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Canonical mainnet launch inputs. There is deliberately no swarm parameter.
library DeploymentConfig {
    uint256 internal constant MIN_REWARD = 5_000e18;
    uint256 internal constant BOND = 100e18;
    uint256 internal constant RESOLVER_STAKE = 25_000e18;
    uint256 internal constant SLASH_BPS = 2_000;
    uint256 internal constant DISPUTE_WINDOW = 48 hours;
    uint256 internal constant MAX_ENTRIES = 500;
    uint256 internal constant PANEL_TIMEOUT = 7 days;
    uint256 internal constant RESOLUTION_TIMEOUT = 7 days;
    uint256 internal constant SUBSIDY_AMOUNT = 100e18;
    uint256 internal constant BOOTSTRAP_AMOUNT = 100e18;
    uint256 internal constant CHAIN_ID = 1;
    uint256 internal constant poolBps = 5_000;
    // Uniswap v4 Currency encoding for native ETH, not an unset contract address.
    address internal constant pairedCurrency = address(0);
    address internal constant remainderTo = 0xBB85C1b7540d9e7b56F7a595FC1ff7Dd07Cb0823;
    address internal constant disputeSigner1 = 0xAF5a05077Da3e3D130d66C1C73362306cc89d899;
    address internal constant disputeSigner2 = 0xC4F6e66C24fDc6Ae0f859c468dd177f8100b4959;
    address internal constant disputeSigner3 = 0xc9b5c6b29F66D526b76e68198F70d66342b0d84c;
}
