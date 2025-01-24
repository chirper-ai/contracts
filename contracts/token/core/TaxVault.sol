// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TaxVaultUpgradeable
 * @dev Global tax collection and distribution system for AI agent tokens.
 * 
 * The TaxVault contract serves as a centralized fee management system that:
 * 1. Collects trading fees from all registered tokens
 * 2. Manages per-token distribution configurations
 * 3. Handles automated and manual fee distribution
 * 4. Provides emergency recovery functions
 * 
 * Upgradeability:
 * This contract implements the UUPS (Universal Upgradeable Proxy Standard) pattern which:
 * - Allows for future upgrades to the contract logic
 * - Maintains the same address and state across upgrades
 * - Requires explicit authorization through UPGRADER_ROLE
 * - Persists immutable values through constructor
 * - Initializes other state through initialize()
 * 
 * Fee Distribution Model:
 * - Each token has its own set of recipients with configurable shares
 * - Shares are measured in basis points (1/100th of 1%)
 * - Total shares must equal 100,000 basis points (100%)
 * - Recipients can be marked active/inactive without removing them
 * 
 * Distribution Process:
 * 1. Fees accumulate in vault from token trades
 * 2. Distribution triggered manually or automatically
 * 3. Fees split according to recipient shares
 * 4. Transfer executed to active recipients only
 * 
 * Common share configurations:
 * - 50/50: Creator and platform split (default)
 * - 40/40/20: Creator, platform, and development
 * - 30/30/40: Creator, platform, and liquidity
 * 
 * Security Features:
 * - Role-based access control for admin, manager, and upgrader roles
 * - Reentrancy protection on financial operations
 * - Safe token transfers using OpenZeppelin's SafeERC20
 * - Emergency fund recovery for stuck tokens
 * - Initialization protection for upgrade safety
 */
contract TaxVault is 
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable 
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configuration for a fee recipient
     * @param recipient Address to receive distributions
     * @param share Percentage share in basis points (100% = 100,000)
     * @param isActive Whether this recipient receives distributions
     */
    struct Recipient {
        address recipient;
        uint256 share;
        bool isActive;
    }

    /**
     * @notice Per-token distribution configuration
     * @param recipients Array of fee recipients and their shares
     * @param isRegistered Whether token is registered with vault
     */
    struct TokenConfig {
        Recipient[] recipients;
        bool isRegistered;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role for managing recipients
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Role for authorizing contract upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Denominator for basis point calculations (100%)
    uint256 private constant BASIS_POINTS = 100_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Asset token collected as fees (e.g., ETH, USDC)
    address public assetToken;

    /// @notice Factory contract that can register tokens
    address public factory;

    /// @notice Maps token address to its distribution configuration
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice List of all registered token addresses
    address[] public registeredTokens;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new token is registered
    event TokenRegistered(address indexed token, Recipient[] recipients);

    /// @notice Emitted when a token's recipients are updated
    event RecipientsUpdated(address indexed token, Recipient[] updates);

    /// @notice Emitted when fees are distributed
    event Distribution(
        address indexed token,
        address[] recipients,
        uint256[] amounts
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures token is registered before operation
     * @param token Token address to check
     */
    modifier onlyRegistered(address token) {
        require(tokenConfigs[token].isRegistered, "Token not registered");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes immutable state variables and disables initializers
     * @dev This constructor is only used by the implementation contract
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the contract for proxy deployment
     * @dev Sets up access control roles and other mutable state
     * @param factory_ Factory contract address
     * @param assetToken_ Asset token address for fee collection
     * Called only once when the proxy is deployed
     */
    function initialize(
        address factory_,
        address assetToken_
    ) external initializer {
        require(assetToken_ != address(0), "Invalid asset token");
        require(factory_ != address(0), "Invalid factory");
        
        assetToken = assetToken_;
        factory = factory_;
        
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                         REGISTRATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers a new token with initial 50/50 fee split
     * @param token Token address to register
     * @param creator Token creator address
     * @param platformTreasury Platform treasury address
     * @return success Whether registration was successful
     */
    function registerAgent(
        address token,
        address creator,
        address platformTreasury
    ) external returns (bool) {
        require(msg.sender == factory, "Only factory");
        require(!tokenConfigs[token].isRegistered, "Already registered");
        require(creator != address(0), "Invalid creator");
        require(platformTreasury != address(0), "Invalid treasury");

        Recipient[] memory initialRecipients = new Recipient[](2);
        
        initialRecipients[0] = Recipient({
            recipient: creator,
            share: 50_000, // 50%
            isActive: true
        });

        initialRecipients[1] = Recipient({
            recipient: platformTreasury,
            share: 50_000, // 50%
            isActive: true
        });

        tokenConfigs[token].recipients = initialRecipients;
        tokenConfigs[token].isRegistered = true;
        registeredTokens.push(token);

        emit TokenRegistered(token, initialRecipients);
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        DISTRIBUTION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Distributes accumulated fees for a token
     * @param token Token address to distribute fees for
     * 
     * Distribution Process:
     * 1. Get current balance of asset tokens
     * 2. Calculate active recipient count
     * 3. Calculate each recipient's share
     * 4. Transfer shares to active recipients
     * 
     * Requirements:
     * - Token must be registered
     * - Vault must have non-zero balance
     * - At least one active recipient
     */
    function distribute(
        address token
    ) external nonReentrant onlyRegistered(token) {
        TokenConfig storage config = tokenConfigs[token];
        uint256 balance = IERC20(assetToken).balanceOf(address(this));
        require(balance > 0, "No balance");

        uint256 activeRecipients;
        for (uint256 i = 0; i < config.recipients.length; i++) {
            if (config.recipients[i].isActive) activeRecipients++;
        }
        require(activeRecipients > 0, "No active recipients");

        address[] memory addrs = new address[](activeRecipients);
        uint256[] memory amounts = new uint256[](activeRecipients);
        uint256 j;

        for (uint256 i = 0; i < config.recipients.length; i++) {
            if (config.recipients[i].isActive) {
                addrs[j] = config.recipients[i].recipient;
                amounts[j] = (balance * config.recipients[i].share) / BASIS_POINTS;
                IERC20(assetToken).safeTransfer(addrs[j], amounts[j]);
                j++;
            }
        }

        emit Distribution(token, addrs, amounts);
    }

    /*//////////////////////////////////////////////////////////////
                       CONFIGURATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates recipient configuration for a token
     * @param token Token address to update
     * @param recipients_ New recipient configuration
     * 
     * Requirements:
     * - Caller must have MANAGER_ROLE
     * - Token must be registered
     * - All recipients must be valid addresses
     * - Total shares must equal BASIS_POINTS (100%)
     */
    function updateRecipients(
        address token,
        Recipient[] calldata recipients_
    ) external onlyRole(MANAGER_ROLE) onlyRegistered(token) {
        require(recipients_.length > 0, "No recipients");
        
        uint256 totalShares;
        for (uint256 i = 0; i < recipients_.length; i++) {
            require(recipients_[i].recipient != address(0), "Invalid recipient");
            require(recipients_[i].share > 0, "Invalid share");
            totalShares += recipients_[i].share;
        }

        require(totalShares == BASIS_POINTS, "Invalid shares");
        tokenConfigs[token].recipients = recipients_;
        
        emit RecipientsUpdated(token, recipients_);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if a token is registered with the vault
     * @param token Token address to query
     * @return Whether token is registered
     */
    function hasRegistered(address token) external view returns (bool) {
        return tokenConfigs[token].isRegistered;
    }

    /**
     * @notice Gets current recipient configuration for a token
     * @param token Token address to query
     * @return Array of current recipients
     */
    function getRecipients(
        address token
    ) external view onlyRegistered(token) returns (Recipient[] memory) {
        return tokenConfigs[token].recipients;
    }

    /**
     * @notice Gets all registered token addresses
     * @return Array of registered token addresses
     */
    function getRegisteredTokens() external view returns (address[] memory) {
        return registeredTokens;
    }

    /**
     * @notice Gets total number of registered tokens
     * @return Number of registered tokens
     */
    function tokenCount() external view returns (uint256) {
        return registeredTokens.length;
    }

    /*//////////////////////////////////////////////////////////////
                         UPGRADE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @param newImplementation Address of new implementation contract
     * @dev Required by UUPS pattern, restricted to UPGRADER_ROLE
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}
}