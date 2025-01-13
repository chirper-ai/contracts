// file: contracts/token/core/AgentBondingManager.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./AgentToken.sol";
import "../interfaces/IDEXAdapter.sol";
import "../libraries/Constants.sol";

/**
 * @title AgentBondingManager
 * @notice Manages bonding-curve lifecycle and then locks external DEX liquidity by burning LP tokens upon graduation.
 * @dev Key features:
 *  - Launch new tokens (charging a native-token launch fee)
 *  - Handle buy/sell via bonding curve
 *  - On graduation, provides liquidity to external DEXes and burns LP tokens
 *  - Uses AccessControl for role-based permissions
 *  - NonReentrant, Pausable
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
     */
    struct CurveConfig {
        uint256 gradThreshold;     // Threshold for graduation
        address[] dexAdapters;     // DEX adapters for graduation
        uint256[] dexWeights;      // Weights for each DEX (must sum to 100)
    }

    /**
     * @notice Per-token data for the bonding curve
     */
    struct CurveData {
        address token;             // Token address
        address creator;           // Creator for tax distribution
        uint256 tokenReserve;      // Reserve of token
        uint256 assetReserve;      // Reserve of base asset
        bool graduated;            // Whether graduated to DEX
        address[] dexPairs;        // DEX pair addresses after graduation
    }

    // ------------------------------------------------------------------------
    // STATE VARIABLES
    // ------------------------------------------------------------------------

    /// @notice Base asset for all curves (e.g. USDC)
    IERC20 public baseAsset;

    /// @notice Tax vault address for platform share
    address public taxVault;

    /// @notice Buy tax in basis points (100 = 1%)
    uint256 public buyTax;

    /// @notice Sell tax in basis points (100 = 1%)
    uint256 public sellTax;

    /// @notice Default configuration for new curves
    CurveConfig public defaultConfig;

    /// @notice Maps token address to curve data
    mapping(address => CurveData) public curves;

    /// @notice List of all launched tokens
    address[] public tokens;

    // ------------------------------------------------------------------------
    // LAUNCH FEE STATE
    // ------------------------------------------------------------------------

    /// @notice Fee in native chain token required to launch
    uint256 public launchFee;

    /// @notice Address that receives the launch fee
    address public feeRecipient;

    // ------------------------------------------------------------------------
    // EVENTS
    // ------------------------------------------------------------------------

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        uint256 initialTokenReserve,
        uint256 initialAssetReserve
    );

    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 tokenAmount,
        uint256 assetAmount,
        uint256 platformTax,
        uint256 creatorTax
    );

    event TokenGraduated(
        address indexed token,
        address[] dexPairs,
        uint256[] amounts
    );

    event TaxConfigUpdated(
        address indexed taxVault,
        uint256 buyTax,
        uint256 sellTax
    );

    /**
     * @notice Emitted when the launch fee is set
     * @param fee The new launch fee (in native token)
     */
    event LaunchFeeSet(uint256 fee);

    /**
     * @notice Emitted when the fee recipient is changed
     * @param recipient The new fee recipient address
     */
    event FeeRecipientSet(address recipient);

    /**
     * @notice Emitted when a user pays the launch fee
     * @param payer The user who paid the fee
     * @param amount The amount paid in native tokens
     */
    event LaunchFeePaid(address indexed payer, uint256 amount);

    // ------------------------------------------------------------------------
    // CONSTRUCTOR (DISABLED FOR UPGRADEABLE)
    // ------------------------------------------------------------------------

    /**
     * @dev Disables initializers to prevent calling initialize() outside proxy
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    // ------------------------------------------------------------------------
    // INITIALIZER
    // ------------------------------------------------------------------------

    /**
     * @notice Initializes the contract
     * @dev Must only be called once (by proxy's initializer)
     * @param _baseAsset Address of the base asset (e.g., USDC)
     * @param _registry Tax vault (or registry) address
     * @param _platform Address with the PLATFORM_ROLE
     * @param _config Default curve configuration
     */
    function initialize(
        address _baseAsset,
        address _registry,
        address _platform,
        CurveConfig calldata _config
    ) external initializer {
        ErrorLibrary.validateAddress(_baseAsset, "baseAsset");
        ErrorLibrary.validateAddress(_registry, "registry");
        ErrorLibrary.validateAddress(_platform, "platform");
        _validateConfig(_config);

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.UPGRADER_ROLE, msg.sender);
        _grantRole(Constants.TAX_MANAGER_ROLE, msg.sender);
        _grantRole(Constants.PAUSER_ROLE, msg.sender);
        _grantRole(Constants.PLATFORM_ROLE, _platform);

        // Assign state variables
        baseAsset = IERC20(_baseAsset);
        taxVault = _registry;
        defaultConfig = _config;

        // Set default tax rates (e.g. 1% each)
        buyTax = 100;  // 1%
        sellTax = 100; // 1%

        // Initialize fee-related variables (can be changed later by admin)
        launchFee = 0;       // default = 0
        feeRecipient = msg.sender; // default to admin
    }

    // ------------------------------------------------------------------------
    // CONFIGURE LAUNCH FEE
    // ------------------------------------------------------------------------

    /**
     * @notice Sets the launch fee in native tokens
     * @dev Only callable by admin
     * @param _fee Amount of native token required
     */
    function setLaunchFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        launchFee = _fee;
        emit LaunchFeeSet(_fee);
    }

    /**
     * @notice Sets the address that receives the launch fee
     * @dev Only callable by admin
     * @param recipient The new fee recipient
     */
    function setFeeRecipient(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ErrorLibrary.validateAddress(recipient, "recipient");
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    // ------------------------------------------------------------------------
    // TOKEN LAUNCH & BONDING CURVE FUNCTIONS
    // ------------------------------------------------------------------------

    /**
     * @notice Creates a new token with bonding curve (requires a native token fee)
     * @dev This function is payable, so the user can send the native token (e.g. BNB/MATIC/AVAX)
     * @param name Token name
     * @param symbol Token symbol
     * @param platform Platform address for the token
     * @return token Address of the newly launched token
     */
    function launchToken(
        string calldata name,
        string calldata symbol,
        address platform
    )
        external
        payable
        nonReentrant
        whenNotPaused
        returns (address token)
    {
        require(platform != address(0), Constants.ERR_ZERO_ADDRESS);

        // --------------------------------------------------------------------
        // 1. Enforce launch fee in native token
        // --------------------------------------------------------------------
        require(msg.value >= launchFee, "Insufficient launch fee");
        (bool successFee, ) = feeRecipient.call{value: launchFee}("");
        require(successFee, "Fee transfer failed");

        // Refund any excess back to user
        uint256 excess = msg.value - launchFee;
        if (excess > 0) {
            (bool successRefund, ) = msg.sender.call{value: excess}("");
            require(successRefund, "Refund transfer failed");
        }

        emit LaunchFeePaid(msg.sender, launchFee);

        // --------------------------------------------------------------------
        // 2. Create the token (AgentToken)
        // --------------------------------------------------------------------
        AgentToken newToken = new AgentToken();
        newToken.initialize(
            name,
            symbol,
            address(this),  // bondingContract
            taxVault,       // protocol tax vault
            platform        // platform admin
        );

        // 3. Set up initial reserves based on constant K
        uint256 initialTokenReserve = Constants.INITIAL_TOKEN_SUPPLY;
        uint256 initialAssetReserve = Constants.BONDING_K / initialTokenReserve;

        // 4. Transfer initial base asset from user to contract
        baseAsset.safeTransferFrom(msg.sender, address(this), initialAssetReserve);

        // 5. Initialize curve data
        CurveData storage curve = curves[address(newToken)];
        curve.token = address(newToken);
        curve.creator = msg.sender;
        curve.tokenReserve = initialTokenReserve;
        curve.assetReserve = initialAssetReserve;

        tokens.push(address(newToken));

        emit TokenLaunched(
            address(newToken),
            msg.sender,
            name,
            symbol,
            initialTokenReserve,
            initialAssetReserve
        );

        return address(newToken);
    }

    /**
     * @notice Buy tokens from the bonding curve with price impact protection
     * @param token Address of the token to buy
     * @param assetAmount Amount of base asset to spend (includes tax)
     * @return tokenAmount Amount of tokens received
     */
    function buy(
        address token,
        uint256 assetAmount
    ) external nonReentrant whenNotPaused returns (uint256 tokenAmount) {
        require(assetAmount >= Constants.MIN_OPERATION_AMOUNT, Constants.ERR_ZERO_AMOUNT);

        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        require(!curve.graduated, "Token graduated");

        // Calculate total tax
        uint256 totalTaxAmount = (assetAmount * buyTax) / Constants.BASIS_POINTS;

        // Split tax
        uint256 platformTaxAmount = (totalTaxAmount * Constants.PLATFORM_FEE_SHARE) /
            (Constants.PLATFORM_FEE_SHARE + Constants.CREATOR_FEE_SHARE);
        uint256 creatorTaxAmount = totalTaxAmount - platformTaxAmount;

        // Net amount going into the curve
        uint256 netAmount = assetAmount - totalTaxAmount;

        // Transfer entire assetAmount from user to contract
        baseAsset.safeTransferFrom(msg.sender, address(this), assetAmount);

        // Pay out taxes
        if (platformTaxAmount > 0) {
            baseAsset.safeTransfer(taxVault, platformTaxAmount);
        }
        if (creatorTaxAmount > 0) {
            baseAsset.safeTransfer(curve.creator, creatorTaxAmount);
        }

        // Prevent underflow (explicit check)
        uint256 newAssetReserve = curve.assetReserve + netAmount;
        uint256 kOverNewReserve = Constants.BONDING_K / newAssetReserve;
        require(
            kOverNewReserve <= curve.tokenReserve,
            "Insufficient token reserve"
        );

        // Calculate how many tokens the user gets
        tokenAmount = curve.tokenReserve - kOverNewReserve;

        // Update reserves
        curve.assetReserve = newAssetReserve;
        curve.tokenReserve -= tokenAmount;

        // Mint tokens to buyer
        AgentToken(token).mint(msg.sender, tokenAmount);

        emit Trade(
            token,
            msg.sender,
            true,        // isBuy = true
            tokenAmount,
            assetAmount, // total asset spent
            platformTaxAmount,
            creatorTaxAmount
        );

        // Check graduation threshold
        if (curve.assetReserve >= defaultConfig.gradThreshold) {
            _graduate(token);
        }
    }

    /**
     * @notice Sell tokens back to the bonding curve with price impact protection
     * @param token Address of the token to sell
     * @param tokenAmount Amount of tokens to sell
     * @return assetAmount Amount of base asset received
     */
    function sell(
        address token,
        uint256 tokenAmount
    ) external nonReentrant whenNotPaused returns (uint256 assetAmount) {
        require(tokenAmount >= Constants.MIN_OPERATION_AMOUNT, Constants.ERR_ZERO_AMOUNT);

        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        require(!curve.graduated, "Token graduated");

        // Burn tokens from sender
        AgentToken(token).burn(msg.sender, tokenAmount);

        // Prevent underflow (explicit check)
        uint256 newTokenReserve = curve.tokenReserve + tokenAmount;
        uint256 kOverNewReserve = Constants.BONDING_K / newTokenReserve;
        require(
            kOverNewReserve <= curve.assetReserve,
            "Insufficient asset reserve"
        );

        // Calculate how many base assets returned
        uint256 grossAssetAmount = curve.assetReserve - kOverNewReserve;

        // Calculate taxes
        uint256 totalTaxAmount = (grossAssetAmount * sellTax) / Constants.BASIS_POINTS;
        uint256 platformTaxAmount = (totalTaxAmount * Constants.PLATFORM_FEE_SHARE) /
            (Constants.PLATFORM_FEE_SHARE + Constants.CREATOR_FEE_SHARE);
        uint256 creatorTaxAmount = totalTaxAmount - platformTaxAmount;
        uint256 netAmount = grossAssetAmount - totalTaxAmount;

        // Update reserves
        curve.tokenReserve = newTokenReserve;
        curve.assetReserve -= grossAssetAmount;

        // Transfer net assets to user
        baseAsset.safeTransfer(msg.sender, netAmount);

        // Pay out taxes
        if (platformTaxAmount > 0) {
            baseAsset.safeTransfer(taxVault, platformTaxAmount);
        }
        if (creatorTaxAmount > 0) {
            baseAsset.safeTransfer(curve.creator, creatorTaxAmount);
        }

        emit Trade(
            token,
            msg.sender,
            false,           // isBuy = false
            tokenAmount,
            grossAssetAmount,
            platformTaxAmount,
            creatorTaxAmount
        );

        return netAmount;
    }

    // ------------------------------------------------------------------------
    // GRADUATION LOGIC (with LP burn)
    // ------------------------------------------------------------------------

    /**
     * @notice Internal function to graduate a token to DEX trading
     * @dev Splits liquidity across multiple DEXes based on weights, then burns LP tokens
     * @param token Token to graduate
     */
    function _graduate(address token) internal nonReentrant {
        CurveData storage curve = curves[token];
        require(!curve.graduated, "Already graduated");

        // STEP 1: Update state FIRST (Checks-Effects-Interactions)
        curve.graduated = true;
        
        uint256[] memory amounts = new uint256[](defaultConfig.dexAdapters.length);
        address[] memory pairs = new address[](defaultConfig.dexAdapters.length);
        curve.dexPairs = pairs;  // Set empty array first

        // Mark token's own graduation flag early
        AgentToken(token).graduate();

        // Calculate total liquidity to be distributed
        uint256 totalAssets = curve.assetReserve;
        uint256 totalTokens = curve.tokenReserve;

        // STEP 2: External interactions AFTER state changes
        for (uint256 i = 0; i < defaultConfig.dexAdapters.length; i++) {
            IDEXAdapter adapter = IDEXAdapter(defaultConfig.dexAdapters[i]);

            // Calculate weighted split
            uint256 assetAmount = (totalAssets * defaultConfig.dexWeights[i]) / 100;
            uint256 tokenAmount = (totalTokens * defaultConfig.dexWeights[i]) / 100;

            // Approve exact amounts instead of unlimited
            IERC20(token).safeIncreaseAllowance(adapter.getRouterAddress(), tokenAmount);
            baseAsset.safeIncreaseAllowance(adapter.getRouterAddress(), assetAmount);

            // Add liquidity with strict slippage protection
            (uint256 amountA, uint256 amountB, uint256 liquidity) = adapter.addLiquidity(
                IDEXAdapter.LiquidityParams({
                    tokenA: token,
                    tokenB: address(baseAsset),
                    amountA: tokenAmount,
                    amountB: assetAmount,
                    minAmountA: (tokenAmount * Constants.MAX_GRADUATION_SLIPPAGE) /
                        Constants.BASIS_POINTS,
                    minAmountB: (assetAmount * Constants.MAX_GRADUATION_SLIPPAGE) /
                        Constants.BASIS_POINTS,
                    to: address(this),
                    deadline: block.timestamp + Constants.GRADUATION_TIMEOUT
                })
            );

            // Verify minimum amounts were received
            require(
                amountA >= (tokenAmount * Constants.MAX_GRADUATION_SLIPPAGE) / Constants.BASIS_POINTS,
                "Insufficient tokenA received"
            );
            require(
                amountB >= (assetAmount * Constants.MAX_GRADUATION_SLIPPAGE) / Constants.BASIS_POINTS,
                "Insufficient tokenB received"
            );

            // Get and store DEX pair address
            address pairAddr = adapter.getPair(token, address(baseAsset));
            pairs[i] = pairAddr;
            amounts[i] = amountB;

            // Clear approvals for safety
            IERC20(token).safeDecreaseAllowance(adapter.getRouterAddress(), tokenAmount);
            baseAsset.safeDecreaseAllowance(adapter.getRouterAddress(), assetAmount);

            // Handle LP tokens using SafeERC20
            if (liquidity > 0) {
                uint256 lpBalance = IERC20(pairAddr).balanceOf(address(this));
                if (lpBalance > 0) {
                    // Use safeTransfer instead of transfer
                    IERC20(pairAddr).safeTransfer(
                        0x000000000000000000000000000000000000dEaD,
                        lpBalance
                    );
                }
            }
        }

        // Update final array of DEX pairs
        curve.dexPairs = pairs;

        emit TokenGraduated(token, pairs, amounts);
    }

    // ------------------------------------------------------------------------
    // ADMIN / TAX CONFIG
    // ------------------------------------------------------------------------

    /**
     * @notice Updates tax configuration (tax vault and rates)
     * @param registry New tax vault address
     * @param newBuyTax New buy tax in basis points
     * @param newSellTax New sell tax in basis points
     */
    function updateTaxConfig(
        address registry,
        uint256 newBuyTax,
        uint256 newSellTax
    ) external onlyRole(Constants.TAX_MANAGER_ROLE) {
        require(registry != address(0), Constants.ERR_ZERO_ADDRESS);
        require(newBuyTax <= Constants.MAX_TAX_RATE, Constants.ERR_TAX_TOO_HIGH);
        require(newSellTax <= Constants.MAX_TAX_RATE, Constants.ERR_TAX_TOO_HIGH);

        taxVault = registry;
        buyTax = newBuyTax;
        sellTax = newSellTax;

        emit TaxConfigUpdated(registry, newBuyTax, newSellTax);
    }

    /**
     * @notice Updates the default curve configuration
     * @param config New configuration
     */
    function setDefaultConfig(CurveConfig calldata config)
        external
        onlyRole(Constants.TAX_MANAGER_ROLE)
    {
        _validateConfig(config);
        defaultConfig = config;
    }

    // ------------------------------------------------------------------------
    // VIEWS
    // ------------------------------------------------------------------------

    /**
     * @notice Returns current price for a token, scaled by 1e18
     */
    function getPrice(address token) external view returns (uint256) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");

        if (curve.assetReserve == 0) {
            return 0;
        }
        return (curve.tokenReserve * 1e18) / curve.assetReserve;
    }

    /**
     * @notice Returns buy price for a given asset amount (hypothetical, read-only)
     */
    function getBuyPrice(
        address token,
        uint256 assetAmount
    ) external view returns (uint256 tokenAmount) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");

        uint256 totalTaxAmount = (assetAmount * buyTax) / Constants.BASIS_POINTS;
        uint256 netAmount = assetAmount - totalTaxAmount;
        uint256 newAssetReserve = curve.assetReserve + netAmount;
        if (newAssetReserve == 0) {
            return curve.tokenReserve;
        }

        uint256 kOverNew = Constants.BONDING_K / newAssetReserve;
        if (kOverNew > curve.tokenReserve) {
            return 0; // would underflow in actual buy
        }
        return curve.tokenReserve - kOverNew;
    }

    /**
     * @notice Returns sell price for a given token amount (hypothetical, read-only)
     */
    function getSellPrice(
        address token,
        uint256 tokenAmount
    ) external view returns (uint256 assetAmount) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");

        uint256 newTokenReserve = curve.tokenReserve + tokenAmount;
        if (newTokenReserve == 0) {
            return 0;
        }

        uint256 kOverNew = Constants.BONDING_K / newTokenReserve;
        if (kOverNew > curve.assetReserve) {
            return 0; // would underflow in actual sell
        }

        uint256 grossAmount = curve.assetReserve - kOverNew;
        uint256 totalTaxAmount = (grossAmount * sellTax) / Constants.BASIS_POINTS;
        return grossAmount - totalTaxAmount;
    }

    /**
     * @notice Gets reserve values for a token
     */
    function getReserves(
        address token
    ) external view returns (uint256 tokenReserve, uint256 assetReserve) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        return (curve.tokenReserve, curve.assetReserve);
    }

    /**
     * @notice Gets expected platform/creator tax splits for a given amount
     */
    function getTaxSplit(
        bool taxOnBuy,
        uint256 amount
    ) public view returns (uint256 platformTax, uint256 creatorTax) {
        uint256 totalTax = (amount * (taxOnBuy ? buyTax : sellTax)) /
            Constants.BASIS_POINTS;
        platformTax = (totalTax * Constants.PLATFORM_FEE_SHARE) /
            (Constants.PLATFORM_FEE_SHARE + Constants.CREATOR_FEE_SHARE);
        creatorTax = totalTax - platformTax;
    }

    // ------------------------------------------------------------------------
    // EMERGENCY / ADMIN
    // ------------------------------------------------------------------------

    /**
     * @notice Emergency rescue of tokens sent to contract.
     * @dev Disallows rescuing the base asset or a non-graduated curve token.
     */
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), Constants.ERR_ZERO_ADDRESS);
        require(amount > 0, Constants.ERR_ZERO_AMOUNT);

        // If this token is part of a curve
        if (curves[token].token == token) {
            // If it has already graduated, revert
            require(!curves[token].graduated, "Cannot rescue graduated token");
            // Also disallow rescuing the curve token itself if not graduated
            revert("Cannot rescue a curve token that has not graduated");
        }

        // Disallow rescuing the base asset from the contract
        require(token != address(baseAsset), "Cannot rescue base asset");

        // Otherwise, rescue is allowed
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Pauses all trading operations (buy/sell)
     */
    function pause() external onlyRole(Constants.PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses all trading operations (buy/sell)
     */
    function unpause() external onlyRole(Constants.PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Returns total number of tokens launched
     */
    function totalTokens() external view returns (uint256) {
        return tokens.length;
    }

    /**
     * @notice Returns graduation status of a token
     */
    function isGraduated(address token) external view returns (bool) {
        return curves[token].graduated;
    }

    /**
     * @notice Returns the DEX pairs for a graduated token
     */
    function getDexPairs(address token) external view returns (address[] memory) {
        require(curves[token].graduated, "Token not graduated");
        return curves[token].dexPairs;
    }

    // ------------------------------------------------------------------------
    // INTERNAL UTILITIES
    // ------------------------------------------------------------------------

    /**
     * @notice Validates the provided curve configuration
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
