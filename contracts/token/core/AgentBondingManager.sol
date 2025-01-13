// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "./AgentToken.sol";

/**
 * @title AgentBondingManager
 * @notice Manages bonding curves for AI agent tokens with Uniswap graduation capability
 * @dev This contract implements a bonding curve mechanism for initial token trading and
 * handles graduation to Uniswap when certain conditions are met.
 *
 * The contract follows these key principles:
 * 1. Initial trading occurs through a bonding curve mechanism
 * 2. Once a token reaches graduation threshold, it transitions to Uniswap
 * 3. Uses role-based access control for administrative functions
 * 4. Implements safety features like reentrancy guards and circuit breakers
 *
 * Key Features:
 * - Bonding curve-based price discovery
 * - Automatic Uniswap graduation
 * - Creator fee distribution
 * - Emergency pause capability
 * - Comprehensive event logging
 */
contract AgentBondingManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    /// @notice Role identifier for contract upgrader
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Role identifier for platform operations
    bytes32 public constant PLATFORM_ROLE = keccak256("PLATFORM_ROLE");

    /// @notice Basis points denominator (100%)
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Minimum valid transaction amount
    uint256 public constant MIN_OPERATION_AMOUNT = 1e14; // 0.0001 ETH

    /// @notice Platform's share of fees (60%)
    uint256 public constant PLATFORM_FEE_SHARE = 60;

    /// @notice Creator's share of fees (40%)
    uint256 public constant CREATOR_FEE_SHARE = 40;

    /// @notice Initial token supply
    uint256 public constant INITIAL_TOKEN_SUPPLY = 1000000 * 1e18; // 1M tokens

    // =============================================================
    //                        STATE VARIABLES
    // =============================================================

    /// @notice Factory contract that deployed this manager
    address public factory;

    /// @notice Base trading asset (e.g. WETH)
    IERC20 public baseAsset;

    /// @notice Address collecting protocol fees
    address public taxVault;

    /// @notice Purchase tax rate (basis points)
    uint256 public buyTax;

    /// @notice Sale tax rate (basis points)
    uint256 public sellTax;

    /// @notice Configurable rate affecting curve steepness
    uint256 public assetRate;

    /// @notice Required initial purchase amount
    uint256 public initialBuyAmount;

    /// @notice Minimum market cap for graduation
    uint256 public graduationThreshold;

    /// @notice Uniswap V2 factory contract
    IUniswapV2Factory public uniswapFactory;

    /// @notice Uniswap V2 router contract
    IUniswapV2Router02 public uniswapRouter;

    /// @notice Maps token address to its curve data
    mapping(address => CurveData) public curves;

    /// @notice List of all launched tokens
    address[] public tokens;

    /// @notice Tracks registered token status
    mapping(address => bool) public isTokenRegistered;

    // =============================================================
    //                          STRUCTS
    // =============================================================

    /**
     * @notice Comprehensive token and bonding curve data
     * @param token Token contract address
     * @param creator Token creator address for fee distribution
     * @param tokenReserve Current token reserve in curve
     * @param assetReserve Current baseAsset reserve in curve
     * @param graduated Whether token has moved to Uniswap
     * @param uniswapPair Active Uniswap pair address
     * @param currentPrice Latest price in baseAsset (18 decimals)
     * @param marketCap Total market cap in baseAsset
     * @param lastPrice Previous price for 24h comparison
     * @param lastUpdateTime Timestamp of last price update
     */
    struct CurveData {
        address token;
        address creator;
        uint256 tokenReserve;
        uint256 assetReserve;
        bool graduated;
        address uniswapPair;
        uint256 currentPrice;
        uint256 marketCap;
        uint256 lastPrice;
        uint256 lastUpdateTime;
    }

    // =============================================================
    //                           EVENTS
    // =============================================================

    /**
     * @notice Emitted when new token is launched
     * @param token New token address
     * @param creator Token creator
     * @param name Token name
     * @param symbol Token symbol 
     * @param initialTokenReserve Starting token reserve
     * @param initialAssetReserve Starting asset reserve
     */
    event TokenLaunched(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        uint256 initialTokenReserve,
        uint256 initialAssetReserve
    );

    /**
     * @notice Emitted for each trade
     * @param token Token being traded
     * @param trader Trading address
     * @param isBuy True for buy, false for sell
     * @param tokenAmount Token quantity
     * @param assetAmount BaseAsset quantity
     * @param platformTax Protocol fee amount
     * @param creatorTax Creator fee amount
     */
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 tokenAmount,
        uint256 assetAmount,
        uint256 platformTax,
        uint256 creatorTax
    );

    /**
     * @notice Emitted on Uniswap graduation
     * @param token Graduated token
     * @param pair Uniswap pair address
     * @param tokenLiquidity Amount of tokens added as liquidity
     * @param assetLiquidity Amount of base asset added as liquidity
     */
    event TokenGraduated(
        address indexed token,
        address indexed pair,
        uint256 tokenLiquidity,
        uint256 assetLiquidity
    );

    /**
     * @notice Emitted when tax settings change
     * @param taxVault New fee collection address
     * @param buyTax New buy tax rate
     * @param sellTax New sell tax rate
     */
    event TaxConfigUpdated(
        address indexed taxVault,
        uint256 buyTax,
        uint256 sellTax
    );

    /**
     * @notice Records asset rate changes
     * @param oldRate Previous rate
     * @param newRate Updated rate
     */
    event AssetRateUpdated(uint256 oldRate, uint256 newRate);

    /**
     * @notice Emitted on price updates
     * @param token Token address
     * @param oldPrice Previous price
     * @param newPrice New price
     * @param marketCap New market cap
     * @param timestamp Update time
     */
    event PriceUpdated(
        address indexed token,
        uint256 oldPrice,
        uint256 newPrice,
        uint256 marketCap,
        uint256 timestamp
    );

    // =============================================================
    //                  CONSTRUCTOR & INITIALIZER
    // =============================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes contract with required settings
     * @param _baseAsset Base trading asset address (18 decimals)
     * @param _taxVault Tax collection address
     * @param _platform Platform admin address
     * @param _uniswapFactory Uniswap factory address
     * @param _uniswapRouter Uniswap router address
     * @param _graduationThreshold Minimum market cap for graduation
     * @param _assetRate Initial curve rate
     * @param _initialBuyAmount Required initial buy amount
     */
    function initialize(
        address _baseAsset,
        address _taxVault,
        address _platform,
        address _uniswapFactory,
        address _uniswapRouter,
        uint256 _graduationThreshold,
        uint256 _assetRate,
        uint256 _initialBuyAmount
    ) external initializer {
        require(_baseAsset != address(0), "Invalid base asset");
        require(_taxVault != address(0), "Invalid tax vault");
        require(_platform != address(0), "Invalid platform");
        require(_uniswapFactory != address(0), "Invalid factory");
        require(_uniswapRouter != address(0), "Invalid router");
        require(_graduationThreshold > 0, "Invalid threshold");
        require(_assetRate > 0, "Invalid asset rate");
        require(_initialBuyAmount >= MIN_OPERATION_AMOUNT, "Buy amount too small");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        factory = msg.sender;
        baseAsset = IERC20(_baseAsset);
        taxVault = _taxVault;
        uniswapFactory = IUniswapV2Factory(_uniswapFactory);
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        graduationThreshold = _graduationThreshold;
        assetRate = _assetRate;
        initialBuyAmount = _initialBuyAmount;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(PLATFORM_ROLE, _platform);

        // Default tax rates
        buyTax = 100;  // 1%
        sellTax = 100; // 1%
    }

    // =============================================================
    //                    CORE TRADING FUNCTIONS
    // =============================================================

    /**
     * @notice Buys tokens using the bonding curve
     * @param token Token to buy
     * @param assetAmount Amount of base asset to spend
     * @return tokenAmount Amount of tokens received
     */
    function buy(
        address token,
        uint256 assetAmount
    ) external nonReentrant whenNotPaused returns (uint256 tokenAmount) {
        require(assetAmount >= MIN_OPERATION_AMOUNT, "Amount too small");
        require(isTokenRegistered[token], "Token not found");

        CurveData storage curve = curves[token];
        require(!curve.graduated, "Token graduated");

        // Calculate taxes
        (uint256 platformTax, uint256 creatorTax) = getTaxSplit(true, assetAmount);
        uint256 netAmount = assetAmount - platformTax - creatorTax;
        require(netAmount > 0, "Amount too small after tax");

        // Transfer assets in
        baseAsset.safeTransferFrom(msg.sender, address(this), assetAmount);

        // Distribute taxes
        if (platformTax > 0) {
            baseAsset.safeTransfer(taxVault, platformTax);
        }
        if (creatorTax > 0) {
            baseAsset.safeTransfer(curve.creator, creatorTax);
        }

        // Calculate buy impact
        (uint256 newAssetReserve, uint256 newTokenReserve, uint256 tokensOut) = 
            _calculateBuyImpact(curve, netAmount);

        require(tokensOut > 0, "No tokens to transfer");
        require(tokensOut <= curve.tokenReserve, "Insufficient token reserve");

        // Update reserves
        curve.assetReserve = newAssetReserve;
        curve.tokenReserve = newTokenReserve;

        // Update price data
        _updatePriceData(curve);

        // Check for graduation
        if (!curve.graduated && curve.marketCap >= graduationThreshold) {
            _graduate(token);
        }

        // Transfer tokens to buyer
        IERC20(token).safeTransfer(msg.sender, tokensOut);

        emit Trade(
            token,
            msg.sender,
            true,
            tokensOut,
            assetAmount,
            platformTax,
            creatorTax
        );

        return tokensOut;
    }

    /**
     * @notice Sells tokens back to the bonding curve
     * @param token Token to sell
     * @param tokenAmount Amount of tokens to sell
     * @return assetAmount Base asset amount received
     */
    function sell(
        address token,
        uint256 tokenAmount
    ) external nonReentrant whenNotPaused returns (uint256 assetAmount) {
        require(tokenAmount >= MIN_OPERATION_AMOUNT, "Amount too small");
        require(isTokenRegistered[token], "Token not found");

        CurveData storage curve = curves[token];
        require(!curve.graduated, "Token graduated");

        // Transfer tokens in
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Calculate sell impact
        (uint256 newAssetReserve, uint256 newTokenReserve, uint256 assetsOut) = 
            _calculateSellImpact(curve, tokenAmount);

        require(assetsOut > 0, "No assets to transfer");

        // Calculate taxes
        (uint256 platformTax, uint256 creatorTax) = getTaxSplit(false, assetsOut);
        uint256 netAmount = assetsOut - platformTax - creatorTax;
        require(netAmount > 0, "Amount too small after tax");

        // Update reserves
        curve.assetReserve = newAssetReserve;
        curve.tokenReserve = newTokenReserve;

        // Update price data
        _updatePriceData(curve);

        // Transfer assets and taxes
        if (platformTax > 0) {
            baseAsset.safeTransfer(taxVault, platformTax);
        }
        if (creatorTax > 0) {
            baseAsset.safeTransfer(curve.creator, creatorTax);
        }
        baseAsset.safeTransfer(msg.sender, netAmount);

        emit Trade(
            token,
            msg.sender,
            false,
            tokenAmount,
            assetsOut,
            platformTax,
            creatorTax
        );

        return netAmount;
    }

    // =============================================================
    //                 PRICE CALCULATION FUNCTIONS
    // =============================================================

    /**
     * @notice Calculates buy price impact and reserves
     * @param curve Token curve data
     * @param assetIn Amount of baseAsset in
     * @return newAssetReserve Updated asset reserve
     * @return newTokenReserve Updated token reserve
     * @return tokenOut Amount of tokens out
     */
    function _calculateBuyImpact(
        CurveData storage curve,
        uint256 assetIn
    ) private view returns (
        uint256 newAssetReserve,
        uint256 newTokenReserve,
        uint256 tokenOut
    ) {
        // Calculate constant product K
        uint256 k = curve.tokenReserve * curve.assetReserve;
        
        // Apply asset rate for curve steepness
        uint256 adjustedK = (k * assetRate) / 1e18;
        
        // Calculate new reserves
        newAssetReserve = curve.assetReserve + assetIn;
        newTokenReserve = adjustedK / newAssetReserve;
        
        require(newTokenReserve < curve.tokenReserve, "Invalid token calculation");
        tokenOut = curve.tokenReserve - newTokenReserve;
        
        return (newAssetReserve, newTokenReserve, tokenOut);
    }

    /**
     * @notice Calculates sell price impact and reserves
     * @param curve Token curve data
     * @param tokenIn Amount of tokens in
     * @return newAssetReserve Updated asset reserve
     * @return newTokenReserve Updated token reserve
     * @return assetOut Amount of baseAsset out
     */
    function _calculateSellImpact(
        CurveData storage curve,
        uint256 tokenIn
    ) private view returns (
        uint256 newAssetReserve,
        uint256 newTokenReserve,
        uint256 assetOut
    ) {
        // Calculate constant product K
        uint256 k = curve.tokenReserve * curve.assetReserve;
        
        // Apply asset rate for curve steepness
        uint256 adjustedK = (k * assetRate) / 1e18;
        
        // Calculate new reserves
        newTokenReserve = curve.tokenReserve + tokenIn;
        newAssetReserve = adjustedK / newTokenReserve;
        
        require(newAssetReserve < curve.assetReserve, "Invalid asset calculation");
        assetOut = curve.assetReserve - newAssetReserve;
        
        return (newAssetReserve, newTokenReserve, assetOut);
    }

    // =============================================================
    //                   GRADUATION FUNCTIONS
    // =============================================================

    /**
     * @notice Handles token graduation to Uniswap
     * @param token Token to graduate
     */
    function _graduate(address token) internal {
        CurveData storage curve = curves[token];
        require(!curve.graduated, "Already graduated");
        
        // Get available liquidity
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        uint256 assetBalance = baseAsset.balanceOf(address(this));
        require(tokenBalance > 0 && assetBalance > 0, "Insufficient liquidity");

        // Create Uniswap pair
        address pair = uniswapFactory.createPair(token, address(baseAsset));
        require(pair != address(0), "Pair creation failed");

        // Approve router
        IERC20(token).approve(address(uniswapRouter), tokenBalance);
        baseAsset.approve(address(uniswapRouter), assetBalance);

        // Add liquidity
        (uint256 tokenLiquidity, uint256 assetLiquidity, ) = uniswapRouter.addLiquidity(
            token,
            address(baseAsset),
            tokenBalance,
            assetBalance,
            tokenBalance * 95 / 100, // 5% slippage tolerance
            assetBalance * 95 / 100,
            address(this),
            block.timestamp + 15 minutes
        );

        // Update state
        curve.graduated = true;
        curve.uniswapPair = pair;

        // Enable trading on token
        AgentToken(token).graduate();

        emit TokenGraduated(token, pair, tokenLiquidity, assetLiquidity);
    }

    // =============================================================
    //                      TOKEN MANAGEMENT
    // =============================================================

    /**
     * @notice Launches new token with bonding curve
     * @dev Only callable by factory
     * @param token Token address to launch
     */
    function launchToken(address token) external {
        require(msg.sender == factory, "Only factory");
        require(!isTokenRegistered[token], "Already registered");
        require(token != address(0), "Zero address");

        isTokenRegistered[token] = true;

        // Setup initial reserves
        uint256 initialTokenReserve = INITIAL_TOKEN_SUPPLY;
        uint256 initialAssetReserve = initialBuyAmount;

        // Initialize curve data
        CurveData storage curve = curves[token];
        curve.token = token;
        curve.creator = tx.origin;
        curve.tokenReserve = initialTokenReserve;
        curve.assetReserve = initialAssetReserve;

        // Calculate initial price and market cap
        curve.currentPrice = (curve.assetReserve * 1e18) / curve.tokenReserve;
        curve.marketCap = (curve.currentPrice * INITIAL_TOKEN_SUPPLY) / 1e18;
        curve.lastPrice = curve.currentPrice;
        curve.lastUpdateTime = block.timestamp;

        // Transfer initial assets from factory
        baseAsset.safeTransferFrom(factory, address(this), initialAssetReserve);

        // Mint initial token supply
        AgentToken(token).mint(address(this), initialTokenReserve);

        tokens.push(token);

        emit TokenLaunched(
            token,
            tx.origin,
            AgentToken(token).name(),
            AgentToken(token).symbol(),
            curve.tokenReserve,
            curve.assetReserve
        );

        emit PriceUpdated(
            token,
            0,
            curve.currentPrice,
            curve.marketCap,
            block.timestamp
        );
    }

    // =============================================================
    //                     HELPER FUNCTIONS
    // =============================================================

    /**
     * @notice Updates price data for a token
     * @param curve Token curve data to update
     */
    function _updatePriceData(CurveData storage curve) private {
        // Store old price for event
        uint256 oldPrice = curve.currentPrice;
        
        // Update price
        curve.currentPrice = (curve.assetReserve * 1e18) / curve.tokenReserve;
        
        // Update market cap
        curve.marketCap = (curve.currentPrice * INITIAL_TOKEN_SUPPLY) / 1e18;
        
        // Update 24h price data if needed
        uint256 timeDelta = block.timestamp - curve.lastUpdateTime;
        if (timeDelta > 24 hours) {
            curve.lastPrice = curve.currentPrice;
            curve.lastUpdateTime = block.timestamp;
        }
        
        emit PriceUpdated(
            curve.token,
            oldPrice,
            curve.currentPrice,
            curve.marketCap,
            block.timestamp
        );
    }

    /**
     * @notice Calculates tax split between platform and creator
     * @param isBuy True if buy tax, false if sell tax
     * @param amount Amount to calculate tax on
     * @return platformTax Platform portion of tax
     * @return creatorTax Creator portion of tax
     */
    function getTaxSplit(
        bool isBuy,
        uint256 amount
    ) public view returns (uint256 platformTax, uint256 creatorTax) {
        uint256 totalTax = (amount * (isBuy ? buyTax : sellTax)) / BASIS_POINTS;
        platformTax = (totalTax * PLATFORM_FEE_SHARE) / (PLATFORM_FEE_SHARE + CREATOR_FEE_SHARE);
        creatorTax = totalTax - platformTax;
    }

    // =============================================================
    //                       VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Gets all registered tokens
     * @return Array of token addresses
     */
    function getAllTokens() external view returns (address[] memory) {
        return tokens;
    }

    /**
     * @notice Gets detailed token info
     * @param token Token address to query
     * @return Curve data struct
     */
    function getTokenInfo(address token) external view returns (CurveData memory) {
        require(isTokenRegistered[token], "Token not found");
        return curves[token];
    }

    /**
     * @notice Gets token statistics
     * @return totalTokens Total number of tokens
     * @return graduatedTokens Number of graduated tokens
     */
    function getTokenStatistics() external view returns (
        uint256 totalTokens,
        uint256 graduatedTokens
    ) {
        totalTokens = tokens.length;
        for (uint i = 0; i < tokens.length; i++) {
            if (curves[tokens[i]].graduated) {
                graduatedTokens++;
            }
        }
    }

    // =============================================================
    //                     ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Updates tax configuration
     * @param newTaxVault New tax collection address
     * @param newBuyTax New buy tax rate
     * @param newSellTax New sell tax rate
     */
    function updateTaxConfig(
        address newTaxVault,
        uint256 newBuyTax,
        uint256 newSellTax
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTaxVault != address(0), "Invalid tax vault");
        require(newBuyTax <= 1000 && newSellTax <= 1000, "Tax too high"); // Max 10%

        taxVault = newTaxVault;
        buyTax = newBuyTax;
        sellTax = newSellTax;

        emit TaxConfigUpdated(newTaxVault, newBuyTax, newSellTax);
    }

    /**
     * @notice Updates asset rate
     * @param newRate New asset rate
     */
    function updateAssetRate(uint256 newRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRate > 0, "Invalid rate");
        
        uint256 oldRate = assetRate;
        assetRate = newRate;
        
        emit AssetRateUpdated(oldRate, newRate);
    }

    /**
     * @notice Pauses all trading
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Resumes trading
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}