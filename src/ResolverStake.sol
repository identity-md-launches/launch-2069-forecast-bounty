// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenPool, IERC20, SafeERC20} from "./lib/TokenPool.sol";

/// @notice Resolver deposits are explicitly scoped to a market selected by the depositor.
/// @dev Only that market can lock/slash its deposits; a counterfeit market has an isolated ledger.
contract ResolverStake is TokenPool {
    using SafeERC20 for IERC20;

    struct Lock {
        address resolver;
        uint256 slashAmount;
        bool active;
    }

    uint256 public immutable RESOLVER_STAKE;
    uint256 public immutable SLASH_BPS;
    uint256 public totalStaked;
    mapping(address market => mapping(address resolver => uint256)) public stakeOf;
    mapping(address market => mapping(address resolver => uint256)) public activeLocks;
    mapping(address market => mapping(address resolver => uint256)) public reserved;
    mapping(address market => mapping(uint256 bountyId => Lock)) public locks;

    error InsufficientStake();
    error StakeLocked();
    error ExistingLock();
    error UnknownLock();

    event Deposited(address indexed market, address indexed resolver, address indexed donor, uint256 amount);
    event Withdrawn(address indexed market, address indexed resolver, uint256 amount);
    event Locked(address indexed market, uint256 indexed bountyId, address indexed resolver, uint256 slashAmount);
    event Released(address indexed market, uint256 indexed bountyId);
    event Slashed(address indexed market, uint256 indexed bountyId, address indexed disputer, uint256 amount);

    constructor(address token_, uint256 resolverStake_, uint256 slashBps_) TokenPool(token_) {
        if (resolverStake_ == 0 || slashBps_ == 0 || slashBps_ > 10_000) revert InvalidParameters();
        RESOLVER_STAKE = resolverStake_;
        SLASH_BPS = slashBps_;
    }

    function deposit(address market, uint256 amount) external nonReentrant {
        _deposit(market, msg.sender, amount);
    }

    function depositFor(address market, address resolver, uint256 amount) external nonReentrant {
        _deposit(market, resolver, amount);
    }

    function _deposit(address market, address resolver, uint256 amount) private {
        if (market == address(0) || resolver == address(0)) revert ZeroAddress();
        _pull(msg.sender, amount);
        stakeOf[market][resolver] += amount;
        totalStaked += amount;
        emit Deposited(market, resolver, msg.sender, amount);
    }

    function withdraw(address market, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (activeLocks[market][msg.sender] != 0) revert StakeLocked();
        if (stakeOf[market][msg.sender] < amount) revert InsufficientStake();
        stakeOf[market][msg.sender] -= amount;
        totalStaked -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(market, msg.sender, amount);
    }

    /// @dev Reserve the slash at resolution time so concurrent disputes cannot exhaust its backing.
    function lock(uint256 bountyId, address resolver) external nonReentrant {
        if (locks[msg.sender][bountyId].resolver != address(0)) revert ExistingLock();
        uint256 balance = stakeOf[msg.sender][resolver];
        if (balance < RESOLVER_STAKE) revert InsufficientStake();
        // Quotient/remainder form avoids overflowing even for an arbitrary uint256 token balance.
        uint256 slashAmount = (balance / 10_000) * SLASH_BPS + ((balance % 10_000) * SLASH_BPS) / 10_000;
        if (slashAmount > balance - reserved[msg.sender][resolver]) revert InsufficientStake();
        reserved[msg.sender][resolver] += slashAmount;
        ++activeLocks[msg.sender][resolver];
        locks[msg.sender][bountyId] = Lock(resolver, slashAmount, true);
        emit Locked(msg.sender, bountyId, resolver, slashAmount);
    }

    function settle(uint256 bountyId, bool slash, address disputer) external nonReentrant returns (uint256 amount) {
        Lock storage position = locks[msg.sender][bountyId];
        if (!position.active) revert UnknownLock();
        if (slash && disputer == address(0)) revert ZeroAddress();
        position.active = false;
        address resolver = position.resolver;
        --activeLocks[msg.sender][resolver];
        reserved[msg.sender][resolver] -= position.slashAmount;
        if (slash) {
            amount = position.slashAmount;
            stakeOf[msg.sender][resolver] -= amount;
            totalStaked -= amount;
            token.safeTransfer(disputer, amount);
            emit Slashed(msg.sender, bountyId, disputer, amount);
        }
        emit Released(msg.sender, bountyId);
    }
}
