// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AgentToken.sol";
import "../interfaces/IDEXInterfaces.sol";
import "../libraries/Constants.sol";
import "../libraries/ErrorLibrary.sol";

/**
 * @title AgentBondingManager V2
 * @notice Enhanced bonding curve manager for AI agent tokens with improved price discovery
 * and synchronization mechanisms.
 * 
 * @dev Key Improvements:
 * - Robust reserve synchronization before operations
 * - Enhanced price calculation using actual balances
 * - Improved DEX graduation process
 * - Better handling of reserves and market cap updates
 * - Additional helper functions for accurate state management
 *
 * Core Features:
 * - Launches new AI agent tokens with initial liquidity
 * - Manages bonding curve trading with dynamic pricing
 * - Tracks comprehensive market data
 * - Handles DEX graduation process
 * - Implements role-based access control
 */
contract AgentBondingManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------
    // STRUCTS
    // ------------------------------------------------------------------------

    /**
     * @notice Settings for DEX graduation process
     * @param gradThreshold Minimum market cap needed for graduation (in baseAsset)
     * @param dexAdapters Array of DEX adapter contract addresses
     * @param dexWeights Percentage allocation for each DEX (must sum to 100)
     */
    struct CurveConfig {
        uint256 gradThreshold;     
        address[] dexAdapters;     
        uint256[] dexWeights;      
    }

    /**
     * @notice Comprehensive token and bonding curve data
     * @param token Token contract address
     * @param creator Token creator address for fee distribution
     * @param tokenReserve Current token reserve in curve
     * @param assetReserve Current baseAsset reserve in curve
     * @param graduated Whether token has moved to DEX
     * @param dexPairs Active DEX trading pair addresses
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
        address[] dexPairs;        
        uint256 currentPrice;      
        uint256 marketCap;         
        uint256 lastPrice;         
        uint256 lastUpdateTime;    
    }

    // ------------------------------------------------------------------------
    // STATE VARIABLES
    // ------------------------------------------------------------------------

    /// @notice Factory contract that deployed this manager
    address public factory;

    /// @notice Base trading asset (e.g. WETH, assumed 18 decimals)
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

    /// @notice Default settings for new curves
    CurveConfig public defaultConfig;

    /// @notice Maps token address to its curve data
    mapping(address => CurveData) public curves;

    /// @notice List of all launched tokens
    address[] public tokens;

    /// @notice Tracks registered token status
    mapping(address => bool) public isTokenRegistered;

    // ------------------------------------------------------------------------
    // EVENTS
    // ------------------------------------------------------------------------

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
     * @notice Emitted on DEX graduation
     * @param token Graduated token
     * @param dexPairs Created DEX pair addresses
     * @param amounts Liquidity amounts per DEX
     */
    event TokenGraduated(
        address indexed token,
        address[] dexPairs,
        uint256[] amounts
    );

    /**
     * @notice Emitted when liquidity is added to DEX
     * @param token Token address
     * @param pair DEX pair address
     * @param amountA Token amount
     * @param amountB BaseAsset amount
     * @param liquidity LP tokens minted
     */
    event LiquidityAdded(
        address indexed token,
        address indexed pair,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
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
     * @notice Records minimum buy requirement changes
     * @param newAmount Updated minimum amount
     */
    event InitialBuyAmountUpdated(uint256 newAmount);

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

    /**
     * @notice Emitted when token is registered
     * @param token Registered token address
     */
    event TokenRegistered(address indexed token);

    // ------------------------------------------------------------------------
    // CONSTRUCTOR & INITIALIZER
    // ------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes contract with required settings
     * @param _baseAsset Base trading asset address (18 decimals)
     * @param _registry Tax collection address
     * @param _platform Platform admin address
     * @param _config Default curve settings
     * @param _initialAssetRate Initial curve rate
     * @param _initialBuyAmount Required initial buy amount
     */
    function initialize(
        address _baseAsset,
        address _registry,
        address _platform,
        CurveConfig calldata _config,
        uint256 _initialAssetRate,
        uint256 _initialBuyAmount
    ) external initializer {
        // Input validation
        ErrorLibrary.validateAddress(_baseAsset, "baseAsset");
        ErrorLibrary.validateAddress(_registry, "registry");
        ErrorLibrary.validateAddress(_platform, "platform");
        _validateConfig(_config);
        require(_initialAssetRate > 0, "Invalid asset rate");
        require(_initialBuyAmount >= Constants.MIN_INITIAL_PURCHASE, "Buy amount too small");

        // Initialize OpenZeppelin contracts
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Store factory
        factory = msg.sender;

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.UPGRADER_ROLE, msg.sender);
        _grantRole(Constants.TAX_MANAGER_ROLE, msg.sender);
        _grantRole(Constants.PAUSER_ROLE, msg.sender);
        _grantRole(Constants.PLATFORM_ROLE, _platform);

        // Initialize state
        baseAsset = IERC20(_baseAsset);
        taxVault = _registry;
        defaultConfig = _config;
        assetRate = _initialAssetRate;
        initialBuyAmount = _initialBuyAmount;
        
        // Default tax rates
        buyTax = 100;  // 1%
        sellTax = 100; // 1%
    }

    // ------------------------------------------------------------------------
    // CORE TRADING FUNCTIONS
    // ------------------------------------------------------------------------

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
        
        // Apply asset rate
        uint256 adjustedK = (k * assetRate) / 1e18;
        
        // Calculate new reserves
        newTokenReserve = curve.tokenReserve + tokenIn;
        newAssetReserve = adjustedK / newTokenReserve;
        
        require(newAssetReserve < curve.assetReserve, "Invalid asset calculation");
        assetOut = curve.assetReserve - newAssetReserve;
        
        return (newAssetReserve, newTokenReserve, assetOut);
    }

    function buy(
        address token,
        uint256 assetAmount
    ) external nonReentrant whenNotPaused returns (uint256 tokenAmount) {
        require(assetAmount >= Constants.MIN_OPERATION_AMOUNT, "Amount too small");
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

        // Update curve state before calculation
        (uint256 currentTokenReserve, uint256 currentAssetReserve,) = _updateCurveState(curve, true);

        // Calculate buy impact
        (uint256 newAssetReserve, uint256 newTokenReserve, uint256 tokensOut) = 
            _calculateBuyImpact(curve, netAmount);

        require(tokensOut > 0, "No tokens to transfer");
        require(tokensOut <= currentTokenReserve, "Insufficient token reserve");

        // Update reserves
        curve.assetReserve = newAssetReserve;
        curve.tokenReserve = newTokenReserve;

        // Update state after trade
        (,,uint256 newMarketCap) = _updateCurveState(curve, false);

        // Check for graduation
        if (!curve.graduated && newMarketCap >= defaultConfig.gradThreshold) {
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
     * @notice Sells tokens back to bonding curve
     * @param token Token to sell
     * @param tokenAmount Amount of tokens to sell
     * @return assetAmount BaseAsset received after tax
     */
    function sell(
        address token,
        uint256 tokenAmount
    ) external nonReentrant whenNotPaused returns (uint256 assetAmount) {
        require(tokenAmount >= Constants.MIN_OPERATION_AMOUNT, "Amount too small");
        require(isTokenRegistered[token], "Token not found");

        CurveData storage curve = curves[token];
        require(!curve.graduated, "Token graduated");

        // Transfer tokens in first
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Update curve state before calculation
        _updateCurveState(curve, true);

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

        // Update state after trade
        _updateCurveState(curve, false);

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

    // ------------------------------------------------------------------------
    // TOKEN LAUNCH & REGISTRATION
    // ------------------------------------------------------------------------

    /**
     * @notice Launches new token with bonding curve
     * @dev Only callable by factory
     * @param token Token address to launch
     */
    function launchToken(address token) external {
        require(msg.sender == factory, "Only factory");
        require(!isTokenRegistered[token], "Already registered");
        require(token != address(0), "Zero address");
        require(initialBuyAmount > 0, "Invalid buy amount");

        isTokenRegistered[token] = true;

        // Calculate initial token purchase
        uint256 initialTokenPurchase = (Constants.INITIAL_TOKEN_SUPPLY * Constants.INITIAL_PURCHASE_PERCENT) / 100;

        // Setup initial reserves
        uint256 initialTokenReserve = Constants.INITIAL_TOKEN_SUPPLY;
        uint256 initialAssetReserve = initialBuyAmount;

        // Initialize curve data
        CurveData storage curve = curves[token];
        curve.token = token;
        curve.creator = tx.origin;
        curve.tokenReserve = initialTokenReserve;
        curve.assetReserve = initialAssetReserve;

        // Calculate initial price and market cap
        curve.currentPrice = (curve.assetReserve * 1e18) / curve.tokenReserve;
        curve.marketCap = (curve.currentPrice * Constants.INITIAL_TOKEN_SUPPLY) / 1e18;
        curve.lastPrice = curve.currentPrice;
        curve.lastUpdateTime = block.timestamp;

        // Transfer initial assets from factory
        baseAsset.safeTransferFrom(factory, address(this), initialAssetReserve);

        // Mint initial token supply
        AgentToken(token).mint(address(this), initialTokenReserve);

        // Transfer initial tokens to creator
        IERC20(token).safeTransfer(tx.origin, initialTokenPurchase);

        tokens.push(token);

        emit TokenLaunched(
            token,
            tx.origin,
            AgentToken(token).name(),
            AgentToken(token).symbol(),
            curve.tokenReserve,
            curve.assetReserve
        );

        emit Trade(
            token,
            tx.origin,
            true,
            initialTokenPurchase,
            initialAssetReserve,
            0,
            0
        );

        emit PriceUpdated(
            token,
            0,
            curve.currentPrice,
            curve.marketCap,
            block.timestamp
        );
    }

    // ------------------------------------------------------------------------
    // GRADUATION FUNCTIONS
    // ------------------------------------------------------------------------

    /**
     * @notice Handles token graduation to DEX
     * @param token Token to graduate
     */
    function _graduate(address token) internal {
        CurveData storage curve = curves[token];
        require(!curve.graduated, "Already graduated");
        
        // Update state and check threshold
        (,,uint256 currentMarketCap) = _updateCurveState(curve, true);
        require(currentMarketCap >= defaultConfig.gradThreshold, "Threshold not met");

        // Set tax exclusion
        AgentToken(token).setTaxExclusion(address(this), true);

        // Sync reserves before graduation
        _syncReserves(curve);

        // Setup DEX pairs and amounts arrays
        address[] memory pairs = new address[](defaultConfig.dexAdapters.length);
        uint256[] memory amounts = new uint256[](defaultConfig.dexAdapters.length);

        // Graduate token
        try AgentToken(token).graduate() {
            console.log("Token graduated successfully");
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Token graduation failed: ", reason)));
        }

        // Track remaining liquidity
        uint256 remainingTokens = curve.tokenReserve;
        uint256 remainingAssets = curve.assetReserve;
        uint256 totalWeight = 100; // Weights sum to 100

        // Setup DEX pairs
        for (uint256 i = 0; i < defaultConfig.dexAdapters.length; i++) {
            if (remainingTokens == 0 || remainingAssets == 0 || defaultConfig.dexWeights[i] == 0) {
                continue;
            }

            IDEXAdapter adapter = IDEXAdapter(defaultConfig.dexAdapters[i]);

            // Create or get existing pair
            address pair;
            try adapter.createPair(token, address(baseAsset)) returns (address newPair) {
                pair = newPair;
                console.log("Created new pair:", pair);

                try AgentToken(token).setDexPair(pair, true) {
                    console.log("Registered DEX pair");
                } catch Error(string memory reason) {
                    revert(string(abi.encodePacked("Failed to register pair: ", reason)));
                }
            } catch {
                pair = adapter.getPair(token, address(baseAsset));
                console.log("Using existing pair:", pair);
            }
            pairs[i] = pair;

            // Calculate liquidity amounts
            uint256 tokenAmount = (remainingTokens * defaultConfig.dexWeights[i]) / totalWeight;
            uint256 assetAmount = (remainingAssets * defaultConfig.dexWeights[i]) / totalWeight;

            // Approve exact amounts
            IERC20(token).approve(address(adapter), tokenAmount);
            baseAsset.approve(address(adapter), assetAmount);

            // Add liquidity
            try adapter.addLiquidity(
                IDEXAdapter.LiquidityParams({
                    tokenA: token,
                    tokenB: address(baseAsset),
                    amountA: tokenAmount,
                    amountB: assetAmount,
                    minAmountA: (tokenAmount * 95) / 100,
                    minAmountB: (assetAmount * 95) / 100,
                    to: address(this),
                    deadline: block.timestamp + 15 minutes,
                    stable: false
                })
            ) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
                amounts[i] = amountB;
                remainingTokens -= amountA;
                remainingAssets -= amountB;

                emit LiquidityAdded(token, pair, amountA, amountB, liquidity);
            } catch Error(string memory reason) {
                // Reset approvals on failure
                IERC20(token).approve(address(adapter), 0);
                baseAsset.approve(address(adapter), 0);
                revert(string(abi.encodePacked("Liquidity addition failed: ", reason)));
            }
        }

        curve.graduated = true;
        curve.dexPairs = pairs;

        emit TokenGraduated(token, pairs, amounts);
    }

    /**
     * @notice Gets detailed token status including total liquidity
     * @dev Returns combined reserves and market data from both bonding curve and DEX
     * @param token Address of token to query
     * @return tokenReserve Total token reserve across all venues
     * @return assetReserve Total asset reserve across all venues
     * @return marketCap Current total market cap in base asset terms
     */
    function getTokenState(address token) external view returns (
        uint256 tokenReserve,
        uint256 assetReserve,
        uint256 marketCap
    ) {
        console.log("1. Starting getTokenState");
        require(isTokenRegistered[token], "Token not found");
        
        CurveData storage curve = curves[token];
        
        // First get curve reserves
        tokenReserve = curve.tokenReserve;
        assetReserve = curve.assetReserve;

        console.log("2. Base reserves:", tokenReserve, assetReserve);
        console.log("3. Graduated status:", curve.graduated);
        
        // Add DEX reserves if graduated
        if (curve.graduated && curve.dexPairs.length > 0) {
            console.log("4. Checking DEX pairs");
            
            for (uint i = 0; i < curve.dexPairs.length; i++) {
                address pair = curve.dexPairs[i];
                console.log("5. Checking DEX pair:", pair);

                if (pair != address(0)) {
                    // Get token ordering
                    address token0;
                    try IDEXPair(pair).token0() returns (address _token0) {
                        token0 = _token0;
                        console.log("6. Got token0:", token0);
                        
                        // Get reserves
                        try IDEXPair(pair).getReserves() returns (
                            uint112 reserve0,
                            uint112 reserve1,
                            uint32
                        ) {
                            console.log("7. Got reserves:", reserve0, reserve1);
                            
                            // Add reserves based on token order
                            if (token0 == token) {
                                tokenReserve += reserve0;
                                assetReserve += reserve1;
                            } else {
                                tokenReserve += reserve1;
                                assetReserve += reserve0;
                            }
                            console.log("8. Updated reserves:", tokenReserve, assetReserve);
                        } catch {
                            console.log("Failed to get reserves for pair:", pair);
                            continue;
                        }
                    } catch {
                        console.log("Failed to get token0 for pair:", pair);
                        continue;
                    }
                }
            }
        }

        // Calculate market cap based on total reserves
        if (tokenReserve > 0) {
            uint256 price = (assetReserve * 1e18) / tokenReserve;
            marketCap = (price * Constants.INITIAL_TOKEN_SUPPLY) / 1e18;
        } else {
            marketCap = 0;
        }

        console.log("9. Final values:", tokenReserve, assetReserve, marketCap);
        return (tokenReserve, assetReserve, marketCap);
    }

    

    /**
     * @notice Updates price data for a token
     * @dev Calculates new price and market cap based on current reserves
     * @param token Token address to update
     * @return success True if update successful
     */
    function updatePriceData(address token) external returns (bool success) {
        require(isTokenRegistered[token], "Token not found");
        CurveData storage curve = curves[token];

        // Sync reserves first
        _syncReserves(curve);
        
        // Update price data
        _updatePriceData(curve);

        return true;
    }

    /**
     * @notice Checks for and executes graduation if threshold met
     * @param token Token to check for graduation
     * @return graduated True if graduation executed
     */
    function checkAndGraduate(address token) external returns (bool graduated) {
        require(isTokenRegistered[token], "Token not found");
        CurveData storage curve = curves[token];
        
        require(!curve.graduated, "Already graduated");

        // Update state before checking
        _syncReserves(curve);
        _updatePriceData(curve);

        if (curve.marketCap >= defaultConfig.gradThreshold) {
            _graduate(token);
            return true;
        }

        return false;
    }

    /**
     * @notice Gets all active tokens managed by contract
     * @return Array of token addresses
     */
    function getAllTokens() external view returns (address[] memory) {
        return tokens;
    }

    /**
     * @notice Gets detailed info for multiple tokens
     * @param tokenList Array of token addresses
     * @return tokens Array of CurveData structs
     */
    function getMultipleTokenInfo(address[] calldata tokenList) 
        external 
        view 
        returns (CurveData[] memory) 
    {
        CurveData[] memory result = new CurveData[](tokenList.length);
        
        for (uint i = 0; i < tokenList.length; i++) {
            require(isTokenRegistered[tokenList[i]], "Token not found");
            result[i] = curves[tokenList[i]];
        }
        
        return result;
    }

    /**
     * @notice Gets graduation threshold
     * @return Current graduation threshold
     */
    function getGraduationThreshold() external view returns (uint256) {
        return defaultConfig.gradThreshold;
    }

    /**
     * @notice Gets global platform settings
     * @return factory Factory address
     * @return baseAssetAddr Base asset address
     * @return taxVaultAddr Tax collection address
     * @return buyTaxRate Current buy tax rate
     * @return sellTaxRate Current sell tax rate
     * @return assetRateValue Current asset rate
     * @return minBuyAmount Minimum initial buy amount
     */
    function getPlatformSettings() external view returns (
        address factory,
        address baseAssetAddr,
        address taxVaultAddr,
        uint256 buyTaxRate,
        uint256 sellTaxRate,
        uint256 assetRateValue,
        uint256 minBuyAmount
    ) {
        return (
            factory,
            address(baseAsset),
            taxVault,
            buyTax,
            sellTax,
            assetRate,
            initialBuyAmount
        );
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

    /**
     * @notice Calculates tax split between platform and creator
     * @param taxOnBuy True if buy tax, false if sell tax
     * @param amount Amount to calculate tax on
     * @return platformTax Platform portion of tax
     * @return creatorTax Creator portion of tax
     */
    function getTaxSplit(
        bool taxOnBuy,
        uint256 amount
    ) public view returns (uint256 platformTax, uint256 creatorTax) {
        uint256 totalTax = (amount * (taxOnBuy ? buyTax : sellTax)) / Constants.BASIS_POINTS;
        platformTax = (totalTax * Constants.PLATFORM_FEE_SHARE) /
            (Constants.PLATFORM_FEE_SHARE + Constants.CREATOR_FEE_SHARE);
        creatorTax = totalTax - platformTax;
    }

    /**
     * @notice Core helper function to update and sync curve state
     * @param curve Token curve data to update
     * @param syncReserves Whether to sync reserves with actual balances
     * @return tokenReserve Current token reserve
     * @return assetReserve Current asset reserve
     * @return marketCap Updated market cap
     */
    function _updateCurveState(
        CurveData storage curve,
        bool syncReserves
    ) private returns (
        uint256 tokenReserve,
        uint256 assetReserve,
        uint256 marketCap
    ) {
        // Sync reserves if requested
        if (syncReserves) {
            uint256 tokenBalance = IERC20(curve.token).balanceOf(address(this));
            uint256 assetBalance = baseAsset.balanceOf(address(this));
            
            curve.tokenReserve = tokenBalance;
            curve.assetReserve = assetBalance;
        }
        
        // Store current values
        tokenReserve = curve.tokenReserve;
        assetReserve = curve.assetReserve;
        
        // Store old price for event
        uint256 oldPrice = curve.currentPrice;
        
        // Update price
        curve.currentPrice = (assetReserve * 1e18) / tokenReserve;
        
        // Update market cap
        marketCap = (curve.currentPrice * Constants.INITIAL_TOKEN_SUPPLY) / 1e18;
        curve.marketCap = marketCap;
        
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
            marketCap,
            block.timestamp
        );
        
        return (tokenReserve, assetReserve, marketCap);
    }

    // Replace old _syncReserves and _updatePriceData with new helper
    function _syncReserves(CurveData storage curve) private {
        _updateCurveState(curve, true);
    }

    function _updatePriceData(CurveData storage curve) private {
        _updateCurveState(curve, false);
    }

    /**
     * @notice Validates curve configuration
     * @param config Configuration to validate
     */
    function _validateConfig(CurveConfig memory config) internal pure {
        require(
            config.gradThreshold >= Constants.MIN_GRAD_THRESHOLD,
            Constants.ERR_INVALID_THRESHOLD
        );
        require(
            config.dexAdapters.length == config.dexWeights.length,
            Constants.ERR_ARRAY_LENGTH
        );

        uint256 totalWeight;
        for (uint256 i = 0; i < config.dexWeights.length; i++) {
            totalWeight += config.dexWeights[i];
        }
        require(totalWeight == Constants.MAX_WEIGHT, Constants.ERR_INVALID_WEIGHTS);
    }
}