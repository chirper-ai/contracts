// file: contracts/skill/core/AgentSkillStorage.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../interfaces/IERC6551Registry.sol";
import "../libraries/Constants.sol";
import "../libraries/ErrorLibrary.sol";

/**
 * @title AgentSkillStorage
 * @author ChirperAI
 * @notice Storage layout for the AgentSkill system
 * @dev Uses storage gaps for upgrade safety following OpenZeppelin pattern
 */
abstract contract AgentSkillStorage {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Core protocol contracts
     * @dev Immutable references to critical protocol contracts
     */
    IERC6551Registry public accountRegistry;
    address public accountImplementation;
    address public platformSigner;

    /**
     * @notice Protocol state
     * @dev Global protocol configuration and state
     */
    bool public burnEnabled;
    bool public emergencyMode;
    uint256 public lastUpgradeTimestamp;
    
    /**
     * @notice Token tracking
     * @dev Counter and mappings for token management
     */
    uint256 internal _currentTokenId;
    mapping(uint256 => bool) public tokenExists;
    mapping(uint256 => uint256) public tokenCreationTime;

    /**
     * @notice Token configurations
     * @dev Mappings for token-specific settings
     */
    mapping(uint256 => address) public boundAccounts;     // TokenId => bound account
    mapping(uint256 => address) public permanentAgent;    // TokenId => permanent agent address
    mapping(uint256 => address) public tokenCreators;     // TokenId => creator address
    mapping(uint256 => uint256) public mintPrice;         // TokenId => mint price
    mapping(uint256 => uint256) public inferencePrice;    // TokenId => inference price
    mapping(uint256 => bool) public tokenLocked;          // TokenId => locked status

    /**
     * @notice Inference tracking
     * @dev Mappings for inference operations
     */
    mapping(uint256 => uint256) public inferenceCount;    // TokenId => total inferences
    mapping(uint256 => uint256) public lastInferenceTime; // TokenId => last inference
    mapping(uint256 => uint256) public pendingInferenceFees;  // TokenId => pending fees
    mapping(bytes32 => bool) public inferenceRequestExists;   // RequestId => exists
    mapping(bytes32 => uint256) public inferenceRequestExpiry; // RequestId => expiry

    /**
     * @notice Fee management
     * @dev Mappings for fee tracking and distribution
     */
    mapping(address => uint256) public tokenFees;         // Token => accumulated fees
    mapping(uint256 => uint256) public creatorFees;       // TokenId => creator fees
    mapping(address => uint256) public platformFees;      // Token => platform fees

    /**
     * @notice Security tracking
     * @dev Mappings for nonces and signatures
     */
    mapping(address => uint256) public nonces;            // Address => current nonce
    mapping(bytes32 => bool) public usedSignatures;       // SignatureHash => used

    /**
     * @dev Gap for upgrade safety
     * @dev Contains 50 storage slots for future upgrades
     */
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when storage is upgraded
     * @param version New storage version
     * @param timestamp When upgrade occurred
     */
    event StorageUpgraded(uint256 version, uint256 timestamp);

    /**
     * @notice Emitted when emergency mode is toggled
     * @param enabled New emergency mode state
     * @param reason Reason for the change
     */
    event EmergencyModeSet(bool enabled, string reason);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures token exists
     * @param tokenId Token ID to check
     */
    modifier tokenMustExist(uint256 tokenId) {
        if (!tokenExists[tokenId]) {
            revert ErrorLibrary.TokenNonexistent(tokenId);
        }
        _;
    }

    /**
     * @notice Ensures token does not exist
     * @param tokenId Token ID to check
     */
    modifier tokenMustNotExist(uint256 tokenId) {
        if (tokenExists[tokenId]) {
            revert ErrorLibrary.TokenAlreadyExists(tokenId);
        }
        _;
    }

    /**
     * @notice Validates a price is within allowed range
     * @param price Price to validate
     */
    modifier validPrice(uint256 price) {
        if (price > Constants.MAX_MINT_PRICE) {
            revert ErrorLibrary.InvalidAmount(price, "price");
        }
        _;
    }

    /**
     * @notice Ensures signature hasn't been used
     * @param signatureHash Hash of the signature
     */
    modifier nonceNotUsed(bytes32 signatureHash) {
        if (usedSignatures[signatureHash]) {
            revert ErrorLibrary.SignatureReplay(0);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            VERSION CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Current storage version
    uint256 public constant STORAGE_VERSION = 1;

    /**
     * @notice Gets the storage version and last upgrade time
     * @return version Current storage version
     * @return upgradeTime Last upgrade timestamp
     */
    function getVersionData() external view returns (uint256 version, uint256 upgradeTime) {
        return (STORAGE_VERSION, lastUpgradeTimestamp);
    }
}