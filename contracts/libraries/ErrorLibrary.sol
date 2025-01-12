// file: contracts/libraries/ErrorLibrary.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ErrorLibrary
 * @author ChirperAI
 * @notice Central library for all custom errors in the protocol
 * @dev Contains all error definitions used across the AgentSkill system
 */
library ErrorLibrary {
    /*//////////////////////////////////////////////////////////////
                            PROTOCOL ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Access control related errors
     */
    error Unauthorized(address caller, bytes32 role, string action);
    error RoleAlreadyGranted(address account, bytes32 role);
    error RoleRevokeFailed(address account, bytes32 role);
    error MissingRole(address account, bytes32 role);
    error InvalidRoleAdmin(address caller, bytes32 role);

    /**
     * @notice Token management errors
     */
    error TokenNonexistent(uint256 tokenId);
    error TokenAlreadyExists(uint256 tokenId);
    error TokenTransferFailed(uint256 tokenId, address from, address to);
    error TokenBurningDisabled(uint256 tokenId);
    error TokenNotTransferable(uint256 tokenId);
    error InvalidTokenURI(uint256 tokenId, string uri);

    /**
     * @notice Financial operation errors
     */
    error InsufficientPayment(uint256 required, uint256 provided);
    error PaymentFailed(address to, uint256 amount);
    error FeeCalculationError(string details);
    error InvalidPrice(uint256 price, string reason);
    error RefundFailed(address to, uint256 amount);
    error RoyaltyPaymentFailed(address recipient, uint256 amount);

    /**
     * @notice Account management errors
     */
    error AccountCreationFailed(address implementation, bytes reason);
    error AccountNotInitialized(uint256 tokenId, address account);
    error AccountExecutionFailed(address account, bytes reason);
    error InvalidAccountImplementation(address implementation);
    error AccountAlreadyExists(address account);
    error AccountNotFound(address account);

    /**
     * @notice Signature validation errors
     */
    error SignatureExpired(uint256 deadline, uint256 currentTime);
    error SignatureInvalid(address signer, bytes32 hash);
    error SignatureReplay(uint256 nonce);
    error InvalidSigner(address signer, string reason);
    error DeadlinePassed(uint256 deadline, uint256 timestamp);

    /**
     * @notice Parameter validation errors
     */
    error InvalidAddress(address addr, string param);
    error InvalidAmount(uint256 amount, string param);
    error InvalidDuration(uint256 duration, string reason);
    error ArrayLengthMismatch(uint256 expected, uint256 received);
    error InvalidParameter(string param, string reason);

    /**
     * @notice State errors
     */
    error ContractPaused();
    error ContractNotPaused();
    error EmergencyMode();
    error NotEmergencyMode();
    error AlreadyInitialized();
    error NotInitialized();

    /**
     * @notice Operation errors
     */
    error OperationFailed(string operation, string reason);
    error InvalidOperation(string operation);
    error OperationNotAllowed(string operation, string reason);
    error ReentrantCall(string operation);

    /*//////////////////////////////////////////////////////////////
                            INFERENCE ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inference specific errors
     */
    error InferenceRequestFailed(uint256 tokenId, string reason);
    error InvalidInferenceRequest(uint256 requestId);
    error InferenceTimeout(uint256 requestId, uint256 deadline);
    error InvalidInferenceResult(uint256 requestId, string reason);
    error InferencePriceMismatch(uint256 expected, uint256 provided);

    /*//////////////////////////////////////////////////////////////
                            PLATFORM ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Platform management errors
     */
    error InvalidPlatformSignature(bytes32 hash, bytes signature);
    error PlatformFeeMismatch(uint256 expected, uint256 provided);
    error InvalidPlatformConfig(string reason);
    error PlatformOperationFailed(string operation, string reason);

    /*//////////////////////////////////////////////////////////////
                            UPGRADE ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Upgrade related errors
     */
    error UpgradeValidationFailed(address implementation, string reason);
    error StorageLayoutMismatch(string details);
    error InvalidUpgradeParameters(string reason);
    error UpgradeFailed(string reason);

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates an address is not zero
     * @param addr Address to validate
     * @param param Name of parameter for error reporting
     */
    function validateAddress(address addr, string memory param) internal pure {
        if (addr == address(0)) {
            revert InvalidAddress(addr, param);
        }
    }

    /**
     * @notice Validates an amount is greater than zero
     * @param amount Amount to validate
     * @param param Name of parameter for error reporting
     */
    function validateAmount(uint256 amount, string memory param) internal pure {
        if (amount == 0) {
            revert InvalidAmount(amount, param);
        }
    }

    /**
     * @notice Validates array lengths match
     * @param len1 Length of first array
     * @param len2 Length of second array
     */
    function validateArrayLengths(uint256 len1, uint256 len2) internal pure {
        if (len1 != len2) {
            revert ArrayLengthMismatch(len1, len2);
        }
    }

    /**
     * @notice Validates a deadline hasn't passed
     * @param deadline Deadline to validate
     */
    function validateDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) {
            revert DeadlinePassed(deadline, block.timestamp);
        }
    }

    /**
     * @notice Validates a nonce hasn't been used
     * @param providedNonce Nonce to validate
     * @param currentNonce Current nonce value
     */
    function validateNonce(uint256 providedNonce, uint256 currentNonce) internal pure {
        if (providedNonce != currentNonce) {
            revert SignatureReplay(providedNonce);
        }
    }
}