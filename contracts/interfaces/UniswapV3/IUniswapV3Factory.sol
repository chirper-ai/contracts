// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Uniswap V3 core interfaces
interface IUniswapV3Factory {
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool);
    
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);
}