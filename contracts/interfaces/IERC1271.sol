// file: contracts/interfaces/IERC1271.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC1271
 * @author Your Name
 * @notice Interface for contracts to validate signatures
 * @dev Implements EIP-1271 standard for contract signature validation
 */
interface IERC1271 {
    /**
     * @notice Struct containing signature validation data
     * @param hash Hash of the data to be signed
     * @param signature Signature bytes to validate
     * @param validUntil Optional timestamp until which signature is valid
     * @param validAfter Optional timestamp after which signature becomes valid
     * @param extraData Optional additional validation data
     */
    struct SignatureValidation {
        bytes32 hash;
        bytes signature;
        uint256 validUntil;
        uint256 validAfter;
        bytes extraData;
    }

    /**
     * @notice Magic value bytes4(keccak256("isValidSignature(bytes32,bytes)"))
     * @dev Must be returned by isValidSignature when validation passes
     */
    bytes4 constant internal MAGIC_VALUE = 0x1626ba7e;

    /**
     * @notice Magic value returned when a signature is invalid
     */
    bytes4 constant internal INVALID_SIGNATURE = 0xffffffff;

    /**
     * @notice Emitted when a signature validation is performed
     * @param hash The hash that was validated
     * @param signer The address that was recovered from the signature
     * @param valid Whether the signature was valid
     */
    event SignatureValidated(
        bytes32 indexed hash,
        address indexed signer,
        bool valid
    );

    /**
     * @notice Returns whether the provided signature is valid for the given data
     * @dev Must return MAGIC_VALUE if valid, any other value indicates invalid
     * @param hash Hash of the data to be signed
     * @param signature Signature byte array associated with hash
     * @return magicValue The magic value (0x1626ba7e) if valid, or other value if invalid
     */
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) external view returns (bytes4 magicValue);

    /**
     * @notice Extended signature validation with additional parameters
     * @dev Optional method for more complex validation scenarios
     * @param validation The complete signature validation struct
     * @return magicValue The magic value if valid, or other value if invalid
     * @return reason If invalid, the reason why
     */
    function isValidSignatureWithParams(
        SignatureValidation calldata validation
    ) external view returns (bytes4 magicValue, string memory reason);

    /**
     * @notice Validates a signature with a specific signer
     * @dev Can be used to check if a specific address signed the message
     * @param hash Hash of the data
     * @param signature The signature to validate
     * @param expectedSigner The address that should have signed the message
     * @return isValid Whether the signature is valid for the expected signer
     */
    function isValidSignatureForSigner(
        bytes32 hash,
        bytes memory signature,
        address expectedSigner
    ) external view returns (bool isValid);

    /**
     * @notice Gets the current nonce for a signer
     * @dev Can be used for replay protection
     * @param signer The address to get the nonce for
     * @return nonce The current nonce
     */
    function getNonce(address signer) external view returns (uint256 nonce);

    /**
     * @notice Checks if a signature has expired
     * @param validUntil The timestamp until which the signature is valid
     * @param validAfter The timestamp after which the signature becomes valid
     * @return isValid Whether the signature is currently valid
     */
    function isValidSignatureTiming(
        uint256 validUntil,
        uint256 validAfter
    ) external view returns (bool isValid);
}

/**
 * @title IERC1271Errors
 * @notice Error definitions for ERC1271 implementations
 */
interface IERC1271Errors {
    /**
     * @notice Thrown when a signature has expired
     * @param validUntil The timestamp when the signature expired
     * @param currentTime The current timestamp
     */
    error SignatureExpired(uint256 validUntil, uint256 currentTime);

    /**
     * @notice Thrown when a signature is not yet valid
     * @param validAfter When the signature becomes valid
     * @param currentTime The current timestamp
     */
    error SignatureNotYetValid(uint256 validAfter, uint256 currentTime);

    /**
     * @notice Thrown when signature verification fails
     * @param signer The recovered signer
     * @param expectedSigner The expected signer
     */
    error SignatureVerificationFailed(address signer, address expectedSigner);

    /**
     * @notice Thrown when an invalid signature length is provided
     * @param length The length provided
     * @param expected The expected length
     */
    error InvalidSignatureLength(uint256 length, uint256 expected);

    /**
     * @notice Thrown when a signature is replayed
     * @param nonce The nonce used
     * @param currentNonce The current nonce value
     */
    error SignatureReplay(uint256 nonce, uint256 currentNonce);
}

/**
 * @title IERC1271Events
 * @notice Event definitions for ERC1271 implementations
 */
interface IERC1271Events {
    /**
     * @notice Emitted when a nonce is used
     * @param signer The address the nonce was used for
     * @param nonce The nonce value used
     * @param timestamp When the nonce was used
     */
    event NonceUsed(
        address indexed signer,
        uint256 nonce,
        uint256 timestamp
    );

    /**
     * @notice Emitted when signature validation fails
     * @param hash The hash that failed validation
     * @param signer The recovered signer
     * @param reason The reason for failure 
     */
    event SignatureValidationFailed(
        bytes32 indexed hash,
        address indexed signer,
        string reason
    );
}