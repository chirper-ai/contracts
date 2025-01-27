// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRouter
 * @dev Interface for Router contract that handles token swaps for bonding pairs
 */
interface IRouter {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Emitted on successful swap
     * @param sender Address initiating the swap
     * @param agentToken Address of the agent token
     * @param amountIn Amount of input tokens
     * @param amountOut Amount of output tokens
     * @param isBuy True if buying agent tokens, false if selling
     */
    event Swap(
        address indexed sender,
        address indexed agentToken,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy
    );

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the router with required parameters
     * @param factory_ Factory contract address
     * @param assetToken_ Asset token address
     */
    function initialize(
        address factory_,
        address assetToken_
    ) external;

    /*//////////////////////////////////////////////////////////////
                         UNISWAP-STYLE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Swaps exact tokens for tokens supporting bonding curves
     * @param amountIn Exact amount of input tokens
     * @param amountOutMin Minimum output tokens to receive
     * @param path Trading path (must be length 2)
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amounts Array of amounts for path
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /**
     * @notice Swaps tokens for exact tokens supporting bonding curves
     * @param amountOut Exact amount of output tokens
     * @param amountInMax Maximum input tokens to spend
     * @param path Trading path (must be length 2)
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amounts Array of amounts for path
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /**
     * @notice Gets amounts out for a swap
     * @param amountIn Input amount
     * @param path Trading path
     * @return amounts Output amounts
     */
    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);

    /**
     * @notice Gets amounts in for a swap
     * @param amountOut Output amount
     * @param path Trading path
     * @return amounts Input amounts
     */
    function getAmountsIn(
        uint256 amountOut,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);

    /**
     * @notice adds initial liquidity to a bonding pair
     * @param agentToken_ Address of the agent token
     * @param assetToken_ Address of the asset token
     * @param amountAgentIn Amount of agent tokens being sold
     * @param amountAssetIn Amount of asset tokens being spent
     */
    function addInitialLiquidity(
        address agentToken_,
        address assetToken_,
        uint256 amountAgentIn,
        uint256 amountAssetIn
    ) external returns (uint256);

    /**
     * @notice Adds liquidity to a bonding pair
     * @param token Address of the agent token
     * @param tokenAmount Amount of agent tokens being added
     * @param assetAmount Amount of asset tokens being added
     */
    function transferLiquidityToManager(
        address token,
        uint256 tokenAmount,
        uint256 assetAmount
    ) external;

    /**
     * @notice Gets the factory contract address
     * @return IFactory Factory contract interface
     */
    function factory() external view returns (address);

    /**
     * @notice Gets the asset token address
     * @return address Asset token address
     */
    function assetToken() external view returns (address);
}