// SPDX-License-Identifier: MIT
// Created by chirper.build
pragma solidity ^0.8.20;

/**
 * @title IPair
 * @dev Interface for chirper.build liquidity pair contracts
 */
interface IPair {
    /**
     * @notice Gets the current reserves of the pair
     * @return Agent token reserve and asset token reserve
     */
    function getReserves() external view returns (uint256, uint256);

    /**
     * @notice Gets the asset token balance of the pair
     * @return Current asset token balance
     */
    function assetBalance() external view returns (uint256);

    /**
     * @notice Gets the agent token balance of the pair
     * @return Current agent token balance
     */
    function balance() external view returns (uint256);

    /**
     * @notice Initializes the pair with initial liquidity
     * @param agentAmount Amount of agent tokens
     * @param assetAmount Amount of asset tokens
     * @return Success boolean
     */
    function mint(
        uint256 agentAmount,
        uint256 assetAmount
    ) external returns (bool);

    /**
     * @notice Transfers asset tokens to a recipient
     * @param recipient Address to receive tokens
     * @param amount Amount to transfer
     */
    function transferAsset(
        address recipient,
        uint256 amount
    ) external;

    /**
     * @notice Transfers agent tokens to a recipient
     * @param recipient Address to receive tokens
     * @param amount Amount to transfer
     */
    function transferTo(
        address recipient,
        uint256 amount
    ) external;

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
    ) external returns (bool);

    /**
     * @notice Gets the constant product value
     * @return Current k value
     */
    function kLast() external view returns (uint256);

    /**
     * @notice Gets agent token price
     * @return Current agent token price
     */
    function agentPrice() external view returns (uint256);

    /**
     * @notice Gets asset token price
     * @return Current asset token price
     */
    function assetPrice() external view returns (uint256);

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
    ) external returns (bool);

    /**
     * @notice Gets the router address
     * @return Router contract address
     */
    function router() external view returns (address);

    /**
     * @notice Gets the agent token address
     * @return Agent token contract address
     */
    function agentToken() external view returns (address);

    /**
     * @notice Gets the asset token address
     * @return Asset token contract address
     */
    function assetToken() external view returns (address);
}