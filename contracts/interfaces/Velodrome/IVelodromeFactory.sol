// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// IVelodromeFactory is the interface for VelodromeFactory contract
interface IVelodromeFactory {
    function createPair(address tokenA, address tokenB, bool stable) external returns (address pair);
    function getPair(address tokenA, address tokenB, bool stable) external view returns (address);
}