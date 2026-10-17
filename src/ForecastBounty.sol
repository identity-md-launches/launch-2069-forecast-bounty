// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenPool, IERC20, SafeERC20} from "./lib/TokenPool.sol";
import {DeploymentConfig} from "./DeploymentConfig.sol";
import {BountyRegistry} from "./BountyRegistry.sol";
import {ResolverStake} from "./ResolverStake.sol";
import {DisputeWindow} from "./DisputeWindow.sol";

contract ForecastBounty is TokenPool {
    using SafeERC20 for IERC20;

    struct Bounty {
        address creator;
        uint256 reward;
        uint256 deadline;
        string question;
        string resolutionSource;
        BountyRegistry.State state;
        int256 trueValue;
        address winner;
        bool hasResolved;
        bool rewardPaid;
        bool resolutionOverturned;
    }

    struct Entry {
        address forecaster;
        int256 value;
    }

    BountyRegistry public immutable registry;
    ResolverStake public immutable resolverStake;
    DisputeWindow public immutable disputeWindow;
    uint256 public immutable MIN_REWARD;
    uint256 public immutable BOND;
    uint256 public immutable MAX_ENTRIES;
    uint256 public constant RESOLUTION_TIMEOUT = DeploymentConfig.RESOLUTION_TIMEOUT;
    uint256 public bountyCount;
    uint256 public rewardLiability;
    uint256 public bondLiability;
    mapping(uint256 id => Bounty) private _bounties;
    mapping(uint256 id => Entry[]) private _entries;
    mapping(uint256 id => mapping(address forecaster => uint256 indexPlusOne)) private _entryIndex;
    mapping(uint256 id => mapping(address forecaster => bool)) public bondWithdrawn;

    error UnknownBounty();
    error InvalidDeadline();
    error RewardTooSmall();
    error EmptyQuestion();
    error EmptySource();
    error NotOpen();
    error EntriesClosed();
    error AlreadyForecast();
    error MaxEntries();
    error NotCreator();
    error BeforeDeadline();
    error ResolutionExpired();
    error NotResolved();
    error ForecastsHidden();
    error NoForecast();
    error AlreadyWithdrawn();
    error NotWinner();
    error RewardAlreadyPaid();
    error NotRefundable();
    error NotDisputeWindow();
    error AlreadyFinalized();
    error NotExpired();
    error ComponentMismatch();

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed creator,
        string question,
        uint256 deadline,
        string resolutionSource,
        uint256 reward
    );
    event ForecastSubmitted(uint256 indexed bountyId, address indexed forecaster);
    event BountyResolved(uint256 indexed bountyId, int256 trueValue, address indexed winner);
    event BountyDisputed(uint256 indexed bountyId);
    event BountyFinalized(uint256 indexed bountyId, int256 trueValue, address indexed winner, bool overturned);
    event BountyExpired(uint256 indexed bountyId);
    event ResolutionTimedOut(uint256 indexed bountyId);
    event RewardClaimed(uint256 indexed bountyId, address indexed winner, uint256 amount);
    event RewardRefunded(uint256 indexed bountyId, address indexed creator, uint256 amount);
    event BondWithdrawn(uint256 indexed bountyId, address indexed forecaster, uint256 amount);

    constructor(
        address token_,
        address registry_,
        address resolverStake_,
        address disputeWindow_,
        uint256 minReward_,
        uint256 bond_,
        uint256 maxEntries_
    ) TokenPool(token_) {
        if (registry_ == address(0) || resolverStake_ == address(0) || disputeWindow_ == address(0)) revert ZeroAddress();
        if (minReward_ == 0 || bond_ == 0 || maxEntries_ == 0 || maxEntries_ > 500) revert InvalidParameters();
        registry = BountyRegistry(registry_);
        resolverStake = ResolverStake(resolverStake_);
        disputeWindow = DisputeWindow(disputeWindow_);
        MIN_REWARD = minReward_;
        BOND = bond_;
        MAX_ENTRIES = maxEntries_;
    }

    function createBounty(string calldata question, uint256 deadline, string calldata resolutionSource, uint256 reward)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (deadline <= block.timestamp || deadline > type(uint256).max - RESOLUTION_TIMEOUT) revert InvalidDeadline();
        if (reward < MIN_REWARD) revert RewardTooSmall();
        if (bytes(question).length == 0) revert EmptyQuestion();
        if (bytes(resolutionSource).length == 0) revert EmptySource();
        id = ++bountyCount;
        Bounty storage item = _bounties[id];
        item.creator = msg.sender;
        item.reward = reward;
        item.deadline = deadline;
        item.question = question;
        item.resolutionSource = resolutionSource;
        rewardLiability += reward;
        _pull(msg.sender, reward);
        uint256 indexedId = registry.append(msg.sender, keccak256(bytes(question)), reward, deadline);
        if (indexedId != id) revert ComponentMismatch();
        emit BountyCreated(id, msg.sender, question, deadline, resolutionSource, reward);
    }

    function forecast(uint256 bountyId, int256 value) external nonReentrant {
        Bounty storage item = _bounty(bountyId);
        if (item.state != BountyRegistry.State.Open) revert NotOpen();
        if (block.timestamp >= item.deadline) revert EntriesClosed();
        if (_entryIndex[bountyId][msg.sender] != 0) revert AlreadyForecast();
        if (_entries[bountyId].length >= MAX_ENTRIES) revert MaxEntries();
        _entries[bountyId].push(Entry(msg.sender, value));
        _entryIndex[bountyId][msg.sender] = _entries[bountyId].length;
        bondLiability += BOND;
        _pull(msg.sender, BOND);
        // Values are intentionally absent from events and all pre-resolution getters.
        emit ForecastSubmitted(bountyId, msg.sender);
    }

    /// @notice The creator resolves after entries close, backed by stake and a separate resolution bond.
    function resolve(uint256 bountyId, int256 trueValue) external nonReentrant {
        Bounty storage item = _bounty(bountyId);
        if (msg.sender != item.creator) revert NotCreator();
        if (item.state != BountyRegistry.State.Open) revert NotOpen();
        if (block.timestamp < item.deadline) revert BeforeDeadline();
        if (block.timestamp >= item.deadline + RESOLUTION_TIMEOUT) revert ResolutionExpired();
        if (
            address(resolverStake.token()) != address(token) || address(disputeWindow.token()) != address(token)
                || disputeWindow.BOND() != BOND
        ) revert ComponentMismatch();
        item.hasResolved = true;
        item.state = BountyRegistry.State.Resolved;
        item.trueValue = trueValue;
        item.winner = _closest(bountyId, trueValue);
        resolverStake.lock(bountyId, msg.sender);
        _pull(msg.sender, BOND);
        token.forceApprove(address(disputeWindow), BOND);
        disputeWindow.open(bountyId, msg.sender, trueValue);
        registry.transition(bountyId, BountyRegistry.State.Resolved, trueValue);
        emit BountyResolved(bountyId, trueValue, item.winner);
    }

    function onDisputed(uint256 bountyId) external nonReentrant {
        if (msg.sender != address(disputeWindow)) revert NotDisputeWindow();
        Bounty storage item = _bounty(bountyId);
        if (item.state != BountyRegistry.State.Resolved) revert NotResolved();
        item.state = BountyRegistry.State.Disputed;
        registry.transition(bountyId, BountyRegistry.State.Disputed, item.trueValue);
        emit BountyDisputed(bountyId);
    }

    function finalize(uint256 bountyId) external nonReentrant {
        _finalize(bountyId, _bounty(bountyId));
    }

    function claim(uint256 bountyId) external nonReentrant {
        Bounty storage item = _bounty(bountyId);
        if (item.state == BountyRegistry.State.Resolved || item.state == BountyRegistry.State.Disputed) {
            _finalize(bountyId, item);
        }
        if (item.state != BountyRegistry.State.Finalized) revert NotResolved();
        if (item.winner != msg.sender) revert NotWinner();
        if (item.rewardPaid) revert RewardAlreadyPaid();
        item.rewardPaid = true;
        rewardLiability -= item.reward;
        token.safeTransfer(msg.sender, item.reward);
        emit RewardClaimed(bountyId, msg.sender, item.reward);
    }

    /// @notice Participant bonds are independent of the reward and arbitration bonds.
    function withdrawBond(uint256 bountyId) external nonReentrant {
        Bounty storage item = _bounty(bountyId);
        if (_entryIndex[bountyId][msg.sender] == 0) revert NoForecast();
        if (!item.hasResolved && item.state != BountyRegistry.State.Refunded) {
            if (block.timestamp < item.deadline + RESOLUTION_TIMEOUT) revert NotResolved();
            _expire(bountyId, item);
        }
        if (bondWithdrawn[bountyId][msg.sender]) revert AlreadyWithdrawn();
        bondWithdrawn[bountyId][msg.sender] = true;
        bondLiability -= BOND;
        token.safeTransfer(msg.sender, BOND);
        emit BondWithdrawn(bountyId, msg.sender, BOND);
    }

    function refundReward(uint256 bountyId) external nonReentrant {
        Bounty storage item = _bounty(bountyId);
        if (msg.sender != item.creator) revert NotCreator();
        if (item.rewardPaid) revert RewardAlreadyPaid();
        if (item.state == BountyRegistry.State.Open) {
            if (block.timestamp < item.deadline) revert BeforeDeadline();
            _expire(bountyId, item);
        } else if (item.state != BountyRegistry.State.Refunded && !(item.hasResolved && _entries[bountyId].length == 0))
        {
            revert NotRefundable();
        }
        item.rewardPaid = true;
        rewardLiability -= item.reward;
        token.safeTransfer(msg.sender, item.reward);
        emit RewardRefunded(bountyId, msg.sender, item.reward);
    }

    /// @notice A silent creator cannot hold bonds forever. Anyone can expire after seven days.
    function expire(uint256 bountyId) external nonReentrant {
        Bounty storage item = _bounty(bountyId);
        if (block.timestamp < item.deadline + RESOLUTION_TIMEOUT) revert NotExpired();
        _expire(bountyId, item);
    }

    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        return _bounty(bountyId);
    }

    function entryCount(uint256 bountyId) external view returns (uint256) {
        _bounty(bountyId);
        return _entries[bountyId].length;
    }

    function hasForecast(uint256 bountyId, address forecaster) external view returns (bool) {
        return _entryIndex[bountyId][forecaster] != 0;
    }

    function entryAt(uint256 bountyId, uint256 index) external view returns (Entry memory) {
        if (!_bounty(bountyId).hasResolved) revert ForecastsHidden();
        return _entries[bountyId][index];
    }

    function forecastOf(uint256 bountyId, address forecaster) external view returns (int256) {
        if (!_bounty(bountyId).hasResolved) revert ForecastsHidden();
        uint256 index = _entryIndex[bountyId][forecaster];
        if (index == 0) revert NoForecast();
        return _entries[bountyId][index - 1].value;
    }

    function isClosed(uint256 bountyId) external view returns (bool) {
        BountyRegistry.State state = _bounty(bountyId).state;
        return state == BountyRegistry.State.Finalized || state == BountyRegistry.State.Refunded;
    }

    function _finalize(uint256 bountyId, Bounty storage item) private {
        if (item.state != BountyRegistry.State.Resolved && item.state != BountyRegistry.State.Disputed) {
            revert AlreadyFinalized();
        }
        DisputeWindow.Outcome outcome = disputeWindow.finalize(address(this), bountyId);
        DisputeWindow.Case memory decision = disputeWindow.getCase(address(this), bountyId);
        bool overturned = outcome == DisputeWindow.Outcome.Overturned;
        item.resolutionOverturned = overturned;
        // A panel that never reaches quorum leaves the original resolution standing, unslashed.
        if (overturned) {
            item.trueValue = decision.finalValue;
            item.winner = _closest(bountyId, item.trueValue);
        }
        item.state = BountyRegistry.State.Finalized;
        registry.transition(bountyId, BountyRegistry.State.Finalized, item.trueValue);
        if (outcome == DisputeWindow.Outcome.TimedOut) emit ResolutionTimedOut(bountyId);
        emit BountyFinalized(bountyId, item.trueValue, item.winner, overturned);
        // The slash goes to the disputer when the panel matched the disputer's own value. When the panel chose a
        // third value, the disputer's claim was wrong too (possibly a resolver's sock filling the slot), so the
        // slash goes to the corrected winner, the forecaster the wrong resolution harmed. The overturned resolver
        // never receives its own slash, and an overturned resolution is always slashed: when the corrected winner
        // is the resolver itself (a creator forecasting on its own bounty) or there is no winner (no entries), the
        // slash falls back to the disputer, whose challenge still succeeded.
        address slashTo = decision.disputer;
        if (
            overturned && decision.correctedValue != decision.finalValue && item.winner != address(0)
                && item.winner != decision.resolver
        ) slashTo = item.winner;
        resolverStake.settle(bountyId, overturned, slashTo);
    }

    function _expire(uint256 bountyId, Bounty storage item) private {
        if (item.state != BountyRegistry.State.Open) revert NotOpen();
        item.state = BountyRegistry.State.Refunded;
        registry.transition(bountyId, BountyRegistry.State.Refunded, 0);
        emit BountyExpired(bountyId);
    }

    function _bounty(uint256 bountyId) private view returns (Bounty storage item) {
        item = _bounties[bountyId];
        if (item.creator == address(0)) revert UnknownBounty();
    }

    /// @dev XOR maps signed order into unsigned order; the distance fits even across both int256 extremes.
    function _closest(uint256 bountyId, int256 trueValue) private view returns (address winner) {
        Entry[] storage entries = _entries[bountyId];
        uint256 target = uint256(trueValue) ^ (uint256(1) << 255);
        uint256 smallest = type(uint256).max;
        for (uint256 i; i < entries.length; ++i) {
            uint256 value = uint256(entries[i].value) ^ (uint256(1) << 255);
            uint256 distance = value >= target ? value - target : target - value;
            if (i == 0 || distance < smallest) {
                smallest = distance;
                winner = entries[i].forecaster;
            }
        }
    }
}
