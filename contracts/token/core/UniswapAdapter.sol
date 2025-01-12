// file: contracts/token/core/UniswapAdapter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IDEXAdapter.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IUniswapV2Factory.sol";
import "../libraries/ErrorLibrary.sol";
import "../libraries/Constants.sol";

/**
 * @title UniswapAdapter
 * @author ChirperAI
 * @notice Adapter implementation for Uniswap V2 and compatible DEX protocols
 * @dev Implements IDEXAdapter interface with Uniswap V2 specific logic
 * - Handles liquidity addition for token graduation
 * - Manages router and factory interactions
 * - Implements safety checks and deadline handling
 */
contract UniswapAdapter is IDEXAdapter {
    using SafeERC20 for IERC20;

    /// @notice Immutable Uniswap V2 Router address
    /// @dev Set during construction and cannot be changed
    address public immutable router;
    
    /// @notice Immutable Uniswap V2 Factory address
    /// @dev Retrieved from router during construction
    address public immutable factory;

    /**
     * @notice Creates new Uniswap adapter instance
     * @dev Validates router and retrieves factory
     * @param router_ Address of Uniswap V2 Router contract
     */
    constructor(address router_) {
        // Validate router address
        ErrorLibrary.validateAddress(router_, "router");
        router = router_;

        // Get and validate factory address
        address factoryAddr = IUniswapV2Router02(router_).factory();
        ErrorLibrary.validateAddress(factoryAddr, "factory");
        factory = factoryAddr;
    }

    /**
     * @notice Adds liquidity to Uniswap pair
     * @dev Handles token approvals and liquidity addition with safety checks
     * @param params Liquidity parameters including amounts and deadlines
     * @return amountA Amount of tokenA actually used
     * @return amountB Amount of tokenB actually used
     * @return liquidity Amount of LP tokens minted
     */
    function addLiquidity(
        LiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Validate parameters
        ErrorLibrary.validateAddress(params.tokenA, "tokenA");
        ErrorLibrary.validateAddress(params.tokenB, "tokenB");
        ErrorLibrary.validateAddress(params.to, "to");
        ErrorLibrary.validateAmount(params.amountA, "amountA");
        ErrorLibrary.validateAmount(params.amountB, "amountB");
        ErrorLibrary.validateDeadline(params.deadline);

        // Validate minimum amounts against slippage tolerance
        if (params.minAmountA < (params.amountA * Constants.MIN_GRADUATION_SLIPPAGE) / Constants.BASIS_POINTS) {
            revert ErrorLibrary.InvalidAmount(params.minAmountA, "minAmountA too low");
        }
        if (params.minAmountB < (params.amountB * Constants.MIN_GRADUATION_SLIPPAGE) / Constants.BASIS_POINTS) {
            revert ErrorLibrary.InvalidAmount(params.minAmountB, "minAmountB too low");
        }

        // Handle token approvals with safety checks
        try IERC20(params.tokenA).forceApprove(router, params.amountA) {} catch {
            revert ErrorLibrary.TokenTransferFailed(params.tokenA, address(this), router);
        }
        try IERC20(params.tokenB).forceApprove(router, params.amountB) {} catch {
            revert ErrorLibrary.TokenTransferFailed(params.tokenB, address(this), router);
        }

        // Add liquidity through router with full error handling
        try IUniswapV2Router02(router).addLiquidity(
            params.tokenA,
            params.tokenB,
            params.amountA,
            params.amountB,
            params.minAmountA,
            params.minAmountB,
            params.to,
            params.deadline
        ) returns (uint256 _amountA, uint256 _amountB, uint256 _liquidity) {
            // Store return values
            amountA = _amountA;
            amountB = _amountB;
            liquidity = _liquidity;
        } catch {
            revert ErrorLibrary.DexOperationFailed(
                "addLiquidity",
                "Router operation failed"
            );
        }

        // Clear approvals for safety
        try IERC20(params.tokenA).forceApprove(router, 0) {} catch {
            revert ErrorLibrary.TokenTransferFailed(params.tokenA, address(this), router);
        }
        try IERC20(params.tokenB).forceApprove(router, 0) {} catch {
            revert ErrorLibrary.TokenTransferFailed(params.tokenB, address(this), router);
        }

        // Validate returned amounts against minimums
        if (amountA < params.minAmountA) {
            revert ErrorLibrary.ExcessiveSlippage(params.minAmountA, amountA);
        }
        if (amountB < params.minAmountB) {
            revert ErrorLibrary.ExcessiveSlippage(params.minAmountB, amountB);
        }
    }

    /**
     * @notice Returns identifier for this DEX implementation
     * @return String identifier for the DEX
     */
    function getDEXName() external pure returns (string memory) {
        return "UniswapV2";
    }

    /**
     * @notice Gets the router contract address
     * @return Address of UniswapV2Router02 contract
     */
    function getRouterAddress() external view returns (address) {
        return router;
    }

    /**
     * @notice Gets the factory contract address
     * @return Address of UniswapV2Factory contract
     */
    function getFactoryAddress() external view returns (address) {
        return factory;
    }

    /**
     * @notice Gets pair address for token combination
     * @dev Queries factory for existing pair
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return Address of pair contract
     */
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address) {
        // Validate input addresses
        ErrorLibrary.validateAddress(tokenA, "tokenA");
        ErrorLibrary.validateAddress(tokenB, "tokenB");
        
        // Get pair from factory
        address pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        
        // Validate pair exists
        if (pair == address(0)) {
            revert ErrorLibrary.InvalidOperation("getPair: Pair does not exist");
        }
        
        return pair;
    }
}