// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// IVelodromeRouter is the interface for VelodromeRouter contract
interface IVelodromeRouter {
    function factory() external view returns (address);
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}