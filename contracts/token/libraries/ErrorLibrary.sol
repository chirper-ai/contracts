// file: contracts/token/libraries/ErrorLibrary.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ErrorLibrary
 * @author ChirperAI
 * @notice Central library for all custom errors in the protocol
 * @dev Contains all error definitions used across the bonding token system
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
    error TokenNonexistent(address token);
    error TokenAlreadyExists(address token);
    error TokenTransferFailed(address token, address from, address to);
    error TokenNotGraduated(address token);
    error TokenAlreadyGraduated(address token);
    error InvalidTokenOperation(address token, string operation);

    /**
     * @notice Financial operation errors
     */
    error InsufficientLiquidity(uint256 required, uint256 provided);
    error InsufficientPayment(uint256 required, uint256 provided);
    error PaymentFailed(address to, uint256 amount);
    error TaxCalculationError(string details);
    error InvalidPrice(uint256 price, string reason);
    error RefundFailed(address to, uint256 amount);
    error InvalidTaxRate(uint256 rate, uint256 maximum);
    error InvalidTaxConfig(string reason);

    /**
     * @notice DEX integration errors
     */
    error DexAddLiquidityFailed(address dex, string reason);
    error DexPairCreationFailed(address factory, address tokenA, address tokenB);
    error InvalidDexAdapter(address adapter);
    error DexOperationFailed(string operation, string reason);
    error ExcessiveSlippage(uint256 expected, uint256 received);
    error InvalidDexWeights(uint256[] weights);

    /**
     * @notice Parameter validation errors
     */
    error InvalidAddress(address addr, string param);
    error InvalidAmount(uint256 amount, string param);
    error ArrayLengthMismatch(uint256 expected, uint256 received);
    error InvalidParameter(string param, string reason);
    error DeadlinePassed(uint256 deadline, uint256 timestamp);

    /**
     * @notice State errors
     */
    error ContractPaused();
    error ContractNotPaused();
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
                        BONDING CURVE ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Bonding curve specific errors
     */
    error InvalidReserveRatio(uint256 ratio);
    error InvalidCurveParameters(string reason);
    error GraduationThresholdNotMet(uint256 current, uint256 required);
    error InvalidGraduation(address token, string reason);
    error PriceCalculationError(string reason);
    error ReserveUpdateFailed(string reason);

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
     * @notice Validates tax rate is within bounds
     * @param rate Tax rate to validate
     * @param maximum Maximum allowed tax rate
     */
    function validateTaxRate(uint256 rate, uint256 maximum) internal pure {
        if (rate > maximum) {
            revert InvalidTaxRate(rate, maximum);
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
     * @notice Validates DEX weights sum to 100%
     * @param weights Array of weights to validate
     */
    function validateDexWeights(uint256[] memory weights) internal pure {
        uint256 total;
        for (uint256 i = 0; i < weights.length; i++) {
            total += weights[i];
        }
        if (total != 100) {
            revert InvalidDexWeights(weights);
        }
    }
}