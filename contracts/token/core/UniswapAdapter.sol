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
 * @dev This contract serves as an adapter between the bonding curve system and Uniswap V2-compatible DEXes.
 * It implements the IDEXAdapter interface and handles:
 * - Safe liquidity addition with slippage protection
 * - Token approvals using SafeERC20
 * - Router and factory interactions
 * - Comprehensive error handling and validation
 *
 * Key features:
 * - Immutable router and factory addresses for security
 * - SafeERC20 integration for safe token operations
 * - Precise approval management to minimize attack surface
 * - Comprehensive parameter validation
 * - Slippage protection for liquidity operations
 */
contract UniswapAdapter is IDEXAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Immutable Uniswap V2 Router address
    /// @dev Set during construction and cannot be changed
    address public immutable router;
    
    /// @notice Immutable Uniswap V2 Factory address
    /// @dev Retrieved from router during construction
    address public immutable factory;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates new Uniswap adapter instance
     * @dev Validates router address and retrieves factory address
     * @param router_ Address of Uniswap V2 Router contract
     */
    constructor(address router_) {
        ErrorLibrary.validateAddress(router_, "router");
        router = router_;

        address factoryAddr = IUniswapV2Router02(router_).factory();
        ErrorLibrary.validateAddress(factoryAddr, "factory");
        factory = factoryAddr;
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDITY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds liquidity to Uniswap pair with comprehensive safety checks
     * @dev This function:
     * 1. Validates all input parameters
     * 2. Checks minimum amounts against maximum allowed slippage
     * 3. Safely manages token approvals
     * 4. Adds liquidity through the router
     * 5. Cleans up approvals afterward
     * 6. Validates returned amounts
     *
     * Safety measures:
     * - Uses SafeERC20 for all token operations
     * - Precise approval management
     * - Comprehensive error handling
     * - Slippage protection
     * - Deadline enforcement
     *
     * @param params Struct containing all liquidity addition parameters
     * @return amountA Amount of tokenA actually used
     * @return amountB Amount of tokenB actually used
     * @return liquidity Amount of LP tokens minted
     */
    function addLiquidity(
        LiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // STEP 1: Validate all input parameters
        ErrorLibrary.validateAddress(params.tokenA, "tokenA");
        ErrorLibrary.validateAddress(params.tokenB, "tokenB");
        ErrorLibrary.validateAddress(params.to, "to");
        ErrorLibrary.validateAmount(params.amountA, "amountA");
        ErrorLibrary.validateAmount(params.amountB, "amountB");
        ErrorLibrary.validateDeadline(params.deadline);

        // STEP 2: Validate minimum amounts against maximum allowed slippage
        // Ensures the specified minimum amounts don't allow for excessive slippage
        if (params.minAmountA < (params.amountA * Constants.MAX_GRADUATION_SLIPPAGE) / Constants.BASIS_POINTS) {
            revert ErrorLibrary.InvalidAmount(params.minAmountA, "minAmountA too low");
        }
        if (params.minAmountB < (params.amountB * Constants.MAX_GRADUATION_SLIPPAGE) / Constants.BASIS_POINTS) {
            revert ErrorLibrary.InvalidAmount(params.minAmountB, "minAmountB too low");
        }

        // STEP 3: Approve exact amounts needed for the operation
        IERC20(params.tokenA).safeIncreaseAllowance(router, params.amountA);
        IERC20(params.tokenB).safeIncreaseAllowance(router, params.amountB);

        // STEP 4: Add liquidity through router with full error handling
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
            amountA = _amountA;
            amountB = _amountB;
            liquidity = _liquidity;
        } catch {
            // If operation fails, reset approvals before reverting
            IERC20(params.tokenA).safeDecreaseAllowance(router, params.amountA);
            IERC20(params.tokenB).safeDecreaseAllowance(router, params.amountB);
            revert ErrorLibrary.DexOperationFailed(
                "addLiquidity",
                "Router operation failed"
            );
        }

        // STEP 5: Clean up any remaining approvals
        // Only decrease by the unused amount to save gas
        if (params.amountA > amountA) {
            IERC20(params.tokenA).safeDecreaseAllowance(router, params.amountA - amountA);
        }
        if (params.amountB > amountB) {
            IERC20(params.tokenB).safeDecreaseAllowance(router, params.amountB - amountB);
        }

        // STEP 6: Final validation of received amounts
        if (amountA < params.minAmountA) {
            revert ErrorLibrary.ExcessiveSlippage(params.minAmountA, amountA);
        }
        if (amountB < params.minAmountB) {
            revert ErrorLibrary.ExcessiveSlippage(params.minAmountB, amountB);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns identifier for this DEX implementation
     * @dev Used for logging and identification purposes
     * @return Name of the DEX implementation
     */
    function getDEXName() external pure returns (string memory) {
        return "UniswapV2";
    }

    /**
     * @notice Gets the router contract address
     * @dev Returns the immutable router address set during construction
     * @return Address of UniswapV2Router02 contract
     */
    function getRouterAddress() external view returns (address) {
        return router;
    }

    /**
     * @notice Gets the factory contract address
     * @dev Returns the immutable factory address set during construction
     * @return Address of UniswapV2Factory contract
     */
    function getFactoryAddress() external view returns (address) {
        return factory;
    }

    /**
     * @notice Gets pair address for token combination
     * @dev Queries factory for existing pair with validation
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return Address of the Uniswap V2 pair contract
     */
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address) {
        ErrorLibrary.validateAddress(tokenA, "tokenA");
        ErrorLibrary.validateAddress(tokenB, "tokenB");
        
        address pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        
        if (pair == address(0)) {
            revert ErrorLibrary.InvalidOperation("getPair: Pair does not exist");
        }
        
        return pair;
    }
}