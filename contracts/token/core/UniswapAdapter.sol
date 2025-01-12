// file: contracts/core/UniswapAdapter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IDEXAdapter.sol";
import "../interfaces/IUniswapV2Router02.sol";
import "../interfaces/IUniswapV2Factory.sol";

/**
 * @title UniswapAdapter
 * @author YourName
 * @notice Adapter for Uniswap V2 integration
 * @dev Implements IDEXAdapter for Uniswap V2 and compatible forks
 */
contract UniswapAdapter is IDEXAdapter {
    using SafeERC20 for IERC20;

    /// @notice Uniswap V2 Router address
    address public immutable router;
    
    /// @notice Uniswap V2 Factory address
    address public immutable factory;

    /**
     * @notice Creates new Uniswap adapter
     * @param router_ Router contract address
     */
    constructor(address router_) {
        require(router_ != address(0), "Invalid router");
        router = router_;
        factory = IUniswapV2Router02(router_).factory();
    }

    /**
     * @notice Adds liquidity to Uniswap pair
     * @param params Liquidity parameters
     * @return amountA Amount of tokenA used
     * @return amountB Amount of tokenB used
     * @return liquidity LP tokens minted
     */
    function addLiquidity(
        LiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Approve router if needed
        IERC20(params.tokenA).forceApprove(router, params.amountA);
        IERC20(params.tokenB).forceApprove(router, params.amountB);

        // Add liquidity
        (amountA, amountB, liquidity) = IUniswapV2Router02(router).addLiquidity(
            params.tokenA,
            params.tokenB,
            params.amountA,
            params.amountB,
            params.minAmountA,
            params.minAmountB,
            params.to,
            params.deadline
        );

        // Clear approvals
        IERC20(params.tokenA).forceApprove(router, 0);
        IERC20(params.tokenB).forceApprove(router, 0);
    }

    /**
     * @notice Gets DEX name
     * @return DEX identifier
     */
    function getDEXName() external pure returns (string memory) {
        return "UniswapV2";
    }

    /**
     * @notice Gets router address
     * @return Router contract
     */
    function getRouterAddress() external view returns (address) {
        return router;
    }

    /**
     * @notice Gets factory address
     * @return Factory contract
     */
    function getFactoryAddress() external view returns (address) {
        return factory;
    }

    /**
     * @notice Gets pair address for tokens
     * @param tokenA First token
     * @param tokenB Second token
     * @return Pair contract
     */
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address) {
        return IUniswapV2Factory(factory).getPair(tokenA, tokenB);
    }
}