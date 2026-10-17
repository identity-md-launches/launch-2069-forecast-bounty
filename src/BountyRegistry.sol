// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Append-only records and transition history, isolated by the issuing bounty contract.
/// @dev An untrusted caller can only write its own namespace, never the canonical market's records.
contract BountyRegistry {
    enum State {
        Open,
        Resolved,
        Disputed,
        Finalized,
        Refunded
    }

    struct Record {
        uint256 id;
        bytes32 questionHash;
        address creator;
        uint256 reward;
        uint256 deadline;
        State state;
        int256 resolutionValue;
    }

    struct Transition {
        State state;
        int256 resolutionValue;
        uint256 timestamp;
    }

    error InvalidRecord();
    error UnknownBounty();
    error InvalidTransition();

    mapping(address market => uint256) public count;
    mapping(address market => mapping(uint256 id => Record)) private _records;
    mapping(address market => mapping(uint256 id => Transition[])) private _history;

    event BountyIndexed(address indexed market, uint256 indexed id, address indexed creator, bytes32 questionHash);
    event StateAppended(address indexed market, uint256 indexed id, State state, int256 resolutionValue);

    function append(address creator, bytes32 questionHash, uint256 reward, uint256 deadline)
        external
        returns (uint256 id)
    {
        if (creator == address(0) || reward == 0 || deadline <= block.timestamp) revert InvalidRecord();
        id = ++count[msg.sender];
        _records[msg.sender][id] = Record(id, questionHash, creator, reward, deadline, State.Open, 0);
        _history[msg.sender][id].push(Transition(State.Open, 0, block.timestamp));
        emit BountyIndexed(msg.sender, id, creator, questionHash);
    }

    function transition(uint256 id, State next, int256 value) external {
        Record storage record = _records[msg.sender][id];
        if (record.id == 0) revert UnknownBounty();
        State previous = record.state;
        bool valid = (previous == State.Open && (next == State.Resolved || next == State.Refunded))
            || (previous == State.Resolved
                && (next == State.Disputed || next == State.Finalized || next == State.Refunded))
            || (previous == State.Disputed && (next == State.Finalized || next == State.Refunded));
        if (!valid) revert InvalidTransition();
        record.state = next;
        record.resolutionValue = value;
        _history[msg.sender][id].push(Transition(next, value, block.timestamp));
        emit StateAppended(msg.sender, id, next, value);
    }

    function getRecord(address market, uint256 id) external view returns (Record memory) {
        if (_records[market][id].id == 0) revert UnknownBounty();
        return _records[market][id];
    }

    function historyLength(address market, uint256 id) external view returns (uint256) {
        return _history[market][id].length;
    }

    function getTransition(address market, uint256 id, uint256 index) external view returns (Transition memory) {
        return _history[market][id][index];
    }
}
