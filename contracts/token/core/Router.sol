// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./Factory.sol";
import "./Token.sol";

// bonding pair
import "../interfaces/IBondingPair.sol";

/**
 * @title Router
 * @dev Manages token swaps and liquidity operations for the platform
 * This contract handles all trading operations including swaps and liquidity provision,
 * with tax management handled by the Factory contract.
 */
contract Router is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Role identifier for execution operations
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Factory contract reference for pair and tax management
    Factory public factory;
    
    /// @notice Asset token used for all trading pairs
    address public assetToken;
    
    /// @notice Maximum transaction amount for a single swap
    uint256 public maxTxPercent;

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
     * @notice Initializes the router contract with required dependencies
     * @param factory_ Address of the factory contract
     * @param assetToken_ Address of the asset token
     * @param maxTxPercent_ Maximum transaction amount for a single swap
     */
    function initialize(
        address factory_,
        address assetToken_,
        uint256 maxTxPercent_
    ) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        require(factory_ != address(0), "Invalid factory");

        factory = Factory(factory_);
        assetToken = assetToken_;
        maxTxPercent = maxTxPercent_;
    }

    /*//////////////////////////////////////////////////////////////
                         CORE TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes a buy operation with fee distribution
     * @param amountIn_ Amount of asset tokens to spend
     * @param tokenAddress_ Address of token to buy
     * @param to_ Address receiving the output tokens
     * @return Tuple of (input amount, output amount)
     */
    function buy(
        uint256 amountIn_,
        address tokenAddress_,
        address to_
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant returns (uint256, uint256) {
        require(tokenAddress_ != address(0), "Invalid token");
        require(to_ != address(0), "Invalid recipient");
        require(amountIn_ > 0, "Invalid amount");
        
        // check max transaction percent by total supply
        uint256 maxTxAmount = (IERC20(tokenAddress_).totalSupply() * maxTxPercent) / 10000;

        // check max transaction amount
        require(amountIn_ <= maxTxAmount, "Exceeds max transaction");
        
        // Check token hasn't graduated
        Token token = Token(tokenAddress_);
        require(!token.hasGraduated(), "Token graduated");

        address pair = factory.getPair(tokenAddress_, assetToken);

        // Calculate split fees using Factory's tax settings
        uint256 feePercent = factory.buyTax();
        uint256 totalFee = (feePercent * amountIn_) / 10000;
        uint256 halfFee = totalFee / 2;
        uint256 finalAmount = amountIn_ - totalFee;
        
        address taxVault = factory.taxVault();
        address tokenOwner = token.owner();

        // Transfer tokens with split fees
        IERC20(assetToken).safeTransferFrom(to_, pair, finalAmount);
        IERC20(assetToken).safeTransferFrom(to_, taxVault, halfFee);
        IERC20(assetToken).safeTransferFrom(to_, tokenOwner, halfFee);

        uint256 amountOut = _getAmountsOut(tokenAddress_, assetToken, finalAmount);

        IBondingPair(pair).transferTo(to_, amountOut);
        IBondingPair(pair).swap(0, amountOut, finalAmount, 0);

        return (finalAmount, amountOut);
    }

    /**
     * @notice Executes a sell operation with fee distribution
     * @param amountIn_ Amount of tokens to sell
     * @param tokenAddress_ Address of token being sold
     * @param to_ Address receiving the output assets
     * @return Tuple of (input amount, output amount)
     */
    function sell(
        uint256 amountIn_,
        address tokenAddress_,
        address to_
    ) external nonReentrant onlyRole(EXECUTOR_ROLE) returns (uint256, uint256) {
        require(tokenAddress_ != address(0), "Invalid token");
        require(to_ != address(0), "Invalid recipient");
        
        // check max transaction percent by total supply
        uint256 maxTxAmount = (IERC20(tokenAddress_).totalSupply() * maxTxPercent) / 10000;

        // check max transaction amount
        require(amountIn_ <= maxTxAmount, "Exceeds max transaction");
        
        // Check token hasn't graduated
        Token token = Token(tokenAddress_);
        require(!token.hasGraduated(), "Token graduated");

        address pairAddress = factory.getPair(tokenAddress_, assetToken);
        IBondingPair pair = IBondingPair(pairAddress);
        
        uint256 amountOut = _getAmountsOut(tokenAddress_, address(0), amountIn_);
        IERC20(tokenAddress_).safeTransferFrom(to_, pairAddress, amountIn_);

        // Calculate split fees using Factory's tax settings
        uint256 fee = factory.sellTax();
        uint256 totalFee = (fee * amountOut) / 10000;
        uint256 halfFee = totalFee / 2;
        uint256 finalAmount = amountOut - totalFee;
        
        address taxVault = factory.taxVault();
        address tokenOwner = token.owner();

        // Distribute fees and transfer tokens
        pair.transferAsset(to_, finalAmount);
        pair.transferAsset(taxVault, halfFee);
        pair.transferAsset(tokenOwner, halfFee);
        
        pair.swap(amountIn_, 0, 0, amountOut);

        return (amountIn_, amountOut);
    }

    /**
     * @notice Adds initial liquidity to a trading pair
     * @param tokenAddress_ Token address to add liquidity for
     * @param amountToken_ Amount of tokens to add
     * @param amountAsset_ Amount of asset tokens to add
     * @return Tuple of (token amount, asset amount) added
     */
    function addInitialLiquidity(
        address tokenAddress_,
        uint256 amountToken_,
        uint256 amountAsset_
    ) external onlyRole(EXECUTOR_ROLE) returns (uint256, uint256) {
        require(tokenAddress_ != address(0), "Invalid token");

        address pairAddress = factory.getPair(tokenAddress_, assetToken);
        IBondingPair pair = IBondingPair(pairAddress);

        IERC20(tokenAddress_).safeTransferFrom(msg.sender, pairAddress, amountToken_);
        pair.mint(amountToken_, amountAsset_);

        return (amountToken_, amountAsset_);
    }

    /**
     * @notice Graduates a token pair to external AMM
     * @param tokenAddress_ Address of token to graduate
     */
    function graduate(
        address tokenAddress_
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(tokenAddress_ != address(0), "Invalid token");
        
        Token token = Token(tokenAddress_);
        require(!token.hasGraduated(), "Token graduated");
        
        address pair = factory.getPair(tokenAddress_, assetToken);
        
        uint256 assetBalance = IBondingPair(pair).assetBalance();
        uint256 agentBalance = IBondingPair(pair).balance();
        
        IBondingPair(pair).transferAsset(msg.sender, assetBalance);
        IBondingPair(pair).transferTo(msg.sender, agentBalance);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the maximum transaction amount for a single swap
     * @param maxTxPercent_ Maximum transaction amount for a single swap
     */
    function setMaxTxPercent(uint256 maxTxPercent_) external onlyRole(ADMIN_ROLE) {
        // Ensure max transaction is within acceptable bounds
        require(maxTxPercent_ > 0, "Invalid amount");
        require(maxTxPercent_ <= 10000, "Exceeds 100%");

        maxTxPercent = maxTxPercent_;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates output amount for a swap operation
     * @param token_ Token address being traded
     * @param assetToken_ Asset token address for direction
     * @param amountIn_ Amount of input tokens
     * @return Amount of output tokens
     */
    function getAmountsOut(
        address token_,
        address assetToken_,
        uint256 amountIn_
    ) external view returns (uint256) {
        return _getAmountsOut(token_, assetToken_, amountIn_);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to calculate swap amounts
     * @param token_ Token address being traded
     * @param assetToken_ Asset token address for direction
     * @param amountIn_ Amount of input tokens
     * @return Amount of output tokens
     */
    function _getAmountsOut(
        address token_,
        address assetToken_,
        uint256 amountIn_
    ) internal view returns (uint256) {
        require(token_ != address(0), "Invalid token");

        address pairAddress = factory.getPair(token_, assetToken);
        IBondingPair pair = IBondingPair(pairAddress);
        
        (uint256 reserveA, uint256 reserveB) = pair.getReserves();
        uint256 k = pair.kLast();
        
        if (assetToken_ == assetToken) {
            uint256 newReserveB = reserveB + amountIn_;
            uint256 newReserveA = k / newReserveB;
            return reserveA - newReserveA;
        } else {
            uint256 newReserveA = reserveA + amountIn_;
            uint256 newReserveB = k / newReserveA;
            return reserveB - newReserveB;
        }
    }

    /**
     * @notice Approves token spending for a pair
     * @param pair_ Address of the pair
     * @param asset_ Address of the asset
     * @param spender_ Address allowed to spend
     * @param amount_ Amount to approve
     */
    function approve(
        address pair_,
        address asset_,
        address spender_,
        uint256 amount_
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(spender_ != address(0), "Invalid spender");
        IBondingPair(pair_).approval(spender_, asset_, amount_);
    }
}