// file: contracts/libraries/SafeCall.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ErrorLibrary.sol";

/**
 * @title SafeCall
 * @author Your Name
 * @notice Library for safe external contract interactions
 * @dev Provides utilities to safely make external calls and handle their results
 */
library SafeCall {
    /**
     * @notice Safely executes an external call with value
     * @dev Includes checks for contract existence and successful execution
     * @param target Address to call
     * @param value Amount of ETH to send
     * @param data Call data
     * @return success Whether the call succeeded
     * @return result Data returned from the call
     */
    function safeCall(
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (bool success, bytes memory result) {
        // Check target is a contract
        if (target.code.length == 0) {
            revert ErrorLibrary.InvalidAddress(target, "Target must be a contract");
        }

        // Execute call
        (success, result) = target.call{value: value}(data);

        // Check call success
        if (!success) {
            // Try to extract error message if one was returned
            string memory reason = result.length > 0 ? 
                abi.decode(result, (string)) : 
                "Call failed with no reason";
                
            revert ErrorLibrary.OperationFailed("external call", reason);
        }

        return (success, result);
    }

    /**
     * @notice Safely executes a delegatecall
     * @dev Includes checks for contract existence and successful execution
     * @param target Address to delegatecall
     * @param data Call data
     * @return success Whether the call succeeded
     * @return result Data returned from the call
     */
    function safeDelegateCall(
        address target,
        bytes memory data
    ) internal returns (bool success, bytes memory result) {
        // Check target is a contract
        if (target.code.length == 0) {
            revert ErrorLibrary.InvalidAddress(target, "Target must be a contract");
        }

        // Execute delegatecall
        (success, result) = target.delegatecall(data);

        // Check call success
        if (!success) {
            string memory reason = result.length > 0 ? 
                abi.decode(result, (string)) : 
                "Delegatecall failed with no reason";
                
            revert ErrorLibrary.OperationFailed("delegate call", reason);
        }

        return (success, result);
    }

    /**
     * @notice Safely transfers ETH to an address
     * @dev Includes gas stipend for receiving contract
     * @param to Address to send ETH to
     * @param amount Amount of ETH to send
     */
    function safeTransferETH(address to, uint256 amount) internal {
        // Validate parameters
        ErrorLibrary.validateAddress(to, "recipient");
        ErrorLibrary.validateAmount(amount, "amount");

        // Transfer with gas stipend for receiving contract
        (bool success, ) = to.call{value: amount, gas: 30000}("");
        
        if (!success) {
            revert ErrorLibrary.PaymentFailed(to, amount);
        }
    }

    /**
     * @notice Checks if an address is a contract
     * @param addr Address to check
     * @return isContract Whether the address is a contract
     */
    function isContract(address addr) internal view returns (bool isContract) {
        return addr.code.length > 0;
    }
}