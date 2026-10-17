// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenPool, IERC20, SafeERC20} from "./lib/TokenPool.sol";
import {DeploymentConfig} from "./DeploymentConfig.sol";

interface IDisputedMarket {
    function onDisputed(uint256 bountyId) external;
}

/// @notice Equal resolution/challenge bonds with direct, immutable 2-of-3 panel voting.
contract DisputeWindow is TokenPool {
    using SafeERC20 for IERC20;

    enum Outcome {
        Pending,
        Uncontested,
        Upheld,
        Overturned,
        TimedOut
    }

    struct Case {
        address resolver;
        address disputer;
        int256 originalValue;
        int256 correctedValue;
        int256 finalValue;
        uint256 endsAt;
        uint256 panelEndsAt;
        uint8 acceptVotes;
        uint8 rejectVotes;
        Outcome outcome;
    }

    uint256 public immutable BOND;
    uint256 public immutable DISPUTE_WINDOW;
    uint256 public constant PANEL_TIMEOUT = DeploymentConfig.PANEL_TIMEOUT;
    address public immutable signer1;
    address public immutable signer2;
    address public immutable signer3;
    uint256 public totalEscrow;
    uint256 public totalCredits;
    mapping(address market => mapping(uint256 bountyId => Case)) private _cases;
    mapping(address market => mapping(uint256 bountyId => mapping(address signer => bool))) public hasVoted;
    mapping(address market => mapping(uint256 bountyId => mapping(int256 value => uint8))) public valueVotes;
    mapping(address account => uint256 amount) public credit;

    error DuplicateSigner();
    error UnknownCase();
    error AlreadyOpened();
    error AlreadyDisputed();
    error WindowClosed();
    error WindowOpen();
    error InvalidDispute();
    error NotSigner();
    error AlreadyVoted();
    error NotDisputed();
    error AlreadyDecided();
    error PanelExpired();
    error NoCredit();

    event WindowOpened(address indexed market, uint256 indexed bountyId, address indexed resolver, uint256 endsAt);
    event Disputed(address indexed market, uint256 indexed bountyId, address indexed disputer, int256 correctedValue);
    event Voted(address indexed market, uint256 indexed bountyId, address indexed signer, int256 value);
    event Decided(address indexed market, uint256 indexed bountyId, Outcome outcome);
    event PayoutWithdrawn(address indexed account, uint256 amount);

    constructor(
        address token_,
        uint256 bond_,
        uint256 disputeWindow_,
        address signer1_,
        address signer2_,
        address signer3_
    ) TokenPool(token_) {
        if (signer1_ == address(0) || signer2_ == address(0) || signer3_ == address(0)) {
            revert ZeroAddress();
        }
        if (signer1_ == signer2_ || signer1_ == signer3_ || signer2_ == signer3_) revert DuplicateSigner();
        if (bond_ == 0 || bond_ > type(uint256).max / 2 || disputeWindow_ == 0) revert InvalidParameters();
        BOND = bond_;
        DISPUTE_WINDOW = disputeWindow_;
        signer1 = signer1_;
        signer2 = signer2_;
        signer3 = signer3_;
    }

    /// @notice The market pays the resolver's bond; arbitrary callers cannot spend a resolver's approval.
    function open(uint256 bountyId, address resolver, int256 originalValue) external nonReentrant {
        if (resolver == address(0)) revert ZeroAddress();
        Case storage item = _cases[msg.sender][bountyId];
        if (item.resolver != address(0)) revert AlreadyOpened();
        item.resolver = resolver;
        item.originalValue = originalValue;
        item.endsAt = block.timestamp + DISPUTE_WINDOW;
        totalEscrow += BOND;
        _pull(msg.sender, BOND);
        emit WindowOpened(msg.sender, bountyId, resolver, item.endsAt);
    }

    function dispute(address market, uint256 bountyId, int256 correctedValue) external nonReentrant {
        Case storage item = _case(market, bountyId);
        if (item.outcome != Outcome.Pending || block.timestamp >= item.endsAt) revert WindowClosed();
        if (item.disputer != address(0)) revert AlreadyDisputed();
        if (msg.sender == item.resolver || correctedValue == item.originalValue) revert InvalidDispute();
        item.disputer = msg.sender;
        item.correctedValue = correctedValue;
        item.panelEndsAt = block.timestamp + PANEL_TIMEOUT;
        totalEscrow += BOND;
        _pull(msg.sender, BOND);
        IDisputedMarket(market).onDisputed(bountyId);
        emit Disputed(market, bountyId, msg.sender, correctedValue);
    }

    function vote(address market, uint256 bountyId, bool accept) external nonReentrant {
        Case storage item = _case(market, bountyId);
        _vote(market, bountyId, item, accept ? item.correctedValue : item.originalValue);
    }

    /// @notice Agree on the actual value even when both the resolver and first challenger are wrong.
    /// @dev Two votes must match the same value. Two different corrections are not a majority.
    function voteValue(address market, uint256 bountyId, int256 trueValue) external nonReentrant {
        _vote(market, bountyId, _case(market, bountyId), trueValue);
    }

    function _vote(address market, uint256 bountyId, Case storage item, int256 value) private {
        if (msg.sender != signer1 && msg.sender != signer2 && msg.sender != signer3) revert NotSigner();
        if (item.disputer == address(0)) revert NotDisputed();
        if (item.outcome != Outcome.Pending) revert AlreadyDecided();
        if (block.timestamp >= item.panelEndsAt) revert PanelExpired();
        if (hasVoted[market][bountyId][msg.sender]) revert AlreadyVoted();
        hasVoted[market][bountyId][msg.sender] = true;
        if (value != item.originalValue) ++item.acceptVotes;
        else ++item.rejectVotes;
        uint8 matching = ++valueVotes[market][bountyId][value];
        emit Voted(market, bountyId, msg.sender, value);
        if (matching == 2) {
            item.finalValue = value;
            _decide(market, bountyId, item, value == item.originalValue ? Outcome.Upheld : Outcome.Overturned);
        }
    }

    /// @notice Anyone can settle an expired window or a panel that failed to reach quorum.
    function finalize(address market, uint256 bountyId) external nonReentrant returns (Outcome) {
        Case storage item = _case(market, bountyId);
        if (item.outcome == Outcome.Pending) {
            if (item.disputer == address(0)) {
                if (block.timestamp < item.endsAt) revert WindowOpen();
                _decide(market, bountyId, item, Outcome.Uncontested);
            } else {
                if (block.timestamp < item.panelEndsAt) revert WindowOpen();
                _decide(market, bountyId, item, Outcome.TimedOut);
            }
        }
        return item.outcome;
    }

    function withdrawPayout() external nonReentrant {
        uint256 amount = credit[msg.sender];
        if (amount == 0) revert NoCredit();
        credit[msg.sender] = 0;
        totalCredits -= amount;
        token.safeTransfer(msg.sender, amount);
        emit PayoutWithdrawn(msg.sender, amount);
    }

    function getCase(address market, uint256 bountyId) external view returns (Case memory) {
        return _case(market, bountyId);
    }

    function _case(address market, uint256 bountyId) private view returns (Case storage item) {
        item = _cases[market][bountyId];
        if (item.resolver == address(0)) revert UnknownCase();
    }

    function _decide(address market, uint256 bountyId, Case storage item, Outcome outcome) private {
        item.outcome = outcome;
        if (outcome == Outcome.Uncontested) item.finalValue = item.originalValue;
        uint256 amount = item.disputer == address(0) ? BOND : 2 * BOND;
        totalEscrow -= amount;
        totalCredits += amount;
        if (outcome == Outcome.Overturned) {
            credit[item.disputer] += amount;
        } else if (outcome == Outcome.TimedOut) {
            credit[item.resolver] += BOND;
            credit[item.disputer] += BOND;
        } else {
            credit[item.resolver] += amount;
        }
        emit Decided(market, bountyId, outcome);
    }
}
