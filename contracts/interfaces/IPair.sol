// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPair
 * @dev Interface for the bonding curve automated market maker for agent tokens.
 * 
 * The bonding curve uses the formula: price = K / supply
 * Where:
 * - K is a constant that determines curve steepness
 * - supply is the current token supply in the pair
 */
interface IPair {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when reserves are updated
     * @param reserveAgent New agent token reserve
     * @param reserveAsset New asset token reserve
     */
    event ReservesUpdated(uint256 reserveAgent, uint256 reserveAsset);

    /**
     * @notice Emitted when graduation threshold is met
     * @param reserveRatio Final reserve ratio at graduation
     */
    event GraduationTriggered(uint256 reserveRatio);

    /**
     * @notice Emitted when tokens are swapped
     * @param sender Address initiating the swap
     * @param agentAmountIn Amount of agent tokens in (if selling)
     * @param assetAmountIn Amount of asset tokens in (if buying)
     * @param agentAmountOut Amount of agent tokens out (if buying)
     * @param assetAmountOut Amount of asset tokens out (if selling)
     */
    event Swap(
        address indexed sender,
        uint256 agentAmountIn,
        uint256 assetAmountIn,
        uint256 agentAmountOut,
        uint256 assetAmountOut
    );

    /*//////////////////////////////////////////////////////////////
                            STATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice The bonding curve constant K
    function K() external view returns (uint256);

    /// @notice The asset token rate in basis points
    function assetRate() external view returns (uint64);

    /// @notice The factory that created this pair
    function factory() external view returns (address);

    /// @notice The router contract that handles trading
    function router() external view returns (address);

    /// @notice The agent token in the pair
    function agentToken() external view returns (address);

    /// @notice The asset token in the pair (e.g., USDC)
    function assetToken() external view returns (address);

    /// @notice Flag indicating if graduation threshold has been met
    function isGraduated() external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                            TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes a swap according to bonding curve formula
     * @param agentAmountIn Amount of agent tokens being sold
     * @param assetAmountIn Amount of asset tokens being spent
     * @param agentAmountOut Minimum agent tokens to receive
     * @param assetAmountOut Minimum asset tokens to receive
     */
    function swap(
        uint256 agentAmountIn,
        uint256 assetAmountIn,
        uint256 agentAmountOut,
        uint256 assetAmountOut
    ) external;

    /// @notice The bonding curve reserve ratio threshold for graduation
    function sync() external;

    /**
     * @notice Transfers tokens from the pair
     * @param to Address to transfer to
     * @param amount Amount to transfer
     */
    function transferTo(
        address to,
        uint256 amount
    ) external;

    /**
     * @notice Transfers asset tokens from the pair
     * @param to Address to transfer to
     * @param amount Amount to transfer
     */
    function transferAsset(
        address to,
        uint256 amount
    ) external;

    /**
     * @notice Approves router to spend tokens
     * @param spender Address to approve
     * @param token Token to approve
     * @param amount Amount to approve
     */
    function approval(
        address spender,
        address token,
        uint256 amount
    ) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns current reserves
     * @return Agent token reserve
     * @return Asset token reserve
     * @return Last update timestamp
     */
    function getReserves() external view returns (
        uint256,
        uint256,
        uint32
    );

    /**
     * @notice Returns amount of agent tokens held by pair
     */
    function balance() external view returns (uint256);

    /**
     * @notice Returns amount of asset tokens held by pair
     */
    function assetBalance() external view returns (uint256);

    /**
     * @notice Calculates output amount of agent tokens for given input of asset tokens
     * @param assetAmountIn Amount of asset tokens to spend
     * @return Amount of agent tokens received
     */
    function getAgentAmountOut(
        uint256 assetAmountIn
    ) external view returns (uint256);

    /**
     * @notice Calculates output amount of asset tokens for given input of agent tokens
     * @param agentAmountIn Amount of agent tokens to sell
     * @return Amount of asset tokens received
     */
    function getAssetAmountOut(
        uint256 agentAmountIn
    ) external view returns (uint256);
}