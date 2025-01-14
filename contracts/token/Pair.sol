// SPDX-License-Identifier: MIT
// Created by chirper.build
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./IPair.sol";

/**
 * @title Pair
 * @dev Manages liquidity pairs for the chirper.build platform
 */
contract Pair is IPair, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Router contract address
    address public immutable router;
    
    /// @notice First token in the pair (Agent token)
    address public immutable agentToken;
    
    /// @notice Second token in the pair (Asset token)
    address public immutable assetToken;

    /**
     * @notice Pool state for the liquidity pair
     * @dev Stores the current reserves and constant product
     */
    struct Pool {
        uint256 reserveAgent;   // Reserve of the agent token
        uint256 reserveAsset;   // Reserve of the asset token
        uint256 k;              // Constant product (k = x * y)
        uint256 lastUpdate;     // Last update timestamp
    }

    /// @notice Current pool state
    Pool private pool;

    /// @notice Emitted on initial liquidity provision
    event Mint(uint256 agentAmount, uint256 assetAmount);

    /// @notice Emitted on swap operations
    event Swap(
        uint256 agentAmountIn,
        uint256 agentAmountOut,
        uint256 assetAmountIn,
        uint256 assetAmountOut
    );

    /**
     * @notice Creates a new pair
     * @param routerAddress Address of the router contract
     * @param agentTokenAddress Address of the agent token
     * @param assetTokenAddress Address of the asset token
     */
    constructor(
        address routerAddress,
        address agentTokenAddress,
        address assetTokenAddress
    ) {
        require(routerAddress != address(0), "Invalid router");
        require(agentTokenAddress != address(0), "Invalid agent token");
        require(assetTokenAddress != address(0), "Invalid asset token");

        router = routerAddress;
        agentToken = agentTokenAddress;
        assetToken = assetTokenAddress;
    }

    /**
     * @notice Restricts function to router only
     */
    modifier onlyRouter() {
        require(router == msg.sender, "Router only");
        _;
    }

    /**
     * @notice Initializes the pool with initial liquidity
     * @param agentAmount Amount of agent tokens
     * @param assetAmount Amount of asset tokens
     * @return Success boolean
     */
    function mint(
        uint256 agentAmount,
        uint256 assetAmount
    ) external onlyRouter returns (bool) {
        require(pool.lastUpdate == 0, "Already initialized");

        pool = Pool({
            reserveAgent: agentAmount,
            reserveAsset: assetAmount,
            k: agentAmount * assetAmount,
            lastUpdate: block.timestamp
        });

        emit Mint(agentAmount, assetAmount);
        return true;
    }

    /**
     * @notice Executes a swap between the pair tokens
     * @param agentAmountIn Amount of agent tokens being added
     * @param agentAmountOut Amount of agent tokens being removed
     * @param assetAmountIn Amount of asset tokens being added
     * @param assetAmountOut Amount of asset tokens being removed
     * @return Success boolean
     */
    function swap(
        uint256 agentAmountIn,
        uint256 agentAmountOut,
        uint256 assetAmountIn,
        uint256 assetAmountOut
    ) external onlyRouter returns (bool) {
        uint256 newReserveAgent = (pool.reserveAgent + agentAmountIn) - agentAmountOut;
        uint256 newReserveAsset = (pool.reserveAsset + assetAmountIn) - assetAmountOut;

        pool = Pool({
            reserveAgent: newReserveAgent,
            reserveAsset: newReserveAsset,
            k: pool.k,
            lastUpdate: block.timestamp
        });

        emit Swap(agentAmountIn, agentAmountOut, assetAmountIn, assetAmountOut);
        return true;
    }

    /**
     * @notice Approves token spending
     * @param spender Address to approve
     * @param token Token to approve
     * @param amount Amount to approve
     * @return Success boolean
     */
    function approval(
        address spender,
        address token,
        uint256 amount
    ) external onlyRouter returns (bool) {
        require(spender != address(0), "Invalid spender");
        require(token != address(0), "Invalid token");

        IERC20(token).forceApprove(spender, amount);
        return true;
    }

    /**
     * @notice Transfers asset tokens
     * @param recipient Recipient address
     * @param amount Amount to transfer
     */
    function transferAsset(
        address recipient,
        uint256 amount
    ) external onlyRouter {
        require(recipient != address(0), "Invalid recipient");
        IERC20(assetToken).safeTransfer(recipient, amount);
    }

    /**
     * @notice Transfers agent tokens
     * @param recipient Recipient address
     * @param amount Amount to transfer
     */
    function transferTo(
        address recipient,
        uint256 amount
    ) external onlyRouter {
        require(recipient != address(0), "Invalid recipient");
        IERC20(agentToken).safeTransfer(recipient, amount);
    }

    /**
     * @notice Gets current reserves
     * @return Agent token reserve and asset token reserve
     */
    function getReserves() external view returns (uint256, uint256) {
        return (pool.reserveAgent, pool.reserveAsset);
    }

    /**
     * @notice Gets constant product value
     * @return k value
     */
    function kLast() external view returns (uint256) {
        return pool.k;
    }

    /**
     * @notice Gets agent token price in terms of asset token
     * @return Price ratio
     */
    function agentPrice() external view returns (uint256) {
        return pool.reserveAsset / pool.reserveAgent;
    }

    /**
     * @notice Gets asset token price in terms of agent token
     * @return Price ratio
     */
    function assetPrice() external view returns (uint256) {
        return pool.reserveAgent / pool.reserveAsset;
    }

    /**
     * @notice Gets agent token balance
     * @return Balance amount
     */
    function balance() external view returns (uint256) {
        return IERC20(agentToken).balanceOf(address(this));
    }

    /**
     * @notice Gets asset token balance
     * @return Balance amount
     */
    function assetBalance() external view returns (uint256) {
        return IERC20(assetToken).balanceOf(address(this));
    }
}