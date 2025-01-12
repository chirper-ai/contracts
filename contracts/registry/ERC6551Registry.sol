// file: contracts/registry/ERC6551Registry.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Create2.sol";
import "../interfaces/IERC6551Registry.sol";
import "../libraries/ErrorLibrary.sol";
import "../libraries/Constants.sol";

/**
 * @title ERC6551Registry
 * @author Your Name
 * @notice Registry for creating and tracking token bound accounts
 * @dev Implementation of ERC6551 registry specification with enhanced security
 */
contract ERC6551Registry is IERC6551Registry {
    /**
     * @notice Creates a token bound account
     * @dev Uses Create2 for deterministic address generation
     * @param params Account creation parameters
     * @param initParams Initialization parameters
     * @return account The address of the created account
     */
    function createAccount(
        AccountCreationParams calldata params,
        InitializationParams calldata initParams
    ) external returns (address account) {
        // Validate parameters
        (bool valid, string memory reason) = validateCreationParams(params);
        if (!valid) {
            revert ErrorLibrary.InvalidParameter("creation params", reason);
        }

        // Verify deadline if provided
        if (initParams.deadline != 0) {
            ErrorLibrary.validateDeadline(initParams.deadline);
        }

        // Generate creation code
        bytes memory creationCode = _creationCode(
            params.implementation,
            params.chainId,
            params.tokenContract,
            params.tokenId,
            params.salt
        );

        // Compute account address
        account = Create2.computeAddress(
            bytes32(params.salt),
            keccak256(creationCode),
            address(this)
        );

        // Deploy if not already deployed
        if (account.code.length == 0) {
            account = Create2.deploy(0, bytes32(params.salt), creationCode);

            // Initialize if needed
            if (initParams.initData.length > 0) {
                (bool success, bytes memory result) = account.call(initParams.initData);
                if (!success) {
                    revert ErrorLibrary.OperationFailed(
                        "account initialization",
                        result.length > 0 ? string(result) : "Initialization failed"
                    );
                }
            }

            emit AccountCreated(
                account,
                params.implementation,
                params.chainId,
                params.tokenContract,
                params.tokenId,
                params.salt,
                initParams.initData
            );
        }

        return account;
    }

    /**
     * @notice Computes the account address that would be created
     * @param params Account creation parameters
     * @return account The computed account address
     */
    function account(
        AccountCreationParams calldata params
    ) external view returns (address account) {
        // Validate parameters
        (bool valid, string memory reason) = validateCreationParams(params);
        if (!valid) {
            revert ErrorLibrary.InvalidParameter("creation params", reason);
        }

        // Generate creation code
        bytes memory creationCode = _creationCode(
            params.implementation,
            params.chainId,
            params.tokenContract,
            params.tokenId,
            params.salt
        );

        // Compute and return address
        return Create2.computeAddress(
            bytes32(params.salt),
            keccak256(creationCode),
            address(this)
        );
    }

    /**
     * @notice Checks if an account exists at the computed address
     * @param params Account parameters to check
     * @return exists Whether the account exists
     * @return account The account address
     */
    function accountExists(
        AccountCreationParams calldata params
    ) external view returns (bool exists, address account) {
        account = this.account(params);
        exists = account.code.length > 0;
        return (exists, account);
    }

    /**
     * @notice Gets the implementation used for an account
     * @param account The account address to check
     * @return implementation The implementation contract address
     */
    function getImplementation(
        address account
    ) external view returns (address implementation) {
        if (account.code.length == 0) {
            revert ErrorLibrary.AccountNotFound(account);
        }

        // Get first 20 bytes of code which contains the implementation address
        assembly {
            let codeSize := extcodesize(account)
            if iszero(codesize) {
                revert(0, 0)
            }
            extcodecopy(account, 0x20, 0x0E, 20) // Skip first 14 bytes of proxy code
            implementation := mload(0x20)
        }
    }

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
    ) {
        if (account.code.length == 0) {
            revert ErrorLibrary.AccountNotFound(account);
        }

        // Get token data from account code
        assembly {
            let codeSize := extcodesize(account)
            if iszero(codeSize) {
                revert(0, 0)
            }
            
            // Load data after implementation address (20 bytes)
            extcodecopy(account, 0x20, 0x22, 84) // 32 bytes chainId + 20 bytes token + 32 bytes tokenId
            chainId := mload(0x20)
            tokenContract := mload(0x40)
            tokenId := mload(0x60)
        }
    }

    /**
     * @notice Validates account creation parameters
     * @param params The parameters to validate
     * @return valid Whether the parameters are valid
     * @return reason If invalid, the reason why
     */
    function validateCreationParams(
        AccountCreationParams calldata params
    ) public pure returns (bool valid, string memory reason) {
        if (params.implementation == address(0)) {
            return (false, "Invalid implementation address");
        }
        if (params.tokenContract == address(0)) {
            return (false, "Invalid token contract address");
        }
        if (params.chainId == 0) {
            return (false, "Invalid chain ID");
        }
        return (true, "");
    }

    /**
     * @notice Creates initialization code for account deployment
     * @dev Generates EIP-1167 minimal proxy code
     * @return code The creation code bytes
     */
    function _creationCode(
        address implementation_,
        uint256 chainId_,
        address tokenContract_,
        uint256 tokenId_,
        uint256 salt_
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            // Proxy code
            hex"3d60ad80600a3d3981f3363d3d373d3d3d363d73",
            implementation_,
            hex"5af43d82803e903d91602b57fd5bf3",
            // Initialization data
            abi.encode(
                chainId_,
                tokenContract_,
                tokenId_,
                salt_
            )
        );
    }
}