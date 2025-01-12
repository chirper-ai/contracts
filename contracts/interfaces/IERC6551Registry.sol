// file: contracts/interfaces/IERC6551Registry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC6551Registry
 * @author Your Name
 * @notice Interface for the ERC6551 account registry
 * @dev Defines the registry functionality for creating and tracking token bound accounts
 */
interface IERC6551Registry {
    /**
     * @notice Configuration struct for account creation/lookup
     * @param implementation The implementation contract for the account
     * @param chainId The chain ID where the token exists
     * @param tokenContract The address of the token contract
     * @param tokenId The ID of the token
     * @param salt Additional value for address generation
     */
    struct AccountCreationParams {
        address implementation;
        uint256 chainId;
        address tokenContract;
        uint256 tokenId;
        uint256 salt;
    }

    /**
     * @notice Account initialization parameters
     * @param initData Optional initialization data for the account
     * @param nonce Expected nonce for the creation
     * @param deadline Timestamp until which creation is valid
     */
    struct InitializationParams {
        bytes initData;
        uint256 nonce;
        uint256 deadline;
    }

    /**
     * @notice Emitted when a new account is created
     * @param account The address of the created account
     * @param implementation The address of the implementation contract
     * @param chainId The chain ID where the token exists
     * @param tokenContract The address of the token contract
     * @param tokenId The ID of the token
     * @param salt The salt used in address generation
     * @param initData The initialization data used (if any)
     */
    event AccountCreated(
        address indexed account,
        address indexed implementation,
        uint256 chainId,
        address indexed tokenContract,
        uint256 tokenId,
        uint256 salt,
        bytes initData
    );

    /**
     * @notice Emitted when account creation fails
     * @param implementation The implementation that failed
     * @param reason The reason for the failure
     */
    event AccountCreationFailed(
        address indexed implementation,
        string reason
    );

    /**
     * @notice Creates a new token bound account
     * @dev The returned address is counterfactually generated
     * @param creationParams The account creation parameters
     * @param initParams The initialization parameters
     * @return account The address of the created account
     */
    function createAccount(
        AccountCreationParams calldata creationParams,
        InitializationParams calldata initParams
    ) external returns (address account);

    /**
     * @notice Computes the address of a token bound account
     * @dev Returns the same address that would be created by createAccount
     * @param params The account creation parameters
     * @return account The computed account address
     */
    function account(
        AccountCreationParams calldata params
    ) external view returns (address account);

    /**
     * @notice Checks if an account has been created
     * @param params The account parameters to check
     * @return exists Whether the account exists
     * @return account The account address (if it exists)
     */
    function accountExists(
        AccountCreationParams calldata params
    ) external view returns (bool exists, address account);

    /**
     * @notice Gets the implementation used for an account
     * @param account The account address to check
     * @return implementation The implementation contract address
     */
    function getImplementation(
        address account
    ) external view returns (address implementation);

    /**
     * @notice Gets the token associated with an account
     * @param account The account address to check
     * @return chainId The chain ID of the token
     * @return tokenContract The token contract address
     * @return tokenId The token ID
     */
    function getTokenForAccount(
        address account
    ) external view returns (
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    );

    /**
     * @notice Validates account creation parameters
     * @param params The parameters to validate
     * @return valid Whether the parameters are valid
     * @return reason If invalid, the reason why
     */
    function validateCreationParams(
        AccountCreationParams calldata params
    ) external pure returns (bool valid, string memory reason);

    /**
     * @notice Checks if an address is a valid implementation
     * @param implementation The address to check
     * @return valid Whether the implementation is valid
     * @return reason If invalid, the reason why
     */
    function isValidImplementation(
        address implementation
    ) external view returns (bool valid, string memory reason);
}