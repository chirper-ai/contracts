// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TaxVault
 * @dev Manages tax collection and distribution from agent token trading.
 * 
 * The TaxVault:
 * 1. Collects taxes from token trades
 * 2. Manages distribution settings
 * 3. Handles recipient management
 * 4. Provides emergency functions
 * 
 * Tax distribution can be configured with:
 * - Multiple recipients with different shares
 * - Minimum distribution thresholds
 * - Manual or automatic distribution
 */
contract TaxVault is 
    Initializable, 
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Distribution recipient configuration
     * @param recipient Address receiving distributions
     * @param share Percentage share in basis points
     * @param isActive Whether recipient is currently active
     */
    struct Recipient {
        address recipient;
        uint256 share;
        bool isActive;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role for managing recipients
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Basis points denominator for share calculations
    uint256 private constant BASIS_POINTS = 100_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Asset token being collected
    address public assetToken;

    /// @notice Factory contract reference
    address public factory;

    /// @notice Minimum amount for distributions
    uint256 public minDistributionAmount;

    /// @notice List of all recipients
    Recipient[] public recipients;

    /// @notice Maps recipient address to their index
    mapping(address => uint256) public recipientIndex;

    /// @notice Whether a recipient exists
    mapping(address => bool) public isRecipient;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a recipient is added
    event RecipientAdded(address indexed recipient, uint256 share);

    /// @notice Emitted when a recipient is removed
    event RecipientRemoved(address indexed recipient);

    /// @notice Emitted when a recipient's share is updated
    event ShareUpdated(address indexed recipient, uint256 share);

    /// @notice Emitted when tax is distributed
    event Distribution(address[] recipients, uint256[] amounts);

    /// @notice Emitted when minimum distribution amount is updated
    event MinDistributionUpdated(uint256 amount);

    /// @notice Emitted when funds are rescued in emergency
    event FundsRescued(address token, address to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures total shares add up to 100%
    modifier validShares() {
        _;
        uint256 totalShares;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].isActive) {
                totalShares += recipients[i].share;
            }
        }
        require(totalShares == BASIS_POINTS, "Invalid shares");
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the tax vault
     * @param assetToken_ Asset token address
     * @param factory_ Factory contract address
     * @param minDistributionAmount_ Minimum distribution amount
     * @param recipients_ Initial recipient addresses
     * @param shares_ Initial recipient shares
     */
    function initialize(
        address assetToken_,
        address factory_,
        uint256 minDistributionAmount_,
        address[] calldata recipients_,
        uint256[] calldata shares_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(assetToken_ != address(0), "Invalid asset token");
        require(factory_ != address(0), "Invalid factory");
        require(recipients_.length == shares_.length, "Length mismatch");
        require(recipients_.length > 0, "No recipients");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        assetToken = assetToken_;
        factory = factory_;
        minDistributionAmount = minDistributionAmount_;

        uint256 totalShares;
        for (uint256 i = 0; i < recipients_.length; i++) {
            require(recipients_[i] != address(0), "Invalid recipient");
            require(shares_[i] > 0, "Invalid share");
            require(!isRecipient[recipients_[i]], "Duplicate recipient");

            recipients.push(Recipient({
                recipient: recipients_[i],
                share: shares_[i],
                isActive: true
            }));
            recipientIndex[recipients_[i]] = i;
            isRecipient[recipients_[i]] = true;
            totalShares += shares_[i];

            emit RecipientAdded(recipients_[i], shares_[i]);
        }

        require(totalShares == BASIS_POINTS, "Invalid total shares");
    }

    /*//////////////////////////////////////////////////////////////
                         DISTRIBUTION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Distributes collected taxes to recipients
     * @dev Can be called by anyone when threshold is met
     */
    function distribute() external nonReentrant {
        uint256 balance = IERC20(assetToken).balanceOf(address(this));
        require(balance >= minDistributionAmount, "Below minimum");

        uint256 activeRecipients;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].isActive) activeRecipients++;
        }

        address[] memory addrs = new address[](activeRecipients);
        uint256[] memory amounts = new uint256[](activeRecipients);
        uint256 j;

        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].isActive) {
                addrs[j] = recipients[i].recipient;
                amounts[j] = (balance * recipients[i].share) / BASIS_POINTS;
                IERC20(assetToken).safeTransfer(addrs[j], amounts[j]);
                j++;
            }
        }

        emit Distribution(addrs, amounts);
    }

    /**
     * @notice Checks if distribution is possible
     * @return canDistribute Whether distribution threshold is met
     * @return currentBalance Current balance
     */
    function canDistribute() external view returns (bool, uint256) {
        uint256 balance = IERC20(assetToken).balanceOf(address(this));
        return (balance >= minDistributionAmount, balance);
    }

    /*//////////////////////////////////////////////////////////////
                         RECIPIENT MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new recipient
     * @param recipient Recipient address
     * @param share Share in basis points
     */
    function addRecipient(
        address recipient,
        uint256 share
    ) external onlyRole(MANAGER_ROLE) validShares {
        require(recipient != address(0), "Invalid recipient");
        require(share > 0, "Invalid share");
        require(!isRecipient[recipient], "Already exists");

        recipients.push(Recipient({
            recipient: recipient,
            share: share,
            isActive: true
        }));
        recipientIndex[recipient] = recipients.length - 1;
        isRecipient[recipient] = true;

        emit RecipientAdded(recipient, share);
    }

    /**
     * @notice Removes a recipient
     * @param recipient Recipient address
     */
    function removeRecipient(
        address recipient
    ) external onlyRole(MANAGER_ROLE) validShares {
        require(isRecipient[recipient], "Not found");
        uint256 index = recipientIndex[recipient];
        recipients[index].isActive = false;
        isRecipient[recipient] = false;

        emit RecipientRemoved(recipient);
    }

    /**
     * @notice Updates a recipient's share
     * @param recipient Recipient address
     * @param share New share in basis points
     */
    function updateShare(
        address recipient,
        uint256 share
    ) external onlyRole(MANAGER_ROLE) validShares {
        require(isRecipient[recipient], "Not found");
        require(share > 0, "Invalid share");
        
        uint256 index = recipientIndex[recipient];
        recipients[index].share = share;

        emit ShareUpdated(recipient, share);
    }

    /**
     * @notice Updates minimum distribution amount
     * @param amount New minimum amount
     */
    function setMinDistribution(
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        minDistributionAmount = amount;
        emit MinDistributionUpdated(amount);
    }

    /*//////////////////////////////////////////////////////////////
                         EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rescues tokens in emergency
     * @param token Token address to rescue
     * @param to Address to send tokens to
     * @param amount Amount to rescue
     */
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ADMIN_ROLE) {
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
        emit FundsRescued(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns all recipient information
     * @return Array of recipients and their configurations
     */
    function getRecipients() external view returns (Recipient[] memory) {
        return recipients;
    }

    /**
     * @notice Returns number of recipients
     * @return Count of recipients
     */
    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }
}