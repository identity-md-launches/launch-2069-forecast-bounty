// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {BountyRegistry} from "../src/BountyRegistry.sol";
import {DisputeWindow} from "../src/DisputeWindow.sol";
import {ResolverStake} from "../src/ResolverStake.sol";
import {ForecastBounty} from "../src/ForecastBounty.sol";
import {BountySubsidy} from "../src/BountySubsidy.sol";
import {ResolverBootstrap} from "../src/ResolverBootstrap.sol";
import {DeploymentConfig as C} from "../src/DeploymentConfig.sol";

/// @notice Local, non-broadcast construction rehearsal. Production deployment belongs to ProjectFactory.
/// @dev No environment, keys, external configuration, funding, or factory calls.
contract DeployForecast is Script {
    struct Deployment {
        LaunchToken token;
        BountyRegistry registry;
        DisputeWindow disputes;
        ResolverStake stake;
        ForecastBounty bounty;
        BountySubsidy subsidy;
        ResolverBootstrap bootstrap;
    }

    function run() external returns (Deployment memory d) {
        d.token = new LaunchToken();
        d.registry = new BountyRegistry();
        d.disputes = new DisputeWindow(
            address(d.token), C.BOND, C.DISPUTE_WINDOW, C.disputeSigner1, C.disputeSigner2, C.disputeSigner3
        );
        d.stake = new ResolverStake(address(d.token), C.RESOLVER_STAKE, C.SLASH_BPS);
        d.bounty = new ForecastBounty(
            address(d.token),
            address(d.registry),
            address(d.stake),
            address(d.disputes),
            C.MIN_REWARD,
            C.BOND,
            C.MAX_ENTRIES
        );
        d.subsidy = new BountySubsidy(address(d.token), address(d.bounty), C.MIN_REWARD);
        d.bootstrap = new ResolverBootstrap(address(d.token), address(d.bounty), address(d.stake));
    }
}
