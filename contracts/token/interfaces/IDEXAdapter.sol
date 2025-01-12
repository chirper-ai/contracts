// file: contracts/interfaces/IDEXAdapter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IDEXAdapter
 * @author YourName
 * @notice Interface for DEX adapters used in graduation
 * @dev Standardizes interaction with different DEX implementations
 */
interface IDEXAdapter {
    /**
     * @notice Parameters for liquidity operations
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param amountA Amount of first token
     * @param amountB Amount of second token
     * @param minAmountA Minimum amount of first token (slippage)
     * @param minAmountB Minimum amount of second token (slippage)
     * @param to Recipient of LP tokens
     * @param deadline Maximum timestamp for execution
     */
    struct LiquidityParams {
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint256 minAmountA;
        uint256 minAmountB;
        address to;
        uint256 deadline;
    }

    /**
     * @notice Adds liquidity to DEX pair
     * @param params Liquidity parameters
     * @return amountA Amount of tokenA used
     * @return amountB Amount of tokenB used
     * @return liquidity Amount of LP tokens minted
     */
    function addLiquidity(
        LiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /**
     * @notice Gets the name of the DEX
     * @return Name identifier
     */
    function getDEXName() external pure returns (string memory);

    /**
     * @notice Gets the router contract address
     * @return Router address
     */
    function getRouterAddress() external view returns (address);

    /**
     * @notice Gets the factory contract address
     * @return Factory address
     */
    function getFactoryAddress() external view returns (address);

    /**
     * @notice Gets pair address for two tokens
     * @param tokenA First token
     * @param tokenB Second token
     * @return Pair address
     */
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address);
}