// SPDX-License-Identifier: MIT
// Created by chirper.build
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";

/**
 * @title Token
 * @dev Implementation of the ERC20 token standard for AI agents with tax functionality
 */
contract Token is Context, IERC20, Ownable {
    /// @notice Token decimals (fixed at 18)
    uint8 private constant DECIMALS = 18;

    /// @notice Total token supply
    uint256 private totalTokenSupply;

    /// @notice Token name
    string private tokenName;

    /// @notice Token symbol
    string private tokenSymbol;

    /// @notice Maximum transaction size as percentage of total supply
    uint256 public maxTransactionPercent;

    /// @notice Maximum transaction amount in token units
    uint256 private maxTransactionAmount;

    /// @notice Whether the token has graduated to Uniswap
    bool public hasGraduated;

    /// @notice Buy tax rate in basis points (1/100 of 1%)
    uint256 public buyTaxRate;

    /// @notice Sell tax rate in basis points (1/100 of 1%)
    uint256 public sellTaxRate;

    /// @notice Platform vault that receives tax fees
    address public taxVault;

    /// @notice Token creator address that receives tax fees
    address public creatorTaxRecipient;

    /// @notice Maps addresses to their token balances
    mapping(address => uint256) private balances;

    /// @notice Maps owner addresses to their spender allowances
    mapping(address => mapping(address => uint256)) private allowances;

    /// @notice Maps addresses that are excluded from transaction limits
    mapping(address => bool) private transactionLimitExempt;

    /// @notice Maps addresses that are excluded from taxes
    mapping(address => bool) private taxExempt;

    /// @notice Maps pairs (e.g., Uniswap) for tax calculation
    mapping(address => bool) public isPair;

    /// @notice Emitted when max transaction limit is updated
    event MaxTransactionUpdated(uint256 newMaxPercent);

    /// @notice Emitted when token graduates
    event Graduated();

    /// @notice Emitted when tax parameters are updated
    event TaxUpdated(uint256 buyTax, uint256 sellTax);

    /// @notice Emitted when tax recipients are updated
    event TaxRecipientsUpdated(address taxVault, address creatorTaxRecipient);

    /// @notice Emitted when pair status is updated
    event PairUpdated(address pair, bool isPair);

    /**
     * @notice Creates a new Agent token
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param initialSupply Initial supply in whole tokens
     * @param maxTxPercent Maximum transaction size as percentage
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply,
        uint256 maxTxPercent
    ) Ownable(msg.sender) {
        tokenName = name_;
        tokenSymbol = symbol_;
        totalTokenSupply = initialSupply * 10 ** DECIMALS;
        
        balances[_msgSender()] = totalTokenSupply;
        
        transactionLimitExempt[_msgSender()] = true;
        transactionLimitExempt[address(this)] = true;
        taxExempt[_msgSender()] = true;
        taxExempt[address(this)] = true;
        
        _updateMaxTransaction(maxTxPercent);
        
        emit Transfer(address(0), _msgSender(), totalTokenSupply);
    }

    /// @notice Returns the token name
    function name() public view returns (string memory) {
        return tokenName;
    }

    /// @notice Returns the token symbol
    function symbol() public view returns (string memory) {
        return tokenSymbol;
    }

    /// @notice Returns the number of decimals (18)
    function decimals() public pure returns (uint8) {
        return DECIMALS;
    }

    /// @notice Returns the total token supply
    function totalSupply() public view override returns (uint256) {
        return totalTokenSupply;
    }

    /// @notice Returns the token balance of an account
    function balanceOf(address account) public view override returns (uint256) {
        return balances[account];
    }

    /**
     * @notice Transfers tokens to a recipient
     * @param recipient Address receiving the tokens
     * @param amount Amount of tokens to transfer
     */
    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _update(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @notice Returns the remaining allowance for a spender
     * @param owner Address that owns the tokens
     * @param spender Address approved to spend tokens
     */
    function allowance(
        address owner,
        address spender
    ) public view override returns (uint256) {
        return allowances[owner][spender];
    }

    /**
     * @notice Approves a spender to spend tokens
     * @param spender Address to approve
     * @param amount Amount of tokens to approve
     */
    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @notice Transfers tokens from one address to another
     * @param sender Address sending the tokens
     * @param recipient Address receiving the tokens
     * @param amount Amount of tokens to transfer
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _update(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            allowances[sender][_msgSender()] - amount
        );
        return true;
    }

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
        if (!hasGraduated || taxExempt[from] || taxExempt[to]) {
            return 0;
        }

        uint256 taxRate;
        if (isPair[from]) {
            // Buy tax
            taxRate = (buyTaxRate / 100);
        } else if (isPair[to]) {
            // Sell tax
            taxRate = (sellTaxRate / 100);
        } else {
            // No tax on wallet transfers
            return 0;
        }

        return (amount * taxRate) / 100; // Base 100 for basis points
    }

    /**
     * @notice Internal function to approve token spending
     * @param owner Address approving the spend
     * @param spender Address being approved
     * @param amount Amount being approved
     */
    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "Invalid owner");
        require(spender != address(0), "Invalid spender");

        allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @notice Internal function to transfer tokens
     * @param from Address sending tokens
     * @param to Address receiving tokens
     * @param amount Amount of tokens to transfer
     */
    function _update(address from, address to, uint256 amount) private {
        require(from != address(0), "Invalid sender");
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");

        if (!transactionLimitExempt[from]) {
            require(amount <= maxTransactionAmount, "Exceeds limit");
        }

        uint256 taxAmount = _calculateTax(from, to, amount);
        uint256 finalAmount = amount - taxAmount;

        if (taxAmount > 0) {
            // Split tax between recipients
            uint256 creatorTax = taxAmount / 2;
            uint256 treasuryTax = taxAmount - creatorTax;

            balances[taxVault] = balances[taxVault] + treasuryTax;
            emit Transfer(from, taxVault, treasuryTax);

            balances[creatorTaxRecipient] = balances[creatorTaxRecipient] + creatorTax;
            emit Transfer(from, creatorTaxRecipient, creatorTax);
        }

        balances[from] = balances[from] - amount;
        balances[to] = balances[to] + finalAmount;

        emit Transfer(from, to, finalAmount);
    }

    /**
     * @notice Internal function to update max transaction limit
     * @param newMaxPercent New maximum as percentage of total supply
     */
    function _updateMaxTransaction(uint256 newMaxPercent) internal {
        maxTransactionPercent = newMaxPercent;
        maxTransactionAmount = (newMaxPercent * totalTokenSupply) / 100;
        emit MaxTransactionUpdated(newMaxPercent);
    }

    /**
     * @notice Updates the maximum transaction limit
     * @param newMaxPercent New maximum as percentage of total supply
     */
    function updateMaxTransaction(uint256 newMaxPercent) external onlyOwner {
        _updateMaxTransaction(newMaxPercent);
    }

    /**
     * @notice Sets the graduated status (can only be set once)
     */
    function graduate() external onlyOwner {
        require(!hasGraduated, "Already graduated");
        hasGraduated = true;
        emit Graduated();
    }

    /**
     * @notice Updates tax rates
     * @param newBuyTax New buy tax rate in basis points
     * @param newSellTax New sell tax rate in basis points
     */
    function setTaxRates(
        uint256 newBuyTax,
        uint256 newSellTax
    ) external onlyOwner {
        require(newBuyTax <= 1000 && newSellTax <= 1000, "Tax too high"); // Max 10%
        buyTaxRate = newBuyTax;
        sellTaxRate = newSellTax;
        emit TaxUpdated(newBuyTax, newSellTax);
    }

    /**
     * @notice Updates tax recipients
     * @param newTaxVault New platform tax vault
     * @param newCreatorRecipient New creator tax recipient
     */
    function setTaxRecipients(
        address newTaxVault,
        address newCreatorRecipient
    ) external onlyOwner {
        require(newTaxVault != address(0) && newCreatorRecipient != address(0), "Invalid address");
        taxVault = newTaxVault;
        creatorTaxRecipient = newCreatorRecipient;
        emit TaxRecipientsUpdated(newTaxVault, newCreatorRecipient);
    }

    /**
     * @notice Excludes an address from transaction limits
     * @param account Address to exclude
     */
    function excludeFromTransactionLimit(address account) external onlyOwner {
        require(account != address(0), "Invalid address");
        transactionLimitExempt[account] = true;
    }

    /**
     * @notice Excludes an address from taxes
     * @param account Address to exclude
     */
    function excludeFromTax(address account) external onlyOwner {
        require(account != address(0), "Invalid address");
        taxExempt[account] = true;
    }

    /**
     * @notice Sets or unsets a pair address
     * @param account Address to update
     * @param isPairAddress Whether the address is a pair
     */
    function setPair(address account, bool isPairAddress) external onlyOwner {
        require(account != address(0), "Invalid address");
        isPair[account] = isPairAddress;
        emit PairUpdated(account, isPairAddress);
    }

    /**
     * @notice Burns tokens from an address
     * @param account Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address account, uint256 amount) external onlyOwner {
        require(account != address(0), "Invalid address");
        balances[account] = balances[account] - amount;
        totalTokenSupply = totalTokenSupply - amount;
        emit Transfer(account, address(0), amount);
    }
}