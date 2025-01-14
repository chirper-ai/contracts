// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "./Factory.sol";

/**
 * @title Token
 * @dev Implementation of the ERC20 token standard for AI agents with tax functionality
 * Uses Factory contract for tax rates and vault management
 */
contract Token is Context, IERC20, Ownable {
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Token decimals (fixed at 18)
    uint8 private constant DECIMALS = 18;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

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

    /// @notice Factory contract reference for tax management
    Factory public immutable factory;

    /// @notice Manager contract reference for graduation control
    address public immutable manager;

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

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when max transaction limit is updated
    event MaxTransactionUpdated(uint256 newMaxPercent_);

    /// @notice Emitted when token graduates
    event Graduated();

    /// @notice Emitted when pair status is updated
    event PairUpdated(address pair_, bool isPair_);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new Agent token
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param initialSupply_ Initial supply in whole tokens
     * @param maxTxPercent_ Maximum transaction size as percentage
     * @param factory_ Address of the factory contract
     * @param manager_ Address of the manager contract
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        uint256 maxTxPercent_,
        address factory_,
        address manager_
    ) Ownable(msg.sender) {
        require(factory_ != address(0), "Invalid factory");
        require(manager_ != address(0), "Invalid manager");

        factory = Factory(factory_);
        manager = manager_;
        tokenName = name_;
        tokenSymbol = symbol_;
        totalTokenSupply = initialSupply_ * 10 ** DECIMALS;
        
        balances[_msgSender()] = totalTokenSupply;
        
        transactionLimitExempt[_msgSender()] = true;
        transactionLimitExempt[address(this)] = true;
        taxExempt[_msgSender()] = true;
        taxExempt[address(this)] = true;
        
        _updateMaxTransaction(maxTxPercent_);
        
        emit Transfer(address(0), _msgSender(), totalTokenSupply);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
    function balanceOf(address account_) public view override returns (uint256) {
        return balances[account_];
    }

    /// @notice Returns the remaining allowance for a spender
    function allowance(
        address owner_,
        address spender_
    ) public view override returns (uint256) {
        return allowances[owner_][spender_];
    }

    /*//////////////////////////////////////////////////////////////
                         TOKEN OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfers tokens to a recipient
     * @param recipient_ Address receiving the tokens
     * @param amount_ Amount of tokens to transfer
     */
    function transfer(
        address recipient_,
        uint256 amount_
    ) public override returns (bool) {
        _update(_msgSender(), recipient_, amount_);
        return true;
    }

    /**
     * @notice Approves a spender to spend tokens
     * @param spender_ Address to approve
     * @param amount_ Amount of tokens to approve
     */
    function approve(
        address spender_,
        uint256 amount_
    ) public override returns (bool) {
        _approve(_msgSender(), spender_, amount_);
        return true;
    }

    /**
     * @notice Transfers tokens from one address to another
     * @param sender_ Address sending the tokens
     * @param recipient_ Address receiving the tokens
     * @param amount_ Amount of tokens to transfer
     */
    function transferFrom(
        address sender_,
        address recipient_,
        uint256 amount_
    ) public override returns (bool) {
        _update(sender_, recipient_, amount_);
        _approve(
            sender_,
            _msgSender(),
            allowances[sender_][_msgSender()] - amount_
        );
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                         OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the maximum transaction limit
     * @param newMaxPercent_ New maximum as percentage of total supply
     */
    function updateMaxTransaction(uint256 newMaxPercent_) external onlyOwner {
        _updateMaxTransaction(newMaxPercent_);
    }

    /**
     * @notice Modifier to restrict function to manager only
     */
    modifier onlyManager() {
        require(msg.sender == manager, "Only manager");
        _;
    }

    /**
     * @notice Sets the graduated status (can only be set once by manager)
     * @param pair_ Address of the pair contract
     */
    function graduate(
        address pair_
    ) external onlyManager {
        require(!hasGraduated, "Already graduated");
        require(pair_ != address(0), "Invalid pair address");
        
        hasGraduated = true;
        isPair[pair_] = true;
        
        emit PairUpdated(pair_, true);
        emit Graduated();
    }
    /**
     * @notice Excludes an address from transaction limits
     * @param account_ Address to exclude
     */
    function excludeFromTransactionLimit(address account_) external onlyOwner {
        require(account_ != address(0), "Invalid address");
        transactionLimitExempt[account_] = true;
    }

    /**
     * @notice Excludes an address from taxes
     * @param account_ Address to exclude
     */
    function excludeFromTax(address account_) external onlyOwner {
        require(account_ != address(0), "Invalid address");
        taxExempt[account_] = true;
    }

    /**
     * @notice Sets or unsets a pair address
     * @param account_ Address to update
     * @param isPair_ Whether the address is a pair
     */
    function setPair(address account_, bool isPair_) external onlyOwner {
        require(account_ != address(0), "Invalid address");
        isPair[account_] = isPair_;
        emit PairUpdated(account_, isPair_);
    }

    /**
     * @notice Burns tokens from an address
     * @param account_ Address to burn from
     * @param amount_ Amount to burn
     */
    function burnFrom(address account_, uint256 amount_) external onlyOwner {
        require(account_ != address(0), "Invalid address");
        balances[account_] = balances[account_] - amount_;
        totalTokenSupply = totalTokenSupply - amount_;
        emit Transfer(account_, address(0), amount_);
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
        if (!hasGraduated || taxExempt[from_] || taxExempt[to_]) {
            return 0;
        }

        uint256 taxRate;
        if (isPair[from_]) {
            // Buy tax from Factory
            taxRate = factory.buyTax();
        } else if (isPair[to_]) {
            // Sell tax from Factory
            taxRate = factory.sellTax();
        } else {
            // No tax on wallet transfers
            return 0;
        }

        return (amount_ * taxRate) / 10000; // Base 10000 for basis points
    }

    /**
     * @notice Internal function to approve token spending
     * @param owner_ Address approving the spend
     * @param spender_ Address being approved
     * @param amount_ Amount being approved
     */
    function _approve(
        address owner_,
        address spender_,
        uint256 amount_
    ) private {
        require(owner_ != address(0), "Invalid owner");
        require(spender_ != address(0), "Invalid spender");

        allowances[owner_][spender_] = amount_;
        emit Approval(owner_, spender_, amount_);
    }

    /**
     * @notice Internal function to transfer tokens
     * @param from_ Address sending tokens
     * @param to_ Address receiving tokens
     * @param amount_ Amount of tokens to transfer
     */
    function _update(
        address from_,
        address to_,
        uint256 amount_
    ) private {
        require(from_ != address(0), "Invalid sender");
        require(to_ != address(0), "Invalid recipient");
        require(amount_ > 0, "Invalid amount");

        if (!transactionLimitExempt[from_]) {
            require(amount_ <= maxTransactionAmount, "Exceeds limit");
        }

        uint256 taxAmount = _calculateTax(from_, to_, amount_);
        uint256 finalAmount = amount_ - taxAmount;

        if (taxAmount > 0) {
            address taxVault_ = factory.taxVault();
            uint256 halfTax = taxAmount / 2;
            
            // Split tax between vault and token owner
            balances[taxVault_] = balances[taxVault_] + halfTax;
            emit Transfer(from_, taxVault_, halfTax);

            balances[owner()] = balances[owner()] + (taxAmount - halfTax);
            emit Transfer(from_, owner(), taxAmount - halfTax);
        }

        balances[from_] = balances[from_] - amount_;
        balances[to_] = balances[to_] + finalAmount;

        emit Transfer(from_, to_, finalAmount);
    }

    /**
     * @notice Internal function to update max transaction limit
     * @param newMaxPercent_ New maximum as percentage of total supply
     */
    function _updateMaxTransaction(uint256 newMaxPercent_) internal {
        maxTransactionPercent = newMaxPercent_;
        maxTransactionAmount = (newMaxPercent_ * totalTokenSupply) / 100;
        emit MaxTransactionUpdated(newMaxPercent_);
    }
}