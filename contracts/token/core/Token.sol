// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Token
 * @dev Implementation of an AI agent token with tax and graduation mechanics.
 * 
 * The token has three key features:
 * 1. Tax collection on trades
 *    - Buy tax: Fee charged when buying from bonding curve
 *    - Sell tax: Fee charged when selling to bonding curve
 *    - Taxes are split between tax vault and token admin
 * 
 * 2. Graduation state
 *    - Initially trades through bonding curve
 *    - After graduation, trades through standard DEXes
 *    - Graduation is one-way and permanent
 * 
 * 3. Max transaction limits
 *    - Prevents large price impacts
 *    - Different limits for buys and sells
 *    - Applies only pre-graduation
 */
contract Token is ERC20, ERC20Permit, Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points denominator for percentage calculations (100%)
    uint256 private constant BASIS_POINTS = 100_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy tax rate in basis points
    uint256 public buyTax;

    /// @notice Sell tax rate in basis points
    uint256 public sellTax;

    /// @notice Maximum transaction size as percentage of total supply
    uint256 public maxTxPercent;

    /// @notice Address where tax is collected
    address public immutable taxVault;

    /// @notice Router contract that manages trading
    address public immutable router;

    /// @notice Whether token has graduated to DEX trading
    bool public hasGraduated;

    /// @notice Maps addresses that are excluded from transaction limits
    mapping(address => bool) public isTxLimitExempt;

    /// @notice Maps addresses that are excluded from taxes
    mapping(address => bool) public isTaxExempt;

    /// @notice Maps liquidity pool addresses
    mapping(address => bool) public isPool;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when token graduates to DEX trading
     * @param pools Array of DEX pool addresses
     */
    event Graduated(address[] pools);

    /**
     * @notice Emitted when tax parameters are updated
     * @param buyTax_ New buy tax rate
     * @param sellTax_ New sell tax rate
     */
    event TaxUpdated(uint256 buyTax_, uint256 sellTax_);

    /**
     * @notice Emitted when max transaction percent is updated
     * @param maxTxPercent_ New max transaction percent
     */
    event MaxTxPercentUpdated(uint256 maxTxPercent_);

    /**
     * @notice Emitted when a pool status is updated
     * @param pool Pool address
     * @param isPool Whether address is a pool
     */
    event PoolUpdated(address indexed pool, bool isPool);

    /**
     * @notice Emitted when tax exemption status is updated
     * @param account Account address
     * @param isExempt Whether account is tax exempt
     */
    event TaxExemptUpdated(address indexed account, bool isExempt);

    /**
     * @notice Emitted when transaction limit exemption is updated
     * @param account Account address
     * @param isExempt Whether account is exempt from limits
     */
    event TxLimitExemptUpdated(address indexed account, bool isExempt);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new AI agent token
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param initialSupply_ Initial supply in whole tokens
     * @param router_ Router contract address
     * @param taxVault_ Tax collection address
     * @dev Initial tax rates and transaction limits can be set by admin later
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        address router_,
        address taxVault_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(msg.sender) {
        require(router_ != address(0), "Invalid router");
        require(taxVault_ != address(0), "Invalid tax vault");
        require(initialSupply_ > 0, "Invalid supply");

        router = router_;
        taxVault = taxVault_;

        // Setup default parameters
        maxTxPercent = 1000; // 1% default max transaction
        buyTax = 500;        // 0.5% default buy tax
        sellTax = 500;       // 0.5% default sell tax

        // Default exemptions
        isTaxExempt[address(this)] = true;
        isTaxExempt[msg.sender] = true;
        isTxLimitExempt[address(this)] = true;
        isTxLimitExempt[msg.sender] = true;
        isTxLimitExempt[router_] = true;

        // Mint initial supply
        _mint(msg.sender, initialSupply_ * (10 ** decimals()));
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets token graduation state and registers DEX pools
     * @param pools Array of DEX pool addresses
     * @dev Can only be called by router and only once
     */
    function graduate(address[] calldata pools) external nonReentrant {
        require(msg.sender == router, "Only router");
        require(!hasGraduated, "Already graduated");
        require(pools.length > 0, "No pools provided");

        hasGraduated = true;

        for (uint256 i = 0; i < pools.length; i++) {
            require(pools[i] != address(0), "Invalid pool");
            isPool[pools[i]] = true;
            emit PoolUpdated(pools[i], true);
        }

        emit Graduated(pools);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates tax rates
     * @param buyTax_ New buy tax rate
     * @param sellTax_ New sell tax rate
     */
    function setTaxes(
        uint256 buyTax_,
        uint256 sellTax_
    ) external onlyOwner {
        require(buyTax_ <= 5000, "Buy tax too high"); // Max 5%
        require(sellTax_ <= 5000, "Sell tax too high"); // Max 5%
        buyTax = buyTax_;
        sellTax = sellTax_;
        emit TaxUpdated(buyTax_, sellTax_);
    }

    /**
     * @notice Updates maximum transaction size
     * @param maxTxPercent_ New max transaction percent
     */
    function setMaxTxPercent(uint256 maxTxPercent_) external onlyOwner {
        require(maxTxPercent_ > 0, "Invalid percent");
        require(maxTxPercent_ <= 5000, "Max tx too high"); // Max 5%
        maxTxPercent = maxTxPercent_;
        emit MaxTxPercentUpdated(maxTxPercent_);
    }

    /**
     * @notice Sets or unsets a pool address
     * @param pool Pool address to update
     * @param isPool_ Whether address is a pool
     */
    function setPool(address pool, bool isPool_) external onlyOwner {
        require(pool != address(0), "Invalid address");
        isPool[pool] = isPool_;
        emit PoolUpdated(pool, isPool_);
    }

    /**
     * @notice Updates tax exemption status for an address
     * @param account Account to update
     * @param isExempt Whether account should be tax exempt
     */
    function setTaxExempt(address account, bool isExempt) external onlyOwner {
        require(account != address(0), "Invalid address");
        isTaxExempt[account] = isExempt;
        emit TaxExemptUpdated(account, isExempt);
    }

    /**
     * @notice Updates transaction limit exemption for an address
     * @param account Account to update
     * @param isExempt Whether account should be exempt from limits
     */
    function setTxLimitExempt(address account, bool isExempt) external onlyOwner {
        require(account != address(0), "Invalid address");
        isTxLimitExempt[account] = isExempt;
        emit TxLimitExemptUpdated(account, isExempt);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates tax amount for a transfer
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     * @return Tax amount to deduct
     */
    function _calculateTax(
        address from,
        address to,
        uint256 amount
    ) private view returns (uint256) {
        // Skip tax for exempt addresses
        if (isTaxExempt[from] || isTaxExempt[to]) {
            return 0;
        }

        // Apply appropriate tax based on transfer type
        if (isPool[from]) {
            return (amount * buyTax) / BASIS_POINTS;  // Buying
        } else if (isPool[to]) {
            return (amount * sellTax) / BASIS_POINTS; // Selling
        }

        // No tax on wallet transfers
        return 0;
    }

    /**
     * @notice Checks if a transfer amount exceeds limits
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     */
    function _checkTransferLimit(
        address from,
        address to,
        uint256 amount
    ) private view {
        if (!hasGraduated && 
            !isTxLimitExempt[from] && 
            !isTxLimitExempt[to]
        ) {
            uint256 maxAmount = (totalSupply() * maxTxPercent) / BASIS_POINTS;
            require(amount <= maxAmount, "Exceeds max transaction");
        }
    }

    /**
     * @notice Override of ERC20 _update to implement taxes
     * @dev Collects tax and enforces transaction limits
     * @param from Sender address
     * @param to Recipient address
     * @param amount Transfer amount
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Check transaction limits
        _checkTransferLimit(from, to, amount);

        // Calculate and collect tax
        uint256 taxAmount = _calculateTax(from, to, amount);
        
        if (taxAmount > 0) {
            // Split tax between vault and admin
            uint256 halfTax = taxAmount / 2;
            super._update(from, taxVault, halfTax);
            super._update(from, owner(), taxAmount - halfTax);
            amount -= taxAmount;
        }

        super._update(from, to, amount);
    }
}