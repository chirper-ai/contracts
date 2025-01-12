// file: contracts/interfaces/IAgentSkillErrors.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAgentSkillErrors
 * @author Your Name
 * @notice Defines all custom errors used throughout the AgentSkill protocol
 * @dev Centralizes error definitions to ensure consistency and avoid duplication
 */
interface IAgentSkillErrors {
    /**
     * @notice Thrown when contract initialization fails
     * @param implementation The implementation contract that failed
     * @param reason The reason for failure (if available)
     */
    error InitializationFailed(address implementation, string reason);

    /**
     * @notice Thrown for invalid registry operations
     * @param registry The address that was invalid
     * @param reason The specific reason for invalidity
     */
    error InvalidRegistry(address registry, string reason);

    /**
     * @notice Thrown when an operation is performed on a non-existent token
     * @param tokenId The ID of the token that doesn't exist
     */
    error TokenNonexistent(uint256 tokenId);

    /**
     * @notice Thrown when an account is not properly initialized
     * @param tokenId The token ID associated with the uninitialized account
     * @param account The account address that failed initialization
     */
    error AccountNotInitialized(uint256 tokenId, address account);

    /**
     * @notice Thrown when a payment amount is incorrect
     * @param expected The expected payment amount
     * @param received The actual payment received
     */
    error InvalidPayment(uint256 expected, uint256 received);

    /**
     * @notice Thrown when attempting to burn a token while burning is disabled
     * @param tokenId The ID of the token attempted to be burned
     */
    error BurningDisabled(uint256 tokenId);

    /**
     * @notice Thrown for invalid signatures
     * @param signer The address that was supposed to sign
     * @param hash The hash that was signed
     * @param signature The invalid signature
     */
    error InvalidSignature(address signer, bytes32 hash, bytes signature);

    /**
     * @notice Thrown when a signature has expired
     * @param deadline The timestamp when the signature expired
     * @param currentTime The current block timestamp
     */
    error SignatureExpired(uint256 deadline, uint256 currentTime);

    /**
     * @notice Thrown when an unauthorized operation is attempted
     * @param caller The address attempting the operation
     * @param tokenId The token ID involved
     * @param requiredRole The role that was required (if applicable)
     */
    error NotAuthorized(address caller, uint256 tokenId, bytes32 requiredRole);

    /**
     * @notice Thrown when fee distribution fails
     * @param recipient The address that should have received the fee
     * @param amount The amount that failed to transfer
     */
    error FeeTransferFailed(address recipient, uint256 amount);

    /**
     * @notice Thrown when an external call fails
     * @param target The address that was called
     * @param value The value sent with the call
     * @param data The call data
     * @param reason The reason for failure (if available)
     */
    error CallFailed(address target, uint256 value, bytes data, string reason);

    /**
     * @notice Thrown when an invalid address is provided
     * @param addr The invalid address
     * @param param The name of the parameter that was invalid
     */
    error InvalidAddress(address addr, string param);

    /**
     * @notice Thrown when an invalid amount is provided
     * @param amount The invalid amount
     * @param param The name of the parameter that was invalid
     * @param reason The reason it was invalid
     */
    error InvalidAmount(uint256 amount, string param, string reason);

    /**
     * @notice Thrown when a nonce is invalid or already used
     * @param nonce The invalid nonce
     * @param expected The expected nonce value
     */
    error InvalidNonce(uint256 nonce, uint256 expected);

    /**
     * @notice Thrown when an operation would result in a reentrancy
     * @param caller The address attempting the reentrant call
     * @param operation The name of the operation attempted
     */
    error ReentrantCall(address caller, string operation);

    /**
     * @notice Thrown when a deadline has passed
     * @param deadline The deadline that was missed
     * @param currentTime The current block timestamp
     */
    error DeadlinePassed(uint256 deadline, uint256 currentTime);

    /**
     * @notice Thrown when an array length mismatch occurs
     * @param array1Length Length of first array
     * @param array2Length Length of second array
     * @param context Description of the arrays being compared
     */
    error ArrayLengthMismatch(uint256 array1Length, uint256 array2Length, string context);
}