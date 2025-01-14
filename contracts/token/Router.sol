// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./Factory.sol";
import "./IPair.sol";
import "./Token.sol";

/**
 * @title Router
 * @dev Manages token swaps and liquidity operations with enhanced fee distribution
 * This contract handles all swap operations, initial liquidity provision,
 * and fee calculations for the platform. It includes split fee distribution
 * between tax vault and token owners.
 */
contract Router is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Role identifier for admin operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Role identifier for execution operations
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice Factory contract for creating and managing pairs
    Factory public factory;
    
    /// @notice Asset token used for trading pairs
    address public assetToken;

    /**
     * @dev Prevents implementation contract initialization
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the router contract
     * @dev Sets up initial configuration and grants admin role
     * @param factory_ Address of the factory contract
     * @param assetToken_ Address of the asset token
     */
    function initialize(
        address factory_,
        address assetToken_
    ) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        require(factory_ != address(0), "Zero addresses not allowed");
        require(assetToken_ != address(0), "Zero addresses not allowed");

        factory = Factory(factory_);
        assetToken = assetToken_;
    }

    /**
     * @notice Calculates output amount for a swap operation
     * @dev Uses constant product formula and handles both buy and sell directions
     * @param token Token address being traded
     * @param assetToken_ Asset token address (for direction)
     * @param amountIn Amount of input tokens
     * @return _amountOut Amount of output tokens
     */
    function getAmountsOut(
        address token,
        address assetToken_,
        uint256 amountIn
    ) public view returns (uint256 _amountOut) {
        require(token != address(0), "Zero addresses not allowed");

        address pairAddress = factory.getPair(token, assetToken);
        IPair pair = IPair(pairAddress);
        
        (uint256 reserveA, uint256 reserveB) = pair.getReserves();
        uint256 k = pair.kLast();
        
        uint256 amountOut;

        if (assetToken_ == assetToken) {
            uint256 newReserveB = reserveB + amountIn;
            uint256 newReserveA = k / newReserveB;
            amountOut = reserveA - newReserveA;
        } else {
            uint256 newReserveA = reserveA + amountIn;
            uint256 newReserveB = k / newReserveA;
            amountOut = reserveB - newReserveB;
        }

        return amountOut;
    }

    /**
     * @notice Adds initial liquidity to a trading pair
     * @dev Only callable by executors, sets up initial trading state
     * @param tokenAddress Token address
     * @param amountToken_ Amount of tokens to add
     * @param amountAsset_ Amount of asset tokens to add
     * @return Tuple of token and asset amounts added
     */
    function addInitialLiquidity(
        address tokenAddress,
        uint256 amountToken_,
        uint256 amountAsset_
    ) external onlyRole(EXECUTOR_ROLE) returns (uint256, uint256) {
        require(tokenAddress != address(0), "Zero addresses not allowed");

        address pairAddress = factory.getPair(tokenAddress, assetToken);
        IPair pair = IPair(pairAddress);

        IERC20(tokenAddress).safeTransferFrom(msg.sender, pairAddress, amountToken_);
        pair.mint(amountToken_, amountAsset_);

        return (amountToken_, amountAsset_);
    }

    /**
     * @notice Executes a sell operation with split fee distribution
     * @dev Handles token transfers and fee calculations
     * @param amountIn Amount of tokens to sell
     * @param tokenAddress Address of token being sold
     * @param to Address receiving the output
     * @return Tuple of input and output amounts
     */
    function sell(
        uint256 amountIn,
        address tokenAddress,
        address to
    ) external nonReentrant onlyRole(EXECUTOR_ROLE) returns (uint256, uint256) {
        require(tokenAddress != address(0), "Zero addresses not allowed");
        require(to != address(0), "Zero addresses not allowed");
        
        // Check token hasn't graduated
        Token token = Token(tokenAddress);
        require(!token.hasGraduated(), "Token graduated");

        address pairAddress = factory.getPair(tokenAddress, assetToken);
        IPair pair = IPair(pairAddress);
        
        uint256 amountOut = getAmountsOut(tokenAddress, address(0), amountIn);
        IERC20(tokenAddress).safeTransferFrom(to, pairAddress, amountIn);

        // Calculate split fees
        uint256 fee = factory.sellTax() / 100;
        uint256 totalFee = (fee * amountOut) / 100;
        uint256 halfFee = totalFee / 2;
        uint256 finalAmount = amountOut - totalFee;
        
        address taxVault = factory.taxVault();
        address tokenOwner = Token(tokenAddress).owner();

        // Distribute fees and transfer tokens
        pair.transferAsset(to, finalAmount);
        pair.transferAsset(taxVault, halfFee);
        pair.transferAsset(tokenOwner, halfFee);
        
        pair.swap(amountIn, 0, 0, amountOut);

        return (amountIn, amountOut);
    }

    /**
     * @notice Executes a buy operation with split fee distribution
     * @dev Handles token transfers and fee calculations
     * @param amountIn Amount of asset tokens to spend
     * @param tokenAddress Address of token to buy
     * @param to Address receiving the output
     * @return Tuple of input and output amounts
     */
    function buy(
        uint256 amountIn,
        address tokenAddress,
        address to
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant returns (uint256, uint256) {
        require(tokenAddress != address(0), "Zero addresses not allowed");
        require(to != address(0), "Zero addresses not allowed");
        require(amountIn > 0, "Amount must be positive");
        
        // Check token hasn't graduated
        Token token = Token(tokenAddress);
        require(!token.hasGraduated(), "Token graduated");

        address pair = factory.getPair(tokenAddress, assetToken);

        // Calculate split fees
        uint256 feePercent = factory.buyTax() / 100;
        uint256 totalFee = (feePercent * amountIn) / 100;
        uint256 halfFee = totalFee / 2;
        uint256 finalAmount = amountIn - totalFee;
        
        address taxVault = factory.taxVault();
        address tokenOwner = Token(tokenAddress).owner();

        // Transfer tokens with split fees
        IERC20(assetToken).safeTransferFrom(to, pair, finalAmount);
        IERC20(assetToken).safeTransferFrom(to, taxVault, halfFee);
        IERC20(assetToken).safeTransferFrom(to, tokenOwner, halfFee);

        uint256 amountOut = getAmountsOut(tokenAddress, assetToken, finalAmount);

        IPair(pair).transferTo(to, amountOut);
        IPair(pair).swap(0, amountOut, finalAmount, 0);

        return (finalAmount, amountOut);
    }

    /**
     * @notice Graduates a token pair
     * @dev Transfers asset balance to caller, only executable by EXECUTOR_ROLE
     * @param tokenAddress Address of token to graduate
     */
    function graduate(
        address tokenAddress
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(tokenAddress != address(0), "Zero addresses not allowed");
        
        // Check token hasn't graduated
        Token token = Token(tokenAddress);
        require(!token.hasGraduated(), "Token graduated");
        
        address pair = factory.getPair(tokenAddress, assetToken);
        
        // Get both balances
        uint256 assetBalance = IPair(pair).assetBalance();
        uint256 agentBalance = IPair(pair).balance();
        
        // Transfer both tokens to caller
        IPair(pair).transferAsset(msg.sender, assetBalance);
        IPair(pair).transferTo(msg.sender, agentBalance);
    }

    /**
     * @notice Approves token spending for a pair
     * @dev Only callable by executors
     * @param pair Address of the pair
     * @param asset Address of the asset
     * @param spender Address allowed to spend
     * @param amount Amount to approve
     */
    function approval(
        address pair,
        address asset,
        address spender,
        uint256 amount
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(spender != address(0), "Zero addresses not allowed");
        IPair(pair).approval(spender, asset, amount);
    }
}