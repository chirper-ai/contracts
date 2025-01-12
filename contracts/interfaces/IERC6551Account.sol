// file: contracts/interfaces/IERC6551Account.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IERC6551Account
 * @author ChirperAI
 * @notice Interface for ERC6551 token bound accounts
 * @dev Specification for accounts bound to non-fungible tokens (NFTs)
 */
interface IERC6551Account {
    /**
     * @notice Information about the owner token of this account
     * @param chainId The chain ID where the token exists
     * @param tokenContract The token contract address
     * @param tokenId The token ID
     */
    struct TokenInfo {
        uint256 chainId;
        address tokenContract;
        uint256 tokenId;
    }

    /**
     * @notice Execution parameters for calls made through the account
     * @param to The target address for the call
     * @param value The amount of native token to send
     * @param data The calldata for the execution
     * @param operation Whether to perform a call or delegatecall (0 = call, 1 = delegatecall)
     * @param nonce The expected current nonce of the account
     * @param deadline The timestamp until which the execution is valid
     */
    struct ExecutionParams {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
        uint256 nonce;
        uint256 deadline;
    }

    /**
     * @notice Emitted when the account execution parameters are changed
     * @param nonce The new nonce value
     * @param timestamp When the change occurred
     */
    event AccountNonceUpdated(uint256 nonce, uint256 timestamp);

    /**
     * @notice Emitted when a call is executed through this account
     * @param caller The address that initiated the call
     * @param target The target of the call
     * @param value The value sent with the call
     * @param data The data sent with the call
     * @param operation The operation type (call vs delegatecall)
     * @param nonce The nonce used
     */
    event CallExecuted(
        address indexed caller,
        address indexed target,
        uint256 value,
        bytes data,
        uint8 operation,
        uint256 nonce
    );

    /**
     * @notice Gets the token that owns this account
     * @return info The complete token information struct
     */
    function token() external view returns (TokenInfo memory info);

    /**
     * @notice Returns the current state of the account
     * @dev Used for replay protection across implementations
     * @return nonce The current nonce
     * @return timestamp The last operation timestamp
     * @return operation The last operation type performed
     */
    function state() external view returns (
        uint256 nonce,
        uint256 timestamp,
        uint8 operation
    );

    /**
     * @notice Executes a call from this account
     * @dev Must validate caller authorization and handle replay protection
     * @param params The complete execution parameters
     * @return success Whether the call was successful
     * @return result The result data from the call
     */
    function executeCall(
        ExecutionParams calldata params
    ) external payable returns (bool success, bytes memory result);

    /**
     * @notice Checks if an address is authorized to make calls
     * @dev Should be implemented alongside IERC1271 for signature validation
     * @param caller The address to check
     * @param params Optional authorization parameters
     * @return authorized Whether the address is authorized
     * @return reason If not authorized, the reason why
     */
    function isAuthorized(
        address caller,
        bytes calldata params
    ) external view returns (bool authorized, string memory reason);

    /**
     * @notice Returns supported interfaces
     * @dev Must support IERC165 interface detection
     * @param interfaceId The interface identifier to check
     * @return supported Whether the interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) external view returns (bool supported);

    /**
     * @notice Gets the owner token's NFT owner
     * @return owner The current owner of the NFT
     */
    function owner() external view returns (address owner);

    /**
     * @notice Checks if the account can receive native token
     * @dev Must return true to receive native token
     * @return canReceive Whether the account can receive native token
     */
    function isPayable() external pure returns (bool canReceive);

    /**
     * @notice Checks if the account is locked for sensitive operations
     * @return locked Whether the account is locked
     * @return unlockTime When the account will be unlocked
     */
    function isLocked() external view returns (bool locked, uint256 unlockTime);
}

/**
 * @title IERC6551Executable
 * @notice Optional extension for accounts that support batched execution
 */
interface IERC6551Executable {
    /**
     * @notice Contains parameters for a single call in a batch
     * @param to The target address
     * @param value The native token value
     * @param data The call data
     * @param operation The operation type (0 = call, 1 = delegatecall)
     */
    struct Call {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
    }

    /**
     * @notice Executes a batch of calls from this account
     * @param calls Array of calls to execute
     * @param nonce The expected current nonce
     * @param deadline Timestamp until which execution is valid
     * @return results Array of results from the calls
     */
    function executeBatch(
        Call[] calldata calls,
        uint256 nonce,
        uint256 deadline
    ) external payable returns (bytes[] memory results);
}

/**
 * @title IERC6551AccountCreator
 * @notice Optional interface for standardized account creation
 */
interface IERC6551AccountCreator {
    /**
     * @notice Configuration for creating a new account
     * @param implementation Account implementation address
     * @param chainId Chain ID of the token
     * @param tokenContract Token contract address
     * @param tokenId Token ID  
     * @param salt Salt for address generation 
     * @param initData Initialization data
     */
    struct AccountCreationConfig {
        address implementation;
        uint256 chainId;
        address tokenContract;
        uint256 tokenId;
        uint256 salt;
        bytes initData;
    }

    /**
     * @notice Creates an account with the given configuration
     * @param config The account creation configuration
     * @return account The address of the created account
     */
    function createAccount(
        AccountCreationConfig calldata config
    ) external returns (address account);
}