// file: contracts/token/core/AgentBondingManager.sol
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
 * @title AgentBondingManager
 * @notice Manages the entire lifecycle of AI agent tokens from launch through a bonding curve, then graduates to DEX.
 * 
 * @dev Key Features:
 *  - Launches new AI agent tokens (requires initial buy amount).
 *  - Implements a bonding curve (constant product) for trading.
 *  - Tracks price and market cap data in the `baseAsset`.
 *  - Graduates tokens to external DEXes and burns LP tokens.
 *  - Utilizes AccessControl for role-based permissions.
 *  - ReentrancyGuard and Pausable for security.
 *
 * @custom:security-contact security@yourdomain.com
 *
 * ----------------------------------------------------------------------------
 * CHANGES IN THIS VERSION (for a standard 18-decimal ERC20 baseAsset):
 *  - Removed references to 6-decimal USDC scaling.
 *  - We now assume `baseAsset` has 18 decimals, matching the new agent tokens.
 *  - Initial liquidity is 1:1 in token count (e.g. 1M agent tokens => 1M baseAsset).
 *  - All bonding-curve math is done directly with 18 decimals (no scaleFactor).
 * ----------------------------------------------------------------------------
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
     * @notice Configuration for how a token graduates to DEX
     * @param gradThreshold Amount of baseAsset tokens needed for graduation
     * @param dexAdapters Array of DEX adapter addresses for graduation
     * @param dexWeights Percentage weights for each DEX (must sum to 100)
     */
    struct CurveConfig {
        uint256 gradThreshold;     
        address[] dexAdapters;     
        uint256[] dexWeights;      
    }

    /**
     * @notice Comprehensive data for each token's bonding curve
     * @param token Token contract address
     * @param creator Token creator address for tax distribution
     * @param tokenReserve Current token reserve in the curve
     * @param assetReserve Current baseAsset reserve in the curve
     * @param graduated Whether token has graduated to DEX
     * @param dexPairs DEX pair addresses after graduation
     * @param currentPrice Current token price in baseAsset (scaled by 1e18)
     * @param marketCap Current market cap in baseAsset
     * @param lastPrice Last recorded price for 24h comparison
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

    /// @notice Address of the factory that deployed this manager
    address public factory;

    /// @notice Base asset token (assumed 18 decimals)
    IERC20 public baseAsset;

    /// @notice Protocol tax vault address
    address public taxVault;

    /// @notice Buy tax in basis points (100 = 1%)
    uint256 public buyTax;

    /// @notice Sell tax in basis points (100 = 1%)
    uint256 public sellTax;

    /// @notice Configurable rate that affects curve steepness (not used in formula below, but left for future expansions)
    uint256 public assetRate;

    /// @notice Required initial buy amount in baseAsset
    uint256 public initialBuyAmount;

    /// @notice Default configuration for new curves
    CurveConfig public defaultConfig;

    /// @notice Maps token address to its curve data
    mapping(address => CurveData) public curves;

    /// @notice List of all launched tokens
    address[] public tokens;

    /// @notice Maps token address to registration status
    mapping(address => bool) public isTokenRegistered;

    // ------------------------------------------------------------------------
    // EVENTS
    // ------------------------------------------------------------------------

    /**
     * @notice Emitted when a new token is launched
     * @param token Address of the new token
     * @param creator Address of token creator
     * @param name Token name
     * @param symbol Token symbol
     * @param initialTokenReserve Initial token reserve
     * @param initialAssetReserve Initial baseAsset reserve
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
     * @notice Emitted on each trade
     * @param token Token being traded
     * @param trader Address executing the trade
     * @param isBuy Whether it's a buy (true) or sell (false)
     * @param tokenAmount Amount of tokens traded
     * @param assetAmount Amount of baseAsset tokens traded
     * @param platformTax Amount of tax sent to platform
     * @param creatorTax Amount of tax sent to creator
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
     * @notice Emitted when a token graduates to DEX
     * @param token Address of graduated token
     * @param dexPairs Array of DEX pair addresses
     * @param amounts Liquidity amounts provided to each DEX
     */
    event TokenGraduated(
        address indexed token,
        address[] dexPairs,
        uint256[] amounts
    );

    /**
     * @notice Emitted when liquidity is added to a DEX pair
     */
    event LiquidityAdded(
        address indexed token,
        address indexed pair,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    /**
     * @notice Emitted when tax configuration is updated
     * @param taxVault New tax vault address
     * @param buyTax New buy tax rate
     * @param sellTax New sell tax rate
     */
    event TaxConfigUpdated(
        address indexed taxVault,
        uint256 buyTax,
        uint256 sellTax
    );

    /**
     * @notice Emitted when asset rate is updated
     * @param oldRate Previous asset rate
     * @param newRate New asset rate
     */
    event AssetRateUpdated(
        uint256 oldRate,
        uint256 newRate
    );

    /**
     * @notice Emitted when initial buy amount is updated
     * @param newAmount New required initial buy amount
     */
    event InitialBuyAmountUpdated(uint256 newAmount);

    /**
     * @notice Emitted when a token's price data is updated
     * @param token Token address
     * @param oldPrice Previous price
     * @param newPrice New price
     * @param marketCap New market cap
     * @param timestamp Update timestamp
     */
    event PriceUpdated(
        address indexed token,
        uint256 oldPrice,
        uint256 newPrice,
        uint256 marketCap,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a token is registered
     * @param token Address of registered token
     */
    event TokenRegistered(address indexed token);

    // ------------------------------------------------------------------------
    // CONSTRUCTOR & INITIALIZER
    // ------------------------------------------------------------------------

    /**
     * @dev Prevents direct initialization of implementation contract
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with required parameters
     * @dev Must only be called once by proxy
     * @param _baseAsset Address of base asset token (18 decimals recommended)
     * @param _registry Tax vault address
     * @param _platform Platform admin address
     * @param _config Default curve configuration
     * @param _initialAssetRate Initial asset rate for curve adjustment (unused in formula here, but stored)
     * @param _initialBuyAmount Required initial buy amount in baseAsset
     */
    function initialize(
        address _baseAsset,
        address _registry,
        address _platform,
        CurveConfig calldata _config,
        uint256 _initialAssetRate,
        uint256 _initialBuyAmount
    ) external initializer {
        ErrorLibrary.validateAddress(_baseAsset, "baseAsset");
        ErrorLibrary.validateAddress(_registry, "registry");
        ErrorLibrary.validateAddress(_platform, "platform");
        _validateConfig(_config);
        require(_initialAssetRate > 0, "Invalid asset rate");
        require(_initialBuyAmount > 0, "Invalid initial buy amount");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Store factory address
        factory = msg.sender;

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.UPGRADER_ROLE, msg.sender);
        _grantRole(Constants.TAX_MANAGER_ROLE, msg.sender);
        _grantRole(Constants.PAUSER_ROLE, msg.sender);
        _grantRole(Constants.PLATFORM_ROLE, _platform);

        // Initialize state variables
        baseAsset = IERC20(_baseAsset);
        taxVault = _registry;
        defaultConfig = _config;
        assetRate = _initialAssetRate;
        initialBuyAmount = _initialBuyAmount;

        // Set default tax rates
        buyTax = 100;  // 1%
        sellTax = 100; // 1%
    }

    // ------------------------------------------------------------------------
    // TOKEN LAUNCH & REGISTRATION
    // ------------------------------------------------------------------------

    /**
     * @notice Launches an existing token with the manager
     * @dev Only callable by factory, uses same initialization as registerToken but with better pricing logic
     * @param token Token address to launch
     */
    function launchToken(address token) external {
        require(msg.sender == factory, "Only factory can launch");
        require(!isTokenRegistered[token], "Already registered");
        require(token != address(0), "Cannot launch zero address");

        isTokenRegistered[token] = true;

        // Start with bare minimum to make price near zero
        uint256 initialTokenReserve = Constants.INITIAL_TOKEN_SUPPLY;  // 100M * 1e18 tokens
        uint256 initialAssetReserve = 1;  // 1 wei

        // Initialize curve data
        CurveData storage curve = curves[token];
        curve.token = token;
        curve.creator = tx.origin;
        curve.tokenReserve = initialTokenReserve;
        curve.assetReserve = initialAssetReserve;
        
        // Calculate initial price
        curve.currentPrice = (curve.assetReserve * 1e18) / curve.tokenReserve;
        curve.marketCap = (curve.currentPrice * curve.tokenReserve) / 1e18;
        curve.lastPrice = curve.currentPrice;
        curve.lastUpdateTime = block.timestamp;

        // Mint initial tokens to this contract
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


    // ------------------------------------------------------------------------
    // TRADING FUNCTIONS
    // ------------------------------------------------------------------------

    /**
     * @notice Buys tokens from the bonding curve
     * @dev Includes tax and slippage protection
     * @param token Address of token to buy
     * @param assetAmount Amount of baseAsset to spend (includes tax)
     * @return tokenAmount Amount of tokens received
     */
    function buy(
        address token,
        uint256 assetAmount
    ) external nonReentrant whenNotPaused returns (uint256 tokenAmount) {
        require(assetAmount >= Constants.MIN_OPERATION_AMOUNT, "Amount too small");
        require(isTokenRegistered[token], "Token not found");

        CurveData storage curve = curves[token];
        require(!curve.graduated, "Token graduated");
        
        // Calculate tax amounts
        uint256 totalTaxAmount = (assetAmount * buyTax) / Constants.BASIS_POINTS;
        uint256 platformTaxAmount = (totalTaxAmount * Constants.PLATFORM_FEE_SHARE) /
            (Constants.PLATFORM_FEE_SHARE + Constants.CREATOR_FEE_SHARE);
        uint256 creatorTaxAmount = totalTaxAmount - platformTaxAmount;

        // Calculate net amount after tax
        uint256 netAmount = assetAmount - totalTaxAmount;
        require(netAmount > 0, "Net amount after tax is zero");

        // Transfer asset from buyer first
        baseAsset.safeTransferFrom(msg.sender, address(this), assetAmount);

        // Distribute taxes
        if (platformTaxAmount > 0) {
            baseAsset.safeTransfer(taxVault, platformTaxAmount);
        }
        if (creatorTaxAmount > 0) {
            baseAsset.safeTransfer(curve.creator, creatorTaxAmount);
        }

        // Calculate token amount using constant product formula
        uint256 oldK = curve.tokenReserve * curve.assetReserve;
        uint256 newAssetReserve = curve.assetReserve + netAmount;
        uint256 newTokenReserve = oldK / newAssetReserve;
        
        require(newTokenReserve < curve.tokenReserve, "Invalid token calculation");
        tokenAmount = curve.tokenReserve - newTokenReserve;
        require(tokenAmount > 0, "No tokens to transfer");

        // Update reserves
        curve.assetReserve = newAssetReserve;
        curve.tokenReserve = newTokenReserve;

        // Update price data
        uint256 oldPrice = curve.currentPrice;

        // Calculate new price
        curve.currentPrice = (curve.assetReserve * 1e18) / curve.tokenReserve;
        curve.marketCap = (curve.currentPrice * curve.tokenReserve) / 1e18;
        curve.lastPrice = oldPrice;
        curve.lastUpdateTime = block.timestamp;
        
        // Check for graduation
        if (!curve.graduated && (curve.marketCap >= defaultConfig.gradThreshold)) {
            _graduate(token);
        }

        // Transfer tokens to buyer
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit Trade(
            token,
            msg.sender,
            true,
            tokenAmount,
            assetAmount,
            platformTaxAmount,
            creatorTaxAmount
        );

        emit PriceUpdated(
            token,
            oldPrice,
            curve.currentPrice,
            curve.marketCap,
            block.timestamp
        );

        return tokenAmount;
    }



    /**
     * @notice Sells tokens back to the bonding curve
     * @dev Includes tax and slippage protection
     * @param token Address of token to sell
     * @param tokenAmount Amount of tokens to sell
     * @return assetAmount Amount of baseAsset received (after tax)
     */
    function sell(
        address token,
        uint256 tokenAmount
    ) external nonReentrant whenNotPaused returns (uint256 assetAmount) {
        require(tokenAmount >= Constants.MIN_OPERATION_AMOUNT, "Amount too small");
        require(isTokenRegistered[token], "Token not found");

        CurveData storage curve = curves[token];
        require(!curve.graduated, "Token graduated");

        // Calculate asset amount using constant product formula
        uint256 oldK = curve.tokenReserve * curve.assetReserve;
        uint256 newTokenReserve = curve.tokenReserve + tokenAmount;
        uint256 newAssetReserve = oldK / newTokenReserve;
        
        require(newAssetReserve < curve.assetReserve, "Invalid asset calculation");
        assetAmount = curve.assetReserve - newAssetReserve;
        require(assetAmount > 0, "No assets to transfer");

        // Calculate tax amounts
        uint256 totalTaxAmount = (assetAmount * sellTax) / Constants.BASIS_POINTS;
        uint256 platformTaxAmount = (totalTaxAmount * Constants.PLATFORM_FEE_SHARE) /
            (Constants.PLATFORM_FEE_SHARE + Constants.CREATOR_FEE_SHARE);
        uint256 creatorTaxAmount = totalTaxAmount - platformTaxAmount;

        // Calculate net amount after tax
        uint256 netAmount = assetAmount - totalTaxAmount;
        require(netAmount > 0, "Net amount after tax is zero");

        // Transfer tokens from seller first
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        // Update reserves
        curve.assetReserve = newAssetReserve;
        curve.tokenReserve = newTokenReserve;

        // Update price data
        uint256 oldPrice = curve.currentPrice;
        curve.currentPrice = (curve.assetReserve * 1e18) / curve.tokenReserve;
        curve.marketCap = (curve.currentPrice * curve.tokenReserve) / 1e18;
        curve.lastPrice = oldPrice;
        curve.lastUpdateTime = block.timestamp;

        // Transfer assets to seller and taxes
        if (platformTaxAmount > 0) {
            baseAsset.safeTransfer(taxVault, platformTaxAmount);
        }
        if (creatorTaxAmount > 0) {
            baseAsset.safeTransfer(curve.creator, creatorTaxAmount);
        }
        baseAsset.safeTransfer(msg.sender, netAmount);

        emit Trade(
            token,
            msg.sender,
            false,
            tokenAmount,
            assetAmount,
            platformTaxAmount,
            creatorTaxAmount
        );

        emit PriceUpdated(
            token,
            oldPrice,
            curve.currentPrice,
            curve.marketCap,
            block.timestamp
        );

        return netAmount;
    }


    // ------------------------------------------------------------------------
    // GRADUATION LOGIC
    // ------------------------------------------------------------------------

    /**
     * @notice Returns whether a token has graduated
     * @param token Token address
     * @return graduated Graduation status
     */
    function isGraduated(address token) public view returns (bool graduated) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        return curve.graduated;
    }

    /**
     * @notice Returns DEX pairs for a graduated token
     * @param token Token address
     * @return pairs Array of DEX pair addresses
     */
    function getDexPairs(address token) public view returns (address[] memory) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        return curve.dexPairs;
    }

    /**
     * @notice Get the current state of a token including total reserves and market cap
     * @dev For graduated tokens, this includes both bonding curve and DEX liquidity
     * @dev The function sums up reserves from the bonding curve and all DEX pairs
     * @dev Market cap is calculated as (total asset reserve * token price)
     * 
     * @param token Address of the token to check
     * @return tokenReserve Total token reserve (bonding curve + DEX if graduated)
     * @return assetReserve Total base asset reserve (bonding curve + DEX if graduated)
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
        
        // Get base reserves
        tokenReserve = curve.tokenReserve;
        assetReserve = curve.assetReserve;

        console.log("2. Base reserves:", tokenReserve, assetReserve);
        console.log("3. Graduated status:", curve.graduated);
        
        // Add DEX reserves if graduated
        if (curve.graduated && curve.dexPairs.length > 0) {
            console.log("4. Checking DEX pair");
            address pair = curve.dexPairs[0];
            console.log("5. DEX pair address:", pair);

            // First verify pair exists
            if (pair != address(0)) {
                // Get token ordering
                address token0;
                try IDEXPair(pair).token0() returns (address _token0) {
                    token0 = _token0;
                    console.log("6. Got token0:", token0);
                } catch {
                    console.log("6. Failed to get token0");
                    // Continue with just base reserves
                    marketCap = assetReserve;
                    return (tokenReserve, assetReserve, marketCap);
                }

                // Get reserves if token0 call succeeded
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
                    console.log("7. Failed to get reserves");
                    // Continue with just base reserves
                }
            }
        }

        marketCap = assetReserve;
        console.log("9. Final values:", tokenReserve, assetReserve, marketCap);

        return (tokenReserve, assetReserve, marketCap);
    }

    /**
     * @notice Get total reserves including both internal and DEX liquidity
     * @param token Address of the token
     * @return tokenReserve Total token reserve
     * @return assetReserve Total asset reserve
     */
    function getTotalReserves(address token) public view returns (uint256 tokenReserve, uint256 assetReserve) {
        CurveData storage curve = curves[token];
        
        // Start with internal reserves
        tokenReserve = curve.tokenReserve;
        assetReserve = curve.assetReserve;
        
        // If graduated, add DEX reserves
        if (curve.graduated && curve.dexPairs.length > 0) {
            for (uint256 i = 0; i < curve.dexPairs.length; i++) {
                address pair = curve.dexPairs[i];
                if (pair != address(0)) {
                    try IDEXPair(pair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
                        address token0 = IDEXPair(pair).token0();
                        if (token0 == token) {
                            tokenReserve += reserve0;
                            assetReserve += reserve1;
                        } else {
                            tokenReserve += reserve1;
                            assetReserve += reserve0;
                        }
                    } catch {
                        // Skip if we can't read reserves
                    }
                }
            }
        }
    }

    /**
     * @notice Returns the array of DEX adapters from default config
     * @return Array of DEX adapter addresses
     */
    function getDEXAdapters() external view returns (address[] memory) {
        return defaultConfig.dexAdapters;
    }

    /**
     * @notice Graduates a token to external DEX liquidity
     * @dev Creates pairs and adds liquidity on configured DEXes
     * @param token Address of the token to graduate
     */
    function _graduate(address token) internal {
        CurveData storage curve = curves[token];
        require(!curve.graduated, "Already graduated");
        require(curve.assetReserve >= defaultConfig.gradThreshold, "Threshold not met");

        // Validate DEX configuration
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < defaultConfig.dexWeights.length; i++) {
            totalWeight += defaultConfig.dexWeights[i];
        }
        require(totalWeight == 100, "Weights must sum to 100");
        require(defaultConfig.dexWeights.length == defaultConfig.dexAdapters.length, "Mismatched weights and adapters");

        // Get actual balances
        uint256 actualTokenBalance = IERC20(token).balanceOf(address(this));
        uint256 actualAssetBalance = baseAsset.balanceOf(address(this));

        console.log("=== Pre-Sync State ===");
        console.log("Curve Reserves:");
        console.log("- Token reserve:", curve.tokenReserve);
        console.log("- Asset reserve:", curve.assetReserve);
        console.log("Actual Balances:");
        console.log("- Token balance:", actualTokenBalance);
        console.log("- Asset balance:", actualAssetBalance);
        console.log("Number of DEX adapters:", defaultConfig.dexAdapters.length);

        // Sync curve reserves with actual balances
        curve.tokenReserve = actualTokenBalance;
        curve.assetReserve = actualAssetBalance;

        // Update price data after sync
        curve.currentPrice = (curve.assetReserve * 1e18) / curve.tokenReserve;
        curve.marketCap = (curve.currentPrice * curve.tokenReserve) / 1e18;
        curve.lastPrice = curve.currentPrice;
        curve.lastUpdateTime = block.timestamp;

        address[] memory pairs = new address[](defaultConfig.dexAdapters.length);
        uint256[] memory amounts = new uint256[](defaultConfig.dexAdapters.length);
        
        // Create all pairs first
        for (uint256 i = 0; i < defaultConfig.dexAdapters.length; i++) {
            IDEXAdapter adapter = IDEXAdapter(defaultConfig.dexAdapters[i]);
            
            try adapter.createPair(token, address(baseAsset)) returns (address newPair) {
                pairs[i] = newPair;
                console.log("Created new pair:", newPair);
                
                // Register pair with token contract
                try AgentToken(token).setDexPair(newPair, true) {
                    console.log("Registered DEX pair with token");
                } catch Error(string memory reason) {
                    revert(string(abi.encodePacked("Failed to register DEX pair: ", reason)));
                }
            } catch {
                pairs[i] = adapter.getPair(token, address(baseAsset));
                console.log("Using existing pair:", pairs[i]);
                
                // Register existing pair
                try AgentToken(token).setDexPair(pairs[i], true) {
                    console.log("Registered existing DEX pair with token");
                } catch Error(string memory reason) {
                    revert(string(abi.encodePacked("Failed to register existing DEX pair: ", reason)));
                }
            }
            
            require(pairs[i] != address(0), "Failed to create/get pair");
        }

        // Graduate the token first
        try AgentToken(token).graduate() {
            console.log("Token graduated successfully");
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Token graduation failed: ", reason)));
        }

        // Now add liquidity
        uint256 remainingTokens = actualTokenBalance;
        uint256 remainingAssets = actualAssetBalance;

        for (uint256 i = 0; i < defaultConfig.dexAdapters.length; i++) {
            if (remainingTokens == 0 || remainingAssets == 0 || defaultConfig.dexWeights[i] == 0) {
                continue;
            }

            IDEXAdapter adapter = IDEXAdapter(defaultConfig.dexAdapters[i]);
            address router = adapter.getRouterAddress();
            
            uint256 assetAmount = (actualAssetBalance * defaultConfig.dexWeights[i]) / 100;
            uint256 tokenAmount = (actualTokenBalance * defaultConfig.dexWeights[i]) / 100;
            
            assetAmount = assetAmount > remainingAssets ? remainingAssets : assetAmount;
            tokenAmount = tokenAmount > remainingTokens ? remainingTokens : tokenAmount;
            
            console.log("DEX Allocation for adapter", i);
            console.log("- Weight:", defaultConfig.dexWeights[i]);
            console.log("- Token amount:", tokenAmount);
            console.log("- Asset amount:", assetAmount);
            
            // Approve adapter
            IERC20(token).approve(address(adapter), tokenAmount);
            baseAsset.approve(address(adapter), assetAmount);
            
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
                console.log("Liquidity added:");
                console.log("- Token used:", amountA);
                console.log("- Asset used:", amountB);
                console.log("- LP tokens:", liquidity);
                emit LiquidityAdded(token, pairs[i], amountA, amountB, liquidity);
            } catch Error(string memory reason) {
                console.log("Liquidity addition failed:", reason);
                revert(string(abi.encodePacked("Liquidity addition failed: ", reason)));
            }

            IERC20(token).approve(address(adapter), 0);
            baseAsset.approve(address(adapter), 0);
        }

        curve.graduated = true;
        curve.dexPairs = pairs;

        emit TokenGraduated(token, pairs, amounts);
    }


    // ------------------------------------------------------------------------
    // ADMIN CONFIGURATION
    // ------------------------------------------------------------------------

    /**
     * @notice Updates tax configuration
     * @param _registry New tax vault address
     * @param newBuyTax New buy tax in basis points
     * @param newSellTax New sell tax in basis points
     */
    function updateTaxConfig(
        address _registry,
        uint256 newBuyTax,
        uint256 newSellTax
    ) external onlyRole(Constants.TAX_MANAGER_ROLE) {
        require(_registry != address(0), Constants.ERR_ZERO_ADDRESS);
        require(newBuyTax <= Constants.MAX_TAX_RATE, Constants.ERR_TAX_TOO_HIGH);
        require(newSellTax <= Constants.MAX_TAX_RATE, Constants.ERR_TAX_TOO_HIGH);

        taxVault = _registry;
        buyTax = newBuyTax;
        sellTax = newSellTax;

        emit TaxConfigUpdated(_registry, newBuyTax, newSellTax);
    }

    /**
     * @notice Updates the asset rate that affects curve steepness
     * @dev This rate is currently not used in the formula, but remains in the contract
     *      for future expansions or alternate curve logic.
     * @param newRate New asset rate value
     */
    function setAssetRate(uint256 newRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRate > 0, "Invalid rate");
        uint256 oldRate = assetRate;
        assetRate = newRate;
        emit AssetRateUpdated(oldRate, newRate);
    }

    /**
     * @notice Updates required initial buy amount
     * @param newAmount New required amount
     */
    function setInitialBuyAmount(uint256 newAmount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAmount > 0, "Invalid amount");
        initialBuyAmount = newAmount;
        emit InitialBuyAmountUpdated(newAmount);
    }

    /**
     * @notice Updates the default curve configuration
     * @param config New configuration
     */
    function setDefaultConfig(CurveConfig calldata config)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validateConfig(config);
        defaultConfig = config;
    }

    // ------------------------------------------------------------------------
    // VIEW FUNCTIONS
    // ------------------------------------------------------------------------

    /**
     * @notice Returns current price for a token, scaled by 1e18
     * @param token Token address
     * @return Current token price in baseAsset
     */
    function getPrice(address token) external view returns (uint256) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");

        if (curve.assetReserve == 0) {
            return 0;
        }
        // Price = assetReserve / tokenReserve, scaled by 1e18
        return (curve.assetReserve * 1e18) / curve.tokenReserve;
    }

    /**
     * @notice Gets complete price data for a token
     * @param token Token address
     * @return currentPrice Current token price
     * @return lastPrice Last recorded price
     * @return marketCap Current market cap
     * @return lastUpdateTime Last update timestamp
     */
    function getPriceData(address token) external view returns (
        uint256 currentPrice,
        uint256 lastPrice,
        uint256 marketCap,
        uint256 lastUpdateTime
    ) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        return (
            curve.currentPrice,
            curve.lastPrice,
            curve.marketCap,
            curve.lastUpdateTime
        );
    }

    /**
     * @notice Calculates 24h price change in basis points
     * @param token Token address
     * @return Price change in basis points (e.g. 1000 = 10%)
     */
    function getPrice24hChange(address token) external view returns (int256) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        
        // If no update in last 24h or lastPrice == 0, return 0
        if (curve.lastUpdateTime < block.timestamp - 24 hours || curve.lastPrice == 0) {
            return 0;
        }

        int256 priceDiff = int256(curve.currentPrice) - int256(curve.lastPrice);
        return (priceDiff * 10000) / int256(curve.lastPrice);
    }

    /**
     * @notice Returns buy price for a given asset amount (hypothetical)
     * @param token Token address
     * @param assetAmount Amount of baseAsset tokens to spend
     * @return tokenAmount Amount of tokens that would be received
     */
    function getBuyPrice(
        address token,
        uint256 assetAmount
    ) external view returns (uint256 tokenAmount) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");

        // Calculate net amount after buy tax
        uint256 totalTaxAmount = (assetAmount * buyTax) / Constants.BASIS_POINTS;
        uint256 netAmount = assetAmount - totalTaxAmount;
        if (netAmount == 0) return 0;

        // newAssetReserve = old assetReserve + netAmount
        uint256 newAssetReserve = curve.assetReserve + netAmount;

        // K = tokenReserve * assetReserve
        uint256 K = curve.tokenReserve * curve.assetReserve;

        // newTokenReserve = K / newAssetReserve
        uint256 newTokenReserve = K / newAssetReserve;
        if (newTokenReserve >= curve.tokenReserve) return 0;

        return curve.tokenReserve - newTokenReserve;
    }

    /**
     * @notice Returns sell price for a given token amount (hypothetical)
     * @param token Token address
     * @param tokenAmount Amount of tokens to sell
     * @return assetAmount Amount of baseAsset tokens that would be received (after tax)
     */
    function getSellPrice(
        address token,
        uint256 tokenAmount
    ) external view returns (uint256 assetAmount) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");

        // newTokenReserve = old tokenReserve + tokenAmount
        uint256 newTokenReserve = curve.tokenReserve + tokenAmount;

        // K = tokenReserve * assetReserve
        uint256 K = curve.tokenReserve * curve.assetReserve;

        // newAssetReserve = K / newTokenReserve
        uint256 newAssetReserve = K / newTokenReserve;
        if (newAssetReserve >= curve.assetReserve) return 0;

        uint256 grossAmount = curve.assetReserve - newAssetReserve;

        // Subtract sell tax
        uint256 totalTaxAmount = (grossAmount * sellTax) / Constants.BASIS_POINTS;
        return grossAmount - totalTaxAmount;
    }

    /**
     * @notice Gets reserve values for a token
     * @param token Token address
     * @return tokenReserve Current token reserve
     * @return assetReserve Current baseAsset reserve
     */
    function getReserves(
        address token
    ) external view returns (uint256 tokenReserve, uint256 assetReserve) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        return (curve.tokenReserve, curve.assetReserve);
    }

    /**
     * @notice Calculates expected tax split for a given amount
     * @param taxOnBuy Whether calculating for buy (true) or sell (false)
     * @param amount Amount to calculate tax on
     * @return platformTax Amount that goes to platform
     * @return creatorTax Amount that goes to creator
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
     * @notice Retrieves the current market capitalization of a token
     * @dev Market cap is calculated as (current price * token reserve)
     *      and is stored in the curve data during each trade
     * @dev This value is used to determine if a token has reached the graduation threshold
     * @param token The address of the token to query
     * @return The current market capitalization in base asset terms (with 18 decimals)
     * @custom:throws "Token not found" if the token is not registered in the system
     */
    function getMarketCap(address token) external view returns (uint256) {
        require(isTokenRegistered[token], "Token not found");
        return curves[token].marketCap;
    }

    // ------------------------------------------------------------------------
    // UTILITY FUNCTIONS
    // ------------------------------------------------------------------------

    /**
     * @notice Validates curve configuration parameters
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

    // ------------------------------------------------------------------------
    // EMERGENCY / ADMIN FUNCTIONS
    // ------------------------------------------------------------------------

    /**
     * @notice Emergency rescue of tokens sent to contract
     * @dev Cannot rescue baseAsset or non-graduated curve tokens
     * @param token Token address
     * @param to Recipient
     * @param amount Amount of tokens to rescue
     */
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), Constants.ERR_ZERO_ADDRESS);
        require(amount > 0, Constants.ERR_ZERO_AMOUNT);

        // Validate token rescue restrictions
        if (curves[token].token == token) {
            require(curves[token].graduated, "Cannot rescue non-graduated token");
        }
        require(token != address(baseAsset), "Cannot rescue base asset");

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Pauses all trading operations
     */
    function pause() external onlyRole(Constants.PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses all trading operations
     */
    function unpause() external onlyRole(Constants.PAUSER_ROLE) {
        _unpause();
    }
}
