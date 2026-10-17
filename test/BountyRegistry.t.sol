// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ProtocolTestBase} from "./ProtocolTestBase.sol";
import {BountyRegistry} from "../src/BountyRegistry.sol";

contract BountyRegistryTest is ProtocolTestBase {
    function testForeignNamespaceCannotRewriteCanonicalRecord() public {
        uint256 id = _create();
        vm.prank(challenger);
        vm.expectRevert(BountyRegistry.UnknownBounty.selector);
        registry.transition(id, BountyRegistry.State.Refunded, 88);
        vm.prank(challenger);
        registry.append(challenger, keccak256("fake"), 1, vm.getBlockTimestamp() + 1 days);
        vm.prank(challenger);
        registry.transition(id, BountyRegistry.State.Refunded, 88);
        BountyRegistry.Record memory canonical = registry.getRecord(address(bounty), id);
        assertEq(canonical.creator, creator);
        assertEq(uint8(canonical.state), uint8(BountyRegistry.State.Open));
        assertEq(canonical.resolutionValue, 0);
        assertEq(registry.historyLength(address(bounty), id), 1);
        assertEq(registry.count(challenger), 1);
    }

    function testTransitionsAreForwardOnlyAndOriginalTermsRemainIntact() public {
        uint256 id = _resolved();
        BountyRegistry.Record memory before = registry.getRecord(address(bounty), id);
        _finalize(id);
        BountyRegistry.Record memory afterRecord = registry.getRecord(address(bounty), id);
        assertEq(before.questionHash, afterRecord.questionHash);
        assertEq(before.creator, afterRecord.creator);
        assertEq(before.reward, afterRecord.reward);
        assertEq(before.deadline, afterRecord.deadline);
        assertEq(registry.historyLength(address(bounty), id), 3);
        assertEq(uint8(registry.getTransition(address(bounty), id, 0).state), uint8(BountyRegistry.State.Open));
        assertEq(uint8(registry.getTransition(address(bounty), id, 1).state), uint8(BountyRegistry.State.Resolved));
        assertEq(uint8(registry.getTransition(address(bounty), id, 2).state), uint8(BountyRegistry.State.Finalized));
        vm.prank(address(bounty));
        vm.expectRevert(BountyRegistry.InvalidTransition.selector);
        registry.transition(id, BountyRegistry.State.Open, 12);
    }

    function testRejectsInvalidRecordsAndMissingIds() public {
        vm.expectRevert(BountyRegistry.InvalidRecord.selector);
        registry.append(address(0), bytes32(0), 1, vm.getBlockTimestamp() + 1);
        vm.expectRevert(BountyRegistry.InvalidRecord.selector);
        registry.append(alice, bytes32(0), 0, vm.getBlockTimestamp() + 1);
        vm.expectRevert(BountyRegistry.InvalidRecord.selector);
        registry.append(alice, bytes32(0), 1, vm.getBlockTimestamp());
        vm.expectRevert(BountyRegistry.UnknownBounty.selector);
        registry.getRecord(address(bounty), 1);
        vm.expectRevert(BountyRegistry.UnknownBounty.selector);
        registry.transition(1, BountyRegistry.State.Resolved, 0);
        assertEq(registry.count(address(this)), 0);
    }
}
