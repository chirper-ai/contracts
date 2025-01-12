// file: contracts/token/interfaces/IUniswapV2Router02.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ErrorLibrary.sol";

interface IUniswapV2Router02 {
    /**
     * @notice Gets factory address
     * @dev Reverts with InvalidAddress if factory is zero address
     */
    function factory() external pure returns (address);
    
    /**
     * @notice Adds liquidity to a pair
     * @dev Reverts with InsufficientLiquidity if amounts too low
     * @dev Reverts with ExcessiveSlippage if slippage exceeds min amounts
     * @dev Reverts with DeadlinePassed if deadline has passed
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}