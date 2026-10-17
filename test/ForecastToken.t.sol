// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {ForecastToken} from "../src/ForecastToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract ForecastTokenTest is ProtocolTestBase {
    function testFixedSupplyAndMetadata() public {
        ForecastToken direct = new ForecastToken();
        assertEq(direct.name(), "Forecast Bounty");
        assertEq(direct.symbol(), "FORECAST");
        assertEq(direct.decimals(), 18);
        assertEq(direct.totalSupply(), 1_000_000_000e18);
        assertEq(direct.balanceOf(address(this)), direct.totalSupply());
        assertEq(token.name(), direct.name());
        assertEq(token.symbol(), direct.symbol());
        assertEq(token.totalSupply(), direct.totalSupply());
    }

    function testTransferAndAllowanceAreExact() public {
        vm.prank(alice);
        token.approve(bob, 42e18);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, carol, 42e18));
        assertEq(token.balanceOf(alice), ALLOCATION - 42e18);
        assertEq(token.balanceOf(carol), ALLOCATION + 42e18);
        assertEq(token.allowance(alice, bob), 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function testZeroAddressAndInsufficientBalanceRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, ALLOCATION, ALLOCATION + 1)
        );
        token.transfer(bob, ALLOCATION + 1);
    }

    function testNoMintBurnOwnerPauseOrUpgradeSelectors() public {
        bytes[] memory calls = new bytes[](8);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, 1);
        calls[1] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[2] = abi.encodeWithSignature("owner()");
        calls[3] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[4] = abi.encodeWithSignature("pause()");
        calls[5] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[6] = abi.encodeWithSignature("blacklist(address)", alice);
        calls[7] = abi.encodeWithSignature("setFee(uint256)", 100);
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(token).call(calls[i]);
            assertFalse(success);
        }
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function testFuzzTransferConservesSupply(uint96 raw) public {
        uint256 amount = bound(raw, 0, ALLOCATION);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob), 2 * ALLOCATION);
        assertEq(token.balanceOf(bob), ALLOCATION + amount);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}
