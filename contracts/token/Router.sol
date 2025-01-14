// SPDX-License-Identifier: MIT
// Created by chirper.build
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
 * @dev Manages token swaps and liquidity operations for the chirper.build platform
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the router contract
     * @param factoryAddress Address of the factory contract
     * @param assetTokenAddress Address of the asset token
     */
    function initialize(
        address factoryAddress,
        address assetTokenAddress
    ) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        require(factoryAddress != address(0), "Invalid factory");
        require(assetTokenAddress != address(0), "Invalid asset");

        factory = Factory(factoryAddress);
        assetToken = assetTokenAddress;
    }

    /**
     * @notice Calculates the output amount for a swap
     * @param tokenAddress Address of the token to swap
     * @param assetTokenAddress Address of the asset token
     * @param amountIn Amount of input tokens
     * @return Amount of output tokens
     */
    function getAmountsOut(
        address tokenAddress,
        address assetTokenAddress,
        uint256 amountIn
    ) public view returns (uint256) {
        require(tokenAddress != address(0), "Invalid token");

        address pairAddress = factory.getPair(tokenAddress, assetToken);
        IPair pair = IPair(pairAddress);
        
        (uint256 reserveA, uint256 reserveB) = pair.getReserves();
        uint256 k = pair.kLast();

        if (assetTokenAddress == assetToken) {
            uint256 newReserveB = reserveB + amountIn;
            uint256 newReserveA = k / newReserveB;
            return reserveA - newReserveA;
        } else {
            uint256 newReserveA = reserveA + amountIn;
            uint256 newReserveB = k / newReserveA;
            return reserveB - newReserveB;
        }
    }

    /**
     * @notice Adds initial liquidity to a pair
     * @param tokenAddress Token address
     * @param tokenAmount Amount of tokens
     * @param assetAmount Amount of asset tokens
     * @return Amount of tokens and asset tokens added
     */
    function addInitialLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 assetAmount
    ) external onlyRole(EXECUTOR_ROLE) returns (uint256, uint256) {
        require(tokenAddress != address(0), "Invalid token");

        address pairAddress = factory.getPair(tokenAddress, assetToken);
        IPair pair = IPair(pairAddress);

        IERC20(tokenAddress).safeTransferFrom(msg.sender, pairAddress, tokenAmount);
        pair.mint(tokenAmount, assetAmount);

        return (tokenAmount, assetAmount);
    }

    /**
     * @notice Executes a sell operation
     * @param amountIn Amount of tokens to sell
     * @param tokenAddress Address of token to sell
     * @param to Address to receive output
     * @return Input and output amounts
     */
    function sell(
        uint256 amountIn,
        address tokenAddress,
        address to
    ) external nonReentrant onlyRole(EXECUTOR_ROLE) returns (uint256, uint256) {
        require(tokenAddress != address(0), "Invalid token");
        require(to != address(0), "Invalid recipient");

        address pairAddress = factory.getPair(tokenAddress, assetToken);
        IPair pair = IPair(pairAddress);
        
        uint256 amountOut = getAmountsOut(tokenAddress, address(0), amountIn);
        IERC20(tokenAddress).safeTransferFrom(to, pairAddress, amountIn);

        // Calculate and distribute fees
        uint256 fee = factory.sellTax();
        uint256 totalFee = (fee * amountOut) / 100;
        uint256 halfFee = totalFee / 2;
        
        address taxVault = factory.taxVault();
        address tokenOwner = Token(tokenAddress).owner();
        
        uint256 finalAmount = amountOut - totalFee;

        // Transfer tokens
        pair.transferAsset(to, finalAmount);
        pair.transferAsset(taxVault, halfFee);
        pair.transferAsset(tokenOwner, halfFee);
        
        pair.swap(amountIn, 0, 0, amountOut);

        return (amountIn, amountOut);
    }

    /**
     * @notice Executes a buy operation
     * @param amountIn Amount of asset tokens to spend
     * @param tokenAddress Address of token to buy
     * @param to Address to receive output
     * @return Input and output amounts
     */
    function buy(
        uint256 amountIn,
        address tokenAddress,
        address to
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant returns (uint256, uint256) {
        require(tokenAddress != address(0), "Invalid token");
        require(to != address(0), "Invalid recipient");
        require(amountIn > 0, "Invalid amount");

        address pairAddress = factory.getPair(tokenAddress, assetToken);
        
        // Calculate and distribute fees
        uint256 fee = factory.buyTax();
        uint256 totalFee = (fee * amountIn) / 100;
        uint256 halfFee = totalFee / 2;
        
        address taxVault = factory.taxVault();
        address tokenOwner = Token(tokenAddress).owner();
        
        uint256 finalAmount = amountIn - totalFee;

        // Transfer asset tokens
        IERC20(assetToken).safeTransferFrom(to, pairAddress, finalAmount);
        IERC20(assetToken).safeTransferFrom(to, taxVault, halfFee);
        IERC20(assetToken).safeTransferFrom(to, tokenOwner, halfFee);

        // Calculate and transfer output tokens
        uint256 amountOut = getAmountsOut(tokenAddress, assetToken, finalAmount);
        IPair(pairAddress).transferTo(to, amountOut);
        IPair(pairAddress).swap(0, amountOut, finalAmount, 0);

        return (finalAmount, amountOut);
    }

    /**
     * @notice Graduates a token pair
     * @param tokenAddress Address of token to graduate
     */
    function graduate(
        address tokenAddress
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(tokenAddress != address(0), "Invalid token");
        
        address pairAddress = factory.getPair(tokenAddress, assetToken);
        uint256 assetBalance = IPair(pairAddress).assetBalance();
        IPair(pairAddress).transferAsset(msg.sender, assetBalance);
    }

    /**
     * @notice Approves token spending for a pair
     * @param pairAddress Address of the pair
     * @param assetAddress Address of the asset
     * @param spender Address of the spender
     * @param amount Amount to approve
     */
    function approval(
        address pairAddress,
        address assetAddress,
        address spender,
        uint256 amount
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant {
        require(spender != address(0), "Invalid spender");
        IPair(pairAddress).approval(spender, assetAddress, amount);
    }
}