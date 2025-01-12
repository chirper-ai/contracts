// file: contracts/interfaces/IVelodromeFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVelodromeFactory {
    function getPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address pair);
    
    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair);
}