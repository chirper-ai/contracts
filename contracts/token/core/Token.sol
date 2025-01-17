// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Token
 * @dev Implementation of an ERC20 token with tax functionality for AI agents
 * Extends OpenZeppelin's ERC20 implementation with buy/sell taxes
 * and graduated trading functionality
 */
contract Token is ERC20, Ownable {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy tax percentage in basis points (1/100th of 1%)
    uint256 public buyTax;
    
    /// @notice Sell tax percentage in basis points (1/100th of 1%)
    uint256 public sellTax;

    /// @notice Tax vault address where half of all taxes are sent
    address public taxVault;

    /// @notice Manager contract reference for graduation control
    address public immutable manager;

    /// @notice Whether the token has graduated to Uniswap
    bool public hasGraduated;
    
    /// @notice Maps addresses that are excluded from taxes
    mapping(address => bool) private taxExempt;

    /// @notice Maps pools (e.g., Uniswap) for tax calculation
    mapping(address => bool) public isPool;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when token graduates to trading
    event Graduated();

    /// @notice Emitted when pool status is updated
    event PoolUpdated(address pool_, bool isPool_);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new Agent token
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param initialSupply_ Initial supply in whole tokens
     * @param manager_ Address of the manager contract
     * @param buyTax_ Buy tax in basis points (1/100th of 1%)
     * @param sellTax_ Sell tax in basis points (1/100th of 1%)
     * @param taxVault_ Address where tax is collected
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        address manager_,
        uint256 buyTax_,
        uint256 sellTax_,
        address taxVault_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        require(manager_ != address(0), "Invalid manager");
        require(buyTax_ <= 1_000, "Buy tax too high");
        require(sellTax_ <= 1_000, "Sell tax too high");

        manager = manager_;
        buyTax = buyTax_;
        sellTax = sellTax_;
        taxVault = taxVault_;
        
        _mint(msg.sender, initialSupply_ * 10 ** decimals());
        
        taxExempt[msg.sender] = true;
        taxExempt[address(this)] = true;
    }

    /*//////////////////////////////////////////////////////////////
                         MANAGER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Modifier to restrict function to manager only
     */
    modifier onlyManager() {
        require(msg.sender == manager, "Only manager");
        _;
    }

    /**
     * @notice Sets the graduated status and registers multiple pools (can only be set once by manager)
     * @param pools_ Array of pool contract addresses
     */
    function graduate(address[] memory pools_) external onlyManager {
        require(!hasGraduated, "Already graduated");
        require(pools_.length > 0, "Must provide at least one pool");
        
        hasGraduated = true;
        
        for(uint i = 0; i < pools_.length; i++) {
            require(pools_[i] != address(0), "Invalid pool address");
            isPool[pools_[i]] = true;
            emit PoolUpdated(pools_[i], true);
        }
        
        emit Graduated();
    }

    /*//////////////////////////////////////////////////////////////
                         OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Excludes an address from taxes
     * @param account_ Address to exclude
     */
    function excludeFromTax(address account_) external onlyOwner {
        require(account_ != address(0), "Invalid address");
        taxExempt[account_] = true;
    }

    /**
     * @notice Sets or unsets a pool address
     * @param account_ Address to update
     * @param isPool_ Whether the address is a pool
     */
    function setPool(address account_, bool isPool_) external onlyOwner {
        require(account_ != address(0), "Invalid address");
        isPool[account_] = isPool_;
        emit PoolUpdated(account_, isPool_);
    }

    /**
     * @notice Sets the tax parameters for the token
     * @param buyTax_ Buy tax percentage in basis points (1/100th of 1%)
     * @param sellTax_ Sell tax percentage in basis points (1/100th of 1%)
     */
    function setTaxParameters(uint256 buyTax_, uint256 sellTax_) external onlyOwner {
        require(buyTax_ <= 1_000, "Buy tax too high");
        require(sellTax_ <= 1_000, "Sell tax too high");
        buyTax = buyTax_;
        sellTax = sellTax_;
    }

    /**
     * @notice Sets the tax vault address
     * @param taxVault_ Address of the tax vault
     */
    function setTaxVault(address taxVault_) external onlyOwner {
        require(taxVault_ != address(0), "Invalid tax vault");
        taxVault = taxVault_;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates tax amount for a transfer
     * @param from_ Sender address
     * @param to_ Recipient address
     * @param amount_ Transfer amount
     * @return Tax amount to deduct
     */
    function _calculateTax(
        address from_,
        address to_,
        uint256 amount_
    ) private view returns (uint256) {
        // Early return conditions
        if (!hasGraduated || taxExempt[from_] || taxExempt[to_]) {
            return 0;
        }

        if (isPool[from_]) {
            // Buy tax
            return (amount_ * buyTax) / 10_000;
        } else if (isPool[to_]) {
            // Sell tax
            return (amount_ * sellTax) / 10_000;
        }
        
        // No tax on wallet transfers
        return 0;
    }

    /**
     * @notice Override of the ERC20 _update function to handle tax collection
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @param amount Amount of tokens to transfer
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        uint256 taxAmount = _calculateTax(from, to, amount);
        uint256 finalAmount = amount - taxAmount;

        if (taxAmount > 0) {
            // Split tax between vault and owner
            uint256 halfTax = taxAmount / 2;
            super._update(from, taxVault, halfTax);
            super._update(from, owner(), taxAmount - halfTax);
        }

        super._update(from, to, finalAmount);
    }
}