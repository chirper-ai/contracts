// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRouter
 * @dev Interface for Router contract that manages token swaps and liquidity operations
 */
interface IRouter {
    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enum to specify the type of DEX router
    enum RouterType {
        UniswapV2,
        UniswapV3,
        Velodrome
    }

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Router information for token graduation
    struct DexRouter {
        address routerAddress; // Address of the DEX router
        uint24 feeAmount;     // Fee amount for the DEX router
        uint24 weight;        // Weight for liquidity distribution (1-100)
        RouterType routerType; // Type of DEX router
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DexPoolsCreated(address indexed token, address[] pools);

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the router contract with required dependencies
     * @param factory_ Address of the factory contract
     * @param assetToken_ Address of the asset token
     * @param maxTxPercent_ Maximum transaction amount for a single swap
     */
    function initialize(
        address factory_,
        address assetToken_,
        uint256 maxTxPercent_
    ) external;

    /*//////////////////////////////////////////////////////////////
                         CORE TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes a buy operation with fee distribution
     * @param amountIn_ Amount of asset tokens to spend
     * @param tokenAddress_ Address of token to buy
     * @param to_ Address receiving the output tokens
     * @return Tuple of (input amount, output amount)
     */
    function buy(
        uint256 amountIn_,
        address tokenAddress_,
        address to_
    ) external returns (uint256, uint256);

    /**
     * @notice Executes a sell operation with fee distribution
     * @param amountIn_ Amount of tokens to sell
     * @param tokenAddress_ Address of token being sold
     * @param to_ Address receiving the output assets
     * @return Tuple of (input amount, output amount)
     */
    function sell(
        uint256 amountIn_,
        address tokenAddress_,
        address to_
    ) external returns (uint256, uint256);

    /**
     * @notice Adds initial liquidity to a trading pair
     * @param tokenAddress_ Token address to add liquidity for
     * @param amountToken_ Amount of tokens to add
     * @param amountAsset_ Amount of asset tokens to add
     * @return Tuple of (token amount, asset amount) added
     */
    function addInitialLiquidity(
        address tokenAddress_,
        uint256 amountToken_,
        uint256 amountAsset_
    ) external returns (uint256, uint256);

    /**
     * @notice Handles the graduation process for a token to external DEXes
     * @param tokenAddress_ Address of token to graduate
     * @param dexRouters_ Array of DEX routers to deploy to
     * @return pairs Array of created DEX pairs
     */
    function graduate(
        address tokenAddress_,
        DexRouter[] calldata dexRouters_
    ) external returns (address[] memory);

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the maximum transaction amount for a single swap
     * @param maxTxPercent_ Maximum transaction amount for a single swap
     */
    function setMaxTxPercent(uint256 maxTxPercent_) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the factory contract address
     * @return IFactory interface of the factory contract
     */
    function factory() external view returns (address);

    /**
     * @notice Gets the asset token address used for all trading pairs
     * @return Address of the asset token
     */
    function assetToken() external view returns (address);

    /**
     * @notice Gets the maximum transaction percentage allowed
     * @return Maximum transaction percentage
     */
    function maxTxPercent() external view returns (uint256);

    /**
     * @notice Gets the array of DEX pools for a given token
     * @param token The token address to query
     * @param index The index in the array
     * @return Address of the DEX pool at the given index
     */
    function tokenDexPools(address token, uint256 index) external view returns (address);

    /**
     * @notice Calculates output amount for a swap operation
     * @param token_ Token address being traded
     * @param assetToken_ Asset token address for direction
     * @param amountIn_ Amount of input tokens
     * @return Amount of output tokens
     */
    function getAmountsOut(
        address token_,
        address assetToken_,
        uint256 amountIn_
    ) external view returns (uint256);

    /**
     * @notice Approves token spending for a pair
     * @param pair_ Address of the pair
     * @param asset_ Address of the asset
     * @param spender_ Address allowed to spend
     * @param amount_ Amount to approve
     */
    function approve(
        address pair_,
        address asset_,
        address spender_,
        uint256 amount_
    ) external;
}