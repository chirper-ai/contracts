// file: contracts/token/core/AgentToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "../libraries/ErrorLibrary.sol";
import "../libraries/Constants.sol";

/**
 * @title AgentToken
 * @notice ERC20 token that supports both bonding-curve-based trading (pre-graduation)
 *         and DEX-based trading (post-graduation). Collects taxes on buys/sells.
 *
 * @dev Key features:
 *  - Upgradeable proxy pattern.
 *  - Role-based access control.
 *  - Tax collection system for both bonding trades and DEX trades.
 *  - Graduation mechanism to finalize bridging from the bonding curve to external DEXes.
 *  - Reentrancy protection and pausable functionality.
 *  - Built to work seamlessly with 18-decimal base assets (e.g. DAI, WETH, WMODE) in the bonding manager.
 */
contract AgentToken is 
    Initializable, 
    ERC20Upgradeable, 
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    /// @notice Address of the bonding curve contract that manages token pricing (pre-graduation)
    address public bondingContract;

    /// @notice Flag indicating if token has graduated from bonding curve to DEX trading
    bool public isGraduated;

    /// @notice Protocol tax collection address for platform fees
    address public taxVault;

    /// @notice Creator tax collection address for creator revenue share
    address public creatorVault;

    /// @notice Buy tax rate in basis points (e.g., 100 = 1%)
    uint256 public buyTax;

    /// @notice Sell tax rate in basis points (e.g., 100 = 1%)
    uint256 public sellTax;

    /**
     * @notice Mapping to track addresses exempt from paying taxes
     * @dev Used for system contracts and privileged addresses
     */
    mapping(address => bool) public isExcludedFromTax;

    /**
     * @notice Tracks known DEX pair addresses post-graduation.
     * @dev If dexPairs[someAddress] is true, then:
     *      - Transfers from that address are treated as "buys"
     *      - Transfers to that address are treated as "sells"
     */
    mapping(address => bool) public dexPairs;

    // ------------------------------------------------------------------------
    // EVENTS
    // ------------------------------------------------------------------------

    /**
     * @notice Emitted when bonding contract address is updated
     * @param newContract Address of the new bonding contract
     */
    event BondingContractUpdated(address newContract);

    /**
     * @notice Emitted when graduation status changes
     * @param graduated New graduation status
     */
    event GraduationUpdated(bool graduated);

    /**
     * @notice Emitted when tax configuration is updated
     * @param taxVault New protocol tax collection address
     * @param creatorVault New creator tax collection address
     * @param buyTax New buy tax rate in basis points
     * @param sellTax New sell tax rate in basis points
     */
    event TaxConfigUpdated(
        address indexed taxVault,
        address indexed creatorVault,
        uint256 buyTax,
        uint256 sellTax
    );

    /**
     * @notice Emitted when a transfer's tax is collected
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @param platformTax Amount of tax sent to platform
     * @param creatorTax Amount of tax sent to creator
     * @param isBuy Whether this was a "buy" (tokens flowing from bonding/DEX to user)
     */
    event TaxCollected(
        address indexed from,
        address indexed to,
        uint256 platformTax,
        uint256 creatorTax,
        bool isBuy
    );

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     * @dev Prevents implementation contract initialization to enforce proxy pattern
     */
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------------
    // INITIALIZER
    // ------------------------------------------------------------------------

    /**
     * @notice Initializes the token contract with basic parameters
     * @dev This replaces the constructor for upgradeable contracts
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param implementation Bonding curve contract address (manages mint/burn pre-graduation)
     * @param registry Protocol tax vault address
     * @param platform Platform admin address
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address implementation,
        address registry,
        address platform
    ) external initializer {
        // Validate addresses
        ErrorLibrary.validateAddress(implementation, "implementation");
        ErrorLibrary.validateAddress(registry, "registry");
        ErrorLibrary.validateAddress(platform, "platform");

        // Initialize inherited contracts
        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Grant relevant roles to the deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.UPGRADER_ROLE, msg.sender);
        _grantRole(Constants.TAX_MANAGER_ROLE, msg.sender);
        _grantRole(Constants.PAUSER_ROLE, msg.sender);
        _grantRole(Constants.PLATFORM_ROLE, platform);
        _grantRole(Constants.TAX_MANAGER_ROLE, implementation);

        // Store references
        bondingContract = implementation;
        taxVault = registry;
        creatorVault = msg.sender; // Creator gets the tax share by default

        // By default, exclude these addresses from tax
        isExcludedFromTax[implementation] = true;  
        isExcludedFromTax[msg.sender] = true;      
        isExcludedFromTax[platform] = true;        
        isExcludedFromTax[registry] = true;        
    }

    // ------------------------------------------------------------------------
    // MINT / BURN (Bonding-Contract Only)
    // ------------------------------------------------------------------------

    /**
     * @notice Mints new tokens (only callable by bonding contract)
     * @dev Used during buy operations on the bonding curve
     * @param to Address to receive new tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external {
        // Only the designated bonding contract can mint
        if (msg.sender != bondingContract) {
            revert ErrorLibrary.Unauthorized(msg.sender, 0, "mint");
        }
        
        // Validate parameters
        ErrorLibrary.validateAddress(to, "to");
        ErrorLibrary.validateAmount(amount, "amount");
        
        // Perform mint
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens (only callable by bonding contract)
     * @dev Used during sell operations on the bonding curve
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external {
        // Only the designated bonding contract can burn
        if (msg.sender != bondingContract) {
            revert ErrorLibrary.Unauthorized(msg.sender, 0, "burn");
        }
        
        // Validate parameters
        ErrorLibrary.validateAddress(from, "from");
        ErrorLibrary.validateAmount(amount, "amount");
        
        // Perform burn
        _burn(from, amount);
    }

    // ------------------------------------------------------------------------
    // TAX & GRADUATION MANAGEMENT
    // ------------------------------------------------------------------------

    /**
     * @notice Updates the bonding contract address
     * @dev Only callable by admin. Also marks the new contract as tax-exempt.
     * @param newBonding New bonding contract address
     */
    function setBondingContract(address newBonding) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ErrorLibrary.validateAddress(newBonding, "newBonding");
        bondingContract = newBonding;
        isExcludedFromTax[newBonding] = true;
        emit BondingContractUpdated(newBonding);
    }

    /**
     * @notice Updates tax configuration
     * @dev Only callable by TAX_MANAGER_ROLE
     * @param newTaxVault New protocol tax vault address
     * @param newCreatorVault New creator tax vault address
     * @param newBuyTax New buy tax rate (bps)
     * @param newSellTax New sell tax rate (bps)
     */
    function setTaxConfig(
        address newTaxVault,
        address newCreatorVault,
        uint256 newBuyTax,
        uint256 newSellTax
    ) external onlyRole(Constants.TAX_MANAGER_ROLE) {
        // Validate parameters
        ErrorLibrary.validateAddress(newTaxVault, "newTaxVault");
        ErrorLibrary.validateAddress(newCreatorVault, "newCreatorVault");
        ErrorLibrary.validateTaxRate(newBuyTax, Constants.MAX_TAX_RATE);
        ErrorLibrary.validateTaxRate(newSellTax, Constants.MAX_TAX_RATE);

        taxVault = newTaxVault;
        creatorVault = newCreatorVault;
        buyTax = newBuyTax;
        sellTax = newSellTax;

        emit TaxConfigUpdated(newTaxVault, newCreatorVault, newBuyTax, newSellTax);
    }

    /**
     * @notice Marks this token as graduated to DEX trading
     * @dev Only callable by bonding contract, a one-way operation
     */
    function graduate() external {
        if (msg.sender != bondingContract) {
            revert ErrorLibrary.Unauthorized(msg.sender, 0, "graduate");
        }
        if (isGraduated) {
            revert ErrorLibrary.TokenAlreadyGraduated(address(this));
        }
        isGraduated = true;
        emit GraduationUpdated(true);
    }

    /**
     * @notice Sets tax exclusion status for an address
     * @dev Only callable by TAX_MANAGER_ROLE
     * @param account Address to update
     * @param excluded Whether account should be excluded from tax
     */
    function setTaxExclusion(
        address account, 
        bool excluded
    ) external onlyRole(Constants.TAX_MANAGER_ROLE) {
        ErrorLibrary.validateAddress(account, "account");
        isExcludedFromTax[account] = excluded;
    }

    /**
     * @notice Registers or unregisters an address as a recognized DEX pair
     * @dev Only callable by TAX_MANAGER_ROLE
     *      If `value == true`, transfers from that address => buy. 
     *      If transfers to that address => sell.
     * @param pair Address of the DEX pair
     * @param value True to add as DEX pair, false to remove
     */
    function setDexPair(address pair, bool value) external onlyRole(Constants.TAX_MANAGER_ROLE) {
        ErrorLibrary.validateAddress(pair, "pair");
        dexPairs[pair] = value;
    }

    // ------------------------------------------------------------------------
    // ERC20 TRANSFER OVERRIDES (TAX LOGIC)
    // ------------------------------------------------------------------------

    /**
     * @dev Overrides the _update function to implement tax collection on transfers.
     * This handles both regular transfers and minting/burning operations.
     * @param from The address tokens are being transferred from
     * @param to The address tokens are being transferred to
     * @param value The amount of tokens being transferred
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        // Skip tax logic for:
        // 1. Minting/burning operations
        // 2. Transfers from/to bonding contract
        // 3. Transfers from/to self
        // 4. When sender is excluded from tax
        if (from == address(0) || 
            to == address(0) || 
            msg.sender == bondingContract ||
            msg.sender == address(this) ||
            isExcludedFromTax[msg.sender]) {
            super._update(from, to, value);
            return;
        }

        // If either party is excluded from tax, process normally
        if (isExcludedFromTax[from] || isExcludedFromTax[to]) {
            super._update(from, to, value);
            return;
        }

        // Determine if this is buy or sell
        bool isBuy = false;
        bool isSell = false;

        if (!isGraduated) {
            // Pre-graduation logic
            if (to == bondingContract) {
                isSell = true;
            } else if (from == bondingContract) {
                isBuy = true;
            }
        } else {
            // Post-graduation logic
            if (dexPairs[from]) {
                isBuy = true;
            } else if (dexPairs[to]) {
                isSell = true;
            }
        }

        uint256 taxRate = isBuy ? buyTax : (isSell ? sellTax : 0);
        
        if (taxRate > 0) {
            uint256 totalTax = (value * taxRate) / Constants.BASIS_POINTS;
            if (totalTax > 0) {
                uint256 platformTaxAmount = (totalTax * Constants.PLATFORM_FEE_SHARE) /
                    (Constants.PLATFORM_FEE_SHARE + Constants.CREATOR_FEE_SHARE);
                uint256 creatorTaxAmount = totalTax - platformTaxAmount;
                uint256 netAmount = value - totalTax;

                // Process tax transfers
                super._update(from, taxVault, platformTaxAmount);
                super._update(from, creatorVault, creatorTaxAmount);
                
                // Then main transfer
                super._update(from, to, netAmount);

                emit TaxCollected(from, to, platformTaxAmount, creatorTaxAmount, isBuy);
                return;
            }
        }
        
        // No tax
        super._update(from, to, value);
    }

    // ------------------------------------------------------------------------
    // PAUSABLE
    // ------------------------------------------------------------------------

    /**
     * @notice Pauses all token transfers
     * @dev Only callable by PAUSER_ROLE
     */
    function pause() external onlyRole(Constants.PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses token transfers
     * @dev Only callable by PAUSER_ROLE
     */
    function unpause() external onlyRole(Constants.PAUSER_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------------
    // MISC
    // ------------------------------------------------------------------------

    /**
     * @notice Forces an approval overwrite
     * @dev Required for certain DEX operations (like some Router calls)
     * @param spender Address being approved
     * @param amount Amount of approval
     * @return bool Success indicator
     */
    function forceApprove(address spender, uint256 amount) external returns (bool) {
        ErrorLibrary.validateAddress(spender, "spender");
        _approve(_msgSender(), spender, amount);
        return true;
    }

    // ------------------------------------------------------------------------
    // ADMIN ROLE ASSIGNMENT (SIMPLE APPROACH)
    // ------------------------------------------------------------------------

    /**
     * @notice Allows the admin to assign any role to a given address
     * @param role The role to assign
     * @param account The address receiving the role
     */
    function assignRole(bytes32 role, address account)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _grantRole(role, account);
    }

    /**
     * @notice Allows the admin to revoke any role from a given address
     * @param role The role to revoke
     * @param account The address losing the role
     */
    function removeRole(bytes32 role, address account)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _revokeRole(role, account);
    }
}
