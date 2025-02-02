// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// IVelodromeFactory is the interface for VelodromeFactory contract
interface IVelodromeFactory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}