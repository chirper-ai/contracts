// file: contracts/token/interfaces/IVelodromeFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ErrorLibrary.sol";

interface IVelodromeFactory {
    /**
     * @notice Gets pair address for tokens
     * @dev Reverts with InvalidAddress if either token is zero address
     */
    function getPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address pair);
    
    /**
     * @notice Creates a new pair for tokens
     * @dev Reverts with DexPairCreationFailed if creation fails
     * @dev Reverts with TokenAlreadyExists if pair exists
     */
    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair);
}