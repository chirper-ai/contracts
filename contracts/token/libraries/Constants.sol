// file: contracts/token/libraries/Constants.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Constants
 * @author YourName
 * @notice Central library for protocol constants and configuration values
 * @dev Contains all immutable values used throughout the bonding curve system
 */
library Constants {
    /*//////////////////////////////////////////////////////////////
                          ACCESS CONTROL ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for contract upgrader role
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Role identifier for tax manager role
    bytes32 public constant TAX_MANAGER_ROLE = keccak256("TAX_MANAGER_ROLE");

    /// @notice Role identifier for pauser role
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role identifier for platform role
    bytes32 public constant PLATFORM_ROLE = keccak256("PLATFORM_ROLE");

    /*//////////////////////////////////////////////////////////////
                              FEE CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points denominator (100%)
    uint96 public constant BASIS_POINTS = 10000;

    /// @notice Platform's share of trading fees (50%)
    uint96 public constant PLATFORM_FEE_SHARE = 50;

    /// @notice Creator's share of trading fees (50%) 
    uint96 public constant CREATOR_FEE_SHARE = 50;

    /// @notice Maximum tax rate (10%)
    uint96 public constant MAX_TAX_RATE = 1000;

    /*//////////////////////////////////////////////////////////////
                          BONDING CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constant product K value for AMM
    uint256 public constant BONDING_K = 3_000_000_000_000;

    /// @notice Initial token supply for new launches
    uint256 public constant INITIAL_TOKEN_SUPPLY = 1_000_000 * 10**18; // 1M tokens

    /// @notice Maximum slippage allowed in graduation (5%)
    uint96 public constant MAX_GRADUATION_SLIPPAGE = 500;

    /// @notice Graduation liquidity timeout
    uint256 public constant GRADUATION_TIMEOUT = 300; // 5 minutes

    /*//////////////////////////////////////////////////////////////
                         PROTOCOL SETTINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum delay between tax rate updates
    uint256 public constant MIN_TAX_UPDATE_DELAY = 1 days;

    /// @notice Maximum batch size for operations
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice Minimum threshold for meaningful operations
    uint256 public constant MIN_OPERATION_AMOUNT = 1000; // 0.001 tokens
    
    /*//////////////////////////////////////////////////////////////
                         VALIDATION CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum weight percentage (100%)
    uint256 public constant MAX_WEIGHT = 100;

    /// @notice Minimum graduation threshold
    uint256 public constant MIN_GRAD_THRESHOLD = 10000 * 10**18; // 10k base asset

    /*//////////////////////////////////////////////////////////////
                             ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Error message for zero address validation
    string public constant ERR_ZERO_ADDRESS = "Zero address not allowed";

    /// @notice Error message for zero amount validation
    string public constant ERR_ZERO_AMOUNT = "Amount must be greater than 0";

    /// @notice Error message for invalid weight configuration
    string public constant ERR_INVALID_WEIGHTS = "Weights must sum to 100";

    /// @notice Error message for graduation threshold
    string public constant ERR_INVALID_THRESHOLD = "Invalid graduation threshold";

    /// @notice Error message for tax rate limits
    string public constant ERR_TAX_TOO_HIGH = "Tax exceeds maximum rate";

    /// @notice Error message for array length mismatch
    string public constant ERR_ARRAY_LENGTH = "Array lengths must match";
}