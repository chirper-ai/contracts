// file: contracts/libraries/Constants.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
* @title Constants
* @author ChirperAI
* @notice Central library for protocol constants and configuration values
* @dev Contains all immutable values used throughout the AgentSkill system
*/
library Constants {
   /*//////////////////////////////////////////////////////////////
                         ACCESS CONTROL ROLES
   //////////////////////////////////////////////////////////////*/

   /// @notice Role identifier for contract upgrader role
   bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

   /// @notice Role identifier for fee manager role 
   bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

   /// @notice Role identifier for pauser role
   bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

   /// @notice Role identifier for platform role
   bytes32 public constant PLATFORM_ROLE = keccak256("PLATFORM_ROLE");

   /*//////////////////////////////////////////////////////////////
                             FEE CONFIG
   //////////////////////////////////////////////////////////////*/

   /// @notice Basis points denominator (100%)
   uint96 public constant BASIS_POINTS = 10000;

   /// @notice Execution fee in basis points (1%)
   uint96 public constant EXECUTION_FEE_BPS = 100;

   /// @notice Trade royalty in basis points (2% total - 1% each to creator/platform)
   uint96 public constant TRADE_ROYALTY_BPS = 200;

   /// @notice Platform's share of inference fees (70%)
   uint96 public constant PLATFORM_INFERENCE_SHARE = 70;

   /// @notice Creator's share of inference fees (30%)
   uint96 public constant CREATOR_INFERENCE_SHARE = 30;

   /*//////////////////////////////////////////////////////////////
                         PROTOCOL SETTINGS
   //////////////////////////////////////////////////////////////*/

   /// @notice Maximum duration for an inference request
   uint256 public constant MAX_INFERENCE_DURATION = 1 days;

   /// @notice Timeout period for emergency withdrawals
   uint256 public constant EMERGENCY_TIMEOUT = 3 days;

   /// @notice Maximum number of tokens in a batch operation
   uint256 public constant MAX_BATCH_SIZE = 50;

   /// @notice Minimum delay between certain operations
   uint256 public constant MIN_OPERATION_DELAY = 1 hours;

   /// @notice Gas stipend for receive/fallback functions
   uint256 public constant RECEIVE_GAS_STIPEND = 30000;

   /*//////////////////////////////////////////////////////////////
                       SIGNATURE CONSTANTS
   //////////////////////////////////////////////////////////////*/
   
   /// @notice EIP712 domain name
   bytes32 public constant DOMAIN_NAME = keccak256("AgentSkill");

   /// @notice EIP712 domain version
   bytes32 public constant DOMAIN_VERSION = keccak256("1");

   /// @notice Prefix for emergency withdrawal signatures
   bytes32 public constant EMERGENCY_WITHDRAW_TYPEHASH = keccak256(
       "EmergencyWithdraw(uint256 tokenId,address recipient,address[] tokens,uint256 nonce,uint256 deadline)"
   );

   /// @notice Prefix for burn signatures
   bytes32 public constant BURN_TYPEHASH = keccak256(
       "Burn(uint256 tokenId,address recipient,uint256 nonce,uint256 deadline)"
   );

   /*//////////////////////////////////////////////////////////////
                        VALIDATION CONSTANTS
   //////////////////////////////////////////////////////////////*/

   /// @notice Minimum inference price
   uint256 public constant MIN_INFERENCE_PRICE = 0.001 ether;

   /// @notice Maximum inference price
   uint256 public constant MAX_INFERENCE_PRICE = 100 ether;

   /// @notice Maximum mint price
   uint256 public constant MAX_MINT_PRICE = 1000 ether;

   /// @notice Address representing native ETH in operations
   address public constant ETH_ADDRESS = address(0);

   /*//////////////////////////////////////////////////////////////
                            ERRORS
   //////////////////////////////////////////////////////////////*/

   /// @notice Error message for zero address validation
   string public constant ERR_ZERO_ADDRESS = "Zero address not allowed";

   /// @notice Error message for zero amount validation
   string public constant ERR_ZERO_AMOUNT = "Amount must be greater than 0";

   /// @notice Error message for invalid price
   string public constant ERR_INVALID_PRICE = "Price out of valid range";

   /// @notice Error message for array length mismatch
   string public constant ERR_ARRAY_LENGTH = "Array lengths must match";
}