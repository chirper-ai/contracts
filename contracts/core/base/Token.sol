// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../../interfaces/IRouter.sol";
import "../../interfaces/IManager.sol";

/**
 * @title Token
 * @dev ERC20 token implementation for AI agents with tax and graduation mechanics.
 * 
 * Core features:
 * 1. Tax System
 *    - Buy tax: Percentage fee on bonding curve purchases and DEX buys
 *    - Sell tax: Percentage fee on bonding curve sales and DEX sells
 *    - Tax distribution: Split 50-50 between creator and platform treasury
 *    - Tax exemptions: Configurable per address by owner
 *    - No tax on direct wallet transfers
 * 
 * 2. Trading Phases
 *    - Pre-graduation: Trades exclusively through bonding curve
 *    - Post-graduation: Trades through whitelisted DEX pools
 *    - Graduation is permanent and managed by manager contract
 * 
 * 3. Security Features
 *    - Reentrancy protection on state-changing operations
 *    - Input validation on all parameters
 *    - Immutable core parameters
 *    - Zero address checks
 * 
 * Example tax calculation:
 * - Transfer amount: 1000 tokens
 * - Buy tax: 1% (1000 basis points)
 * - Tax amount = 1000 * 1000 / 100000 = 10 tokens
 * - Creator receives: 5 tokens
 * - Treasury receives: 5 tokens
 * - Recipient receives: 990 tokens
 */
contract Token is ERC20, ERC20Permit, Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Denominator for basis point calculations (100%)
    /// @dev Used to convert basis points to percentages (e.g., 1000 bp = 1%)
    uint256 private constant BASIS_POINTS = 100_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Reference URL for token metadata and documentation
    string public url;

    /// @notice Description of token's intended use case
    string public intention;

    /// @notice Tax rate for buy operations in basis points (1000 = 1%)
    uint256 public buyTax;

    /// @notice Tax rate for sell operations in basis points (1000 = 1%)
    uint256 public sellTax;

    /// @notice Address receiving 50% of collected taxes
    address public creator;

    /// @notice Address receiving remaining 50% of taxes
    address public platformTreasury;

    /// @notice Contract controlling graduation process
    address public immutable manager;

    /// @notice Indicates if token has moved to DEX trading phase
    bool public hasGraduated;

    /// @notice Addresses exempted from tax collection
    mapping(address => bool) public isTaxExempt;

    /// @notice Whitelisted DEX pool addresses post-graduation
    mapping(address => bool) public isPool;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Indicates transition to DEX trading phase
     * @param pools Authorized DEX pool addresses
     */
    event Graduated(address[] pools);

    /**
     * @notice Records tax parameter updates
     * @param buyTax_ Updated buy tax rate
     * @param sellTax_ Updated sell tax rate
     */
    event TaxUpdated(uint256 buyTax_, uint256 sellTax_);

    /**
     * @notice Tracks changes to pool whitelist
     * @param pool DEX pool address
     * @param isPool Authorization status
     */
    event PoolUpdated(address indexed pool, bool isPool);

    /**
     * @notice Records tax exemption changes
     * @param account Modified address
     * @param isExempt New exemption status
     */
    event TaxExemptUpdated(address indexed account, bool isExempt);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys and configures token contract
     * @param name_ ERC20 token name
     * @param symbol_ ERC20 token symbol
     * @param initialSupply_ Starting token supply (in standard units)
     * @param url_ Metadata URL
     * @param intention_ Token purpose description
     * @param manager_ Graduation manager address
     * @param creator_ Tax recipient address
     * @param platformTreasury_ Platform tax recipient address
     * @dev Sets default 1% tax rates and exempts contract + deployer
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        string memory url_,
        string memory intention_,
        address manager_,
        address creator_,
        address platformTreasury_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(msg.sender) {
        require(manager_ != address(0), "Invalid manager");
        require(initialSupply_ > 0, "Invalid supply");

        url = url_;
        intention = intention_;
        manager = manager_;
        creator = creator_;
        platformTreasury = platformTreasury_;

        buyTax = 1_000;
        sellTax = 1_000;

        isTaxExempt[address(this)] = true;
        isTaxExempt[msg.sender] = true;

        _mint(msg.sender, initialSupply_);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transitions token to DEX trading phase
     * @param pools Authorized DEX pool addresses
     * @dev Only callable once by manager contract
     */
    function graduate(address[] calldata pools) external nonReentrant {
        require(msg.sender == manager, "Only manager");
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
     * @notice Configures tax exemption status
     * @param account Target address
     * @param isExempt Exemption flag
     * @dev Restricted to contract owner
     */
    function setTaxExempt(address account, bool isExempt) external onlyOwner {
        require(account != address(0), "Invalid address");
        isTaxExempt[account] = isExempt;
        emit TaxExemptUpdated(account, isExempt);
    }

    /**
     * @notice sets new platform treasury address
     * @param newTreasury New treasury address
     * @dev Restricted to contract owner
     */
    function setPlatformTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury");
        require(newTreasury != platformTreasury, "Identical treasury");
        platformTreasury = newTreasury;
    }

    /**
     * @notice Updates buy tax rate
     * @param newBuyTax New buy tax rate
     */
    function setBuyTax(uint256 newBuyTax) external onlyOwner {
        require(newBuyTax < BASIS_POINTS, "Invalid tax");
        require(newBuyTax != buyTax, "Identical tax rates");
        buyTax = newBuyTax;
        emit TaxUpdated(buyTax, sellTax);
    }

    /**
     * @notice Updates sell tax rate
     * @param newSellTax New sell tax rate
     */
    function setSellTax(uint256 newSellTax) external onlyOwner {
        require(newSellTax < BASIS_POINTS, "Invalid tax");
        require(newSellTax != sellTax, "Identical tax rates");
        sellTax = newSellTax;
        emit TaxUpdated(buyTax, sellTax);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Computes tax for transfer operation
     * @param from Source address
     * @param to Destination address
     * @param amount Transfer amount
     * @return Tax amount to deduct
     * @dev Applies tax based on:
     * 1. Exemption status of addresses
     * 2. Graduation state
     * 3. Transfer type (buy/sell/transfer)
     */
    function _calculateTax(
        address from,
        address to,
        uint256 amount
    ) private view returns (uint256) {
        if (isTaxExempt[from] || isTaxExempt[to]) {
            return 0;
        }
        if (buyTax == 0 && sellTax == 0) {
            return 0;
        }

        if (!hasGraduated) {
            address pair = IManager(manager).getBondingPair(address(this));
            if (pair == from) {
                return (amount * buyTax) / BASIS_POINTS;
            } else if (pair == to) {
                return (amount * sellTax) / BASIS_POINTS;
            }
        }

        if (isPool[from]) {
            return (amount * buyTax) / BASIS_POINTS;
        } else if (isPool[to]) {
            return (amount * sellTax) / BASIS_POINTS;
        }

        return 0;
    }

    /**
     * @notice Enhanced ERC20 transfer logic with tax handling
     * @param from Source address
     * @param to Destination address
     * @param amount Transfer amount
     * @dev Tax workflow:
     * 1. Calculate applicable tax
     * 2. Split tax between creator and treasury
     * 3. Deduct tax from transfer amount
     * 4. Execute final transfer
     */
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        uint256 taxAmount = _calculateTax(from, to, amount);
        
        if (taxAmount > 0) {
            uint256 halfTax = taxAmount / 2;
            super._update(from, creator, halfTax);
            super._update(from, platformTreasury, taxAmount - halfTax);
            amount -= taxAmount;
        }

        super._update(from, to, amount);
    }
}