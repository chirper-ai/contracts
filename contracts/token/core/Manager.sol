// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// openzeppelin
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// uniswap v2
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

// uniswap v3 simplified
import "../interfaces/UniswapV3/IUniswapV3Pool.sol";
import "../interfaces/UniswapV3/IUniswapV3Factory.sol";
import "../interfaces/UniswapV3/INonfungiblePositionManager.sol";

// velodrome simplified
import "../interfaces/Velodrome/IVelodromeRouter.sol";
import "../interfaces/Velodrome/IVelodromeFactory.sol";

// locals
import "../interfaces/IFactory.sol";
import "../interfaces/IRouter.sol";
import "./Token.sol";

// interfaces
import "../interfaces/IBondingPair.sol";

/**
 * @title Manager
 * @dev Manages the lifecycle of AI agent tokens, including creation, bonding curve trading, and graduation
 * This contract coordinates with Factory for tax management and Router for trading operations
 */
contract Manager is
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enum to specify the type of DEX router
    enum RouterType {
        UniswapV2,
        UniswapV3,
        Velodrome
    }

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Bonding curve constant used in price calculations
    uint256 public K;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Factory contract for creating token pairs
    IFactory public factory;

    /// @notice Router contract for token trading operations
    IRouter public router;

    /// @notice Initial token supply for new agent tokens
    uint256 public initialSupply;

    /// @notice Rate used in asset requirement calculations
    uint64 public assetRate;

    /// @notice Percentage threshold required for graduation eligibility
    uint64 public gradThreshold;

    /*//////////////////////////////////////////////////////////////
                                  STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Router information for token graduation
    struct DexRouter {
        address routerAddress; // Address of the DEX router
        uint24 feeAmount;     // Fee amount for the DEX router
        uint24 weight;        // Weight for liquidity distribution (1-100)
        RouterType routerType; // Type of DEX router (UniswapV2 or UniswapV3)
    }

    /**
     * @notice Comprehensive metrics tracking for an agent token
     * @param tokenAddr Address of the token contract
     * @param name Full token name
     * @param ticker Trading symbol
     * @param totalSupply Total token supply
     * @param circSupply Tokens in circulation (not in bonding pair)
     * @param price Current price in VANA (1e18 decimals)
     * @param cap Market cap (circulating * price)
     * @param fdv Fully diluted value (totalSupply * price)
     * @param tvl Total value locked in bonding pair
     * @param lastUpdate Last update timestamp
     */
    struct TokenMetrics {
        address tokenAddr;         // Token contract address
        string name;               // Full token name
        string ticker;             // Trading symbol
        uint256 totalSupply;       // Total token supply
        uint256 circSupply;        // Tokens in circulation (not in bonding pair)
        uint256 price;             // Current price in VANA (1e18 decimals)
        uint256 cap;               // Market cap (circulating * price)
        uint256 fdv;               // Fully diluted value (totalSupply * price)
        uint256 tvl;               // Total value locked in bonding pair
        uint256 lastUpdate;        // Last update timestamp
    }

    /**
     * @notice Comprehensive data structure for an AI agent token
     * @param creator Address of the token creator
     * @param token Address of the token contract
     * @param intention Purpose of the token
     * @param url Reference URL for the token
     * @param metrics Comprehensive token metrics
     * @param hasGraduated Whether the token has graduated to DEXes
     * @param bondingPair Address of the bonding curve pair
     * @param dexRouters Array of DEX routers and their weights
     * @param dexPools Array of DEX pairs created during graduation
     */
    struct TokenData {
        address creator;
        address token;
        string intention;
        string url;
        TokenMetrics metrics;
        bool hasGraduated;
        address bondingPair;
        DexRouter[] dexRouters;
        address[] dexPools;
    }

    /*//////////////////////////////////////////////////////////////
                                MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Mapping from token address to its complete data
    mapping(address => TokenData) public agentTokens;

    /// @notice List of all agent token addresses
    address[] public agentTokenList;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new agent token is created
    event Launched(address indexed token, address indexed pair, uint256 index);

    /// @notice Emitted when an agent token graduates to Uniswap
    event Graduated(address indexed token);

    /// @notice Emitted when token metrics are updated
    event MetricsUpdated(
        address indexed token,
        uint256 totalSupply,
        uint256 circSupply,
        uint256 price,
        uint256 cap,
        uint256 fdv
    );

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
     * @notice Initializes the Manager contract with required parameters
     * @param factory_ Address of the Factory contract
     * @param router_ Address of the Router contract
     * @param initSupply_ Initial token supply
     * @param kConstant_ Bonding curve constant
     * @param assetRate_ Asset rate for calculations
     * @param gradThreshold_ Graduation threshold percentage
     */
    function initialize(
        address factory_,
        address router_,
        uint256 initSupply_,
        uint256 kConstant_,
        uint64 assetRate_,
        uint64 gradThreshold_
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        
        require(factory_ != address(0), "Invalid factory");
        require(router_ != address(0), "Invalid router");

        K = kConstant_;
        factory = IFactory(factory_);
        router = IRouter(router_);
        initialSupply = initSupply_;
        assetRate = assetRate_;
        gradThreshold = gradThreshold_;
    }

    /*//////////////////////////////////////////////////////////////
                         CORE TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates and initializes a new AI agent token with bonding curve trading
     * @dev This is the core function for launching new agent tokens. It:
     * 1. Validates inputs and collects launch tax
     * 2. Creates new Token contract
     * 3. Creates bonding pair via Factory
     * 4. Sets up initial liquidity with bonding curve parameters
     * 5. Makes initial token purchase for launcher
     * 6. Updates and validates metrics
     *
     * @param name_ Full name of the token
     * @param ticker_ Trading symbol for the token
     * @param intention_ Purpose/mission of the token
     * @param url_ Reference URL for the token
     * @param initBuy_ Amount of asset tokens (VANA) to spend on launch
     * @param dexRouters_ Array of DEX routers and weights for future graduation
     * @return token Address of the newly created token
     * @return pair Address of the bonding pair
     * @return index Index in the agentTokenList
     */
    function launch(
        string calldata name_,
        string calldata ticker_,
        string calldata intention_,
        string calldata url_,
        uint256 initBuy_,
        DexRouter[] calldata dexRouters_
    ) external nonReentrant returns (address token, address pair, uint256 index) {
        // Validate DEX router configuration
        require(dexRouters_.length > 0, "Must provide at least one DEX router");
        uint24 totalWeight;
        for(uint i = 0; i < dexRouters_.length; i++) {
            require(dexRouters_[i].routerAddress != address(0), "Invalid router address");
            require(dexRouters_[i].weight > 0 && dexRouters_[i].weight <= 100_000, "Invalid weight");
            totalWeight += dexRouters_[i].weight;
        }
        require(totalWeight == 100_000, "Weights must sum to 100_000");

        // Check asset token balance and collect launch tax
        address assetToken_ = router.assetToken();
        require(
            IERC20(assetToken_).balanceOf(msg.sender) >= initBuy_,
            "Insufficient funds"
        );

        uint256 launchTax = (initBuy_ * factory.launchTax()) / 100_000;
        uint256 initialPurchase = initBuy_ - launchTax;
        
        // Transfer launch tax to tax vault
        IERC20(assetToken_).safeTransferFrom(msg.sender, factory.taxVault(), launchTax);
        IERC20(assetToken_).safeTransferFrom(
            msg.sender,
            address(this),
            initialPurchase
        );

        // Create token contract
        Token actualToken = new Token(
            name_, 
            ticker_,
            initialSupply,
            address(this),
            factory.buyTax(),
            factory.sellTax(),
            factory.taxVault()
        );

        // Create bonding pair
        address newBondingPair = factory.createPair(address(actualToken), assetToken_);
        uint256 totalSupply = actualToken.totalSupply();

        // force approve
        IERC20(address(actualToken)).forceApprove(address(router), totalSupply);

        // Calculate initial liquidity
        uint256 k = K * 1 ether;  // Scale k to 18 decimals
        uint256 initialLiquidity = (k * 1 ether) / totalSupply;  // Calculate initial VANA liquidity

        // Add initial liquidity to bonding pair
        router.addInitialLiquidity(address(actualToken), totalSupply, initialLiquidity);

        // Get initial price using router's getAmountsOut
        uint256 initialPrice = router.getAmountsOut(address(actualToken), address(0), 1e18);

        // Initialize token metrics
        TokenMetrics memory metrics = TokenMetrics({
            tokenAddr: address(actualToken),
            name: name_,
            ticker: ticker_,
            totalSupply: totalSupply,
            circSupply: 0,  // Initially 0 as all tokens in bonding pair
            price: initialPrice,
            cap: 0,  // Initially 0 as no circulating supply
            fdv: (totalSupply * initialPrice) / 1e18,
            tvl: initialPurchase * 2,  // Double the VANA liquidity
            lastUpdate: block.timestamp
        });

        // Store token data
        TokenData memory localToken = TokenData({
            creator: msg.sender,
            token: address(actualToken),
            bondingPair: newBondingPair,
            intention: intention_,
            url: url_,
            metrics: metrics,
            hasGraduated: false,
            dexRouters: dexRouters_,
            dexPools: new address[](0)
        });

        agentTokens[address(actualToken)] = localToken;
        agentTokenList.push(address(actualToken));
        uint256 tokenIndex = agentTokenList.length;

        emit Launched(address(actualToken), newBondingPair, tokenIndex);

        // Execute initial token purchase
        IERC20(assetToken_).forceApprove(address(router), initialPurchase);
        router.buy(initialPurchase, address(actualToken), address(this));
        
        // Validate received tokens
        uint256 receivedTokens = actualToken.balanceOf(address(this));
        
        // Ensure initial purchase doesn't exceed 20% of supply
        require(
            receivedTokens <= (totalSupply * 20_000) / 100_000,
            "Initial purchase exceeds 20% of supply"
        );
        
        // Transfer tokens to launcher
        actualToken.transfer(msg.sender, receivedTokens);

        // Update metrics after initial purchase
        (uint256 reserveToken,) = IBondingPair(newBondingPair).getReserves();
        _updateMetrics(address(actualToken), reserveToken);

        return (address(actualToken), newBondingPair, tokenIndex);
    }

    /**
     * @notice Executes a buy order for agent tokens
     * @param amountIn_ Amount of asset tokens to spend
     * @param tokenAddress_ Address of token to buy
     * @return success Whether the operation succeeded
     */
    function buy(
        uint256 amountIn_,
        address tokenAddress_
    ) external payable returns (bool) {
        require(!agentTokens[tokenAddress_].hasGraduated, "Trading not active");

        address pairAddress = factory.getPair(
            tokenAddress_,
            router.assetToken()
        );

        IBondingPair pair = IBondingPair(pairAddress);
        (uint256 reserveA,) = pair.getReserves();

        (,uint256 amount0Out) = router.buy(
            amountIn_,
            tokenAddress_,
            msg.sender
        );

        uint256 newReserveA = reserveA - amount0Out;

        _updateMetrics(
            tokenAddress_,
            newReserveA
        );

        uint256 totalSupply = IERC20(tokenAddress_).totalSupply();
        require(totalSupply > 0, "Invalid total supply");

        uint256 reservePercentage = (newReserveA * 100_000) / totalSupply;
        
        if (reservePercentage <= gradThreshold) {
            _graduate(tokenAddress_);
        }

        return true;
    }

    /**
     * @notice Executes a sell order for agent tokens
     * @param amountIn_ Amount of tokens to sell
     * @param tokenAddress_ Address of token to sell
     * @return success Whether the operation succeeded
     */
    function sell(
        uint256 amountIn_,
        address tokenAddress_
    ) external returns (bool) {
        require(!agentTokens[tokenAddress_].hasGraduated, "Trading not active");

        address pairAddress = factory.getPair(
            tokenAddress_,
            router.assetToken()
        );

        IBondingPair pair = IBondingPair(pairAddress);
        (uint256 reserveA,) = pair.getReserves();
        
        (uint256 amount0In,) = router.sell(
            amountIn_,
            tokenAddress_,
            msg.sender
        );

        _updateMetrics(
            tokenAddress_,
            reserveA + amount0In
        );

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates token metrics after a trade or during launch
     * @dev Uses router's getAmountsOut for accurate price calculation
     * @param tokenAddress_ Address of the token being updated
     * @param newReserveToken_ Current token balance in bonding pair
     */
    function _updateMetrics(
        address tokenAddress_,
        uint256 newReserveToken_
    ) private {
        Token token = Token(tokenAddress_);
        TokenData storage tokenData = agentTokens[tokenAddress_];
        
        // Get total supply from token contract
        uint256 totalSupply = Token(tokenAddress_).totalSupply();
        
        // Get locked/non-circulating balances
        uint256 bondingReserves = token.balanceOf(tokenData.bondingPair);
        uint256 deadBalance = token.balanceOf(address(0));  // Burned tokens
        
        // Calculate circulating supply (total - bonding pair balance)
        uint256 circSupply = totalSupply - bondingReserves - deadBalance;
        
        // Calculate price using router's getAmountsOut
        // Get price for 1 token (1e18 units) to maintain precision
        uint256 price;
        if (newReserveToken_ > 0) {
            price = router.getAmountsOut(tokenAddress_, address(0), 1e18);
        } else {
            price = 0;
        }
        
        // Calculate market metrics using price with 1e18 precision
        uint256 cap = (circSupply * price) / 1e18;
        uint256 fdv = (totalSupply * price) / 1e18;
        uint256 tvl = IERC20(router.assetToken()).balanceOf(tokenData.bondingPair) * 2;
        
        // Update metrics
        tokenData.metrics.circSupply = circSupply;
        tokenData.metrics.price = price;
        tokenData.metrics.cap = cap;
        tokenData.metrics.fdv = fdv;
        tokenData.metrics.tvl = tvl;
        tokenData.metrics.lastUpdate = block.timestamp;
        
        emit MetricsUpdated(
            tokenAddress_,
            totalSupply,
            circSupply,
            price,
            cap,
            fdv
        );
    }

    /**
     * @notice Internal function to handle token graduation to DEXes
     * @param tokenAddress_ Address of token to graduate
     */
    function _graduate(address tokenAddress_) private {
        TokenData storage token = agentTokens[tokenAddress_];
        require(!token.hasGraduated, "Invalid graduation state");

        // Extract liquidity from bonding curve
        (uint256 tokenBalance, uint256 assetBalance) = _extractBondingCurveLiquidity(tokenAddress_);
        
        // Deploy to DEXes and store the pairs
        address[] memory newPairs = _deployToDexes(
            tokenAddress_,
            token.dexRouters,
            tokenBalance,
            assetBalance
        );

        // Update token data with new pairs
        token.dexPools = newPairs;
        token.hasGraduated = true;

        emit Graduated(tokenAddress_);
    }

    /**
     * @notice Extracts liquidity from the bonding curve pair
     * @param tokenAddress_ Address of the token
     * @return tokenBalance Amount of tokens extracted
     * @return assetBalance Amount of asset tokens extracted
     */
    function _extractBondingCurveLiquidity(
        address tokenAddress_
    ) private returns (uint256 tokenBalance, uint256 assetBalance) {
        TokenData storage token = agentTokens[tokenAddress_];
        address assetTokenAddr = router.assetToken();

        IBondingPair pair = IBondingPair(token.bondingPair);
        tokenBalance = pair.balance();
        assetBalance = pair.assetBalance();
        require(tokenBalance > 0 && assetBalance > 0, "No liquidity to graduate");

        // Note: This now just extracts liquidity, graduation happens later
        router.graduate(tokenAddress_);

        require(
            IERC20(tokenAddress_).balanceOf(address(this)) >= tokenBalance &&
            IERC20(assetTokenAddr).balanceOf(address(this)) >= assetBalance,
            "Failed to receive tokens"
        );

        return (tokenBalance, assetBalance);
    }

    /**
     * @notice Deploys liquidity to multiple DEXes according to weights
     * @param tokenAddress_ Address of the token
     * @param dexRouters_ Array of DEX routers and their weights
     * @param totalTokens_ Total tokens to distribute
     * @param totalAssets_ Total asset tokens to distribute
     * @return pairs Array of created DEX pairs
     */
    function _deployToDexes(
        address tokenAddress_,
        DexRouter[] memory dexRouters_,
        uint256 totalTokens_,
        uint256 totalAssets_
    ) private returns (address[] memory pairs) {
        uint256 length = dexRouters_.length;
        address[] memory newPairs = new address[](length);

        uint256 denominator = 100_000;  // Reduce repeated division operations

        for (uint256 i = 0; i < length; ++i) {
            DexRouter memory dexRouter = dexRouters_[i];  // Cache the struct in memory

            uint256 tokenAmount = (totalTokens_ * dexRouter.weight) / denominator;
            uint256 assetAmount = (totalAssets_ * dexRouter.weight) / denominator;

            if (dexRouter.routerType == RouterType.UniswapV2) {
                newPairs[i] = _deployUniV2(tokenAddress_, dexRouter.routerAddress, tokenAmount, assetAmount);
            } else if (dexRouter.routerType == RouterType.UniswapV3) {
                newPairs[i] = _deployUniV3(tokenAddress_, dexRouter.routerAddress, tokenAmount, assetAmount, dexRouter.feeAmount);
            } else {
                // Assuming Velodrome is the only remaining option
                newPairs[i] = _deployVelo(tokenAddress_, dexRouter.routerAddress, tokenAmount, assetAmount);
            }
        }

        Token(tokenAddress_).graduate(newPairs);
        return newPairs;
    }

    /**
     * @notice Deploys liquidity to a Uniswap V2 pool
     * @param tokenAddress_ Address of the token
     * @param routerAddress_ Address of the Uniswap V2 router
     * @param tokenAmount_ Amount of tokens to provide as liquidity
     * @param assetAmount_ Amount of asset tokens to provide as liquidity
     * @return dexPool Address of the created or existing DEX pool
     */
    function _deployUniV2(
        address tokenAddress_,
        address routerAddress_,
        uint256 tokenAmount_,
        uint256 assetAmount_
    ) private returns (address dexPool) {
        address assetTokenAddr = router.assetToken();
        IUniswapV2Router02 dexRouter = IUniswapV2Router02(routerAddress_);
        IUniswapV2Factory dexFactory = IUniswapV2Factory(dexRouter.factory());

        IERC20 token = IERC20(tokenAddress_);
        IERC20 assetToken = IERC20(assetTokenAddr);

        // Approve tokens for router in a single step
        token.forceApprove(address(dexRouter), tokenAmount_);
        assetToken.forceApprove(address(dexRouter), assetAmount_);

        // Check if the pair exists, if not create it
        dexPool = dexFactory.getPair(tokenAddress_, assetTokenAddr);
        if (dexPool == address(0)) {
            dexPool = dexFactory.createPair(tokenAddress_, assetTokenAddr);
        }

        // Precompute slippage tolerance values (95% of provided amount)
        uint256 minTokenAmount = (tokenAmount_ * 95) / 100;
        uint256 minAssetAmount = (assetAmount_ * 95) / 100;

        // Add liquidity with calculated minimums
        dexRouter.addLiquidity(
            tokenAddress_,
            assetTokenAddr,
            tokenAmount_,
            assetAmount_,
            minTokenAmount,
            minAssetAmount,
            address(0),
            block.timestamp + 3600
        );

        return dexPool;
    }


    /**
     * @notice Deploys liquidity to a Uniswap V3 pool with full range coverage
     * @dev This function handles both pool creation and initial liquidity provision.
     * It ensures full-range market making (-887220 to +887220 ticks) while properly
     * setting the initial pool price based on the token ratio.
     * 
     * Key steps:
     * 1. Sort tokens (V3 requires token0 < token1)
     * 2. Create pool if it doesn't exist
     * 3. Initialize pool with correct price if new
     * 4. Create full-range position
     *
     * Technical notes:
     * - sqrtPriceX96 is in Q64.96 format
     * - Assumes amounts provided are already correctly proportioned
     * - Sets minimum amounts to 1 to allow maximum slippage
     *
     * @param tokenAddress_ Address of the token being graduated
     * @param routerAddress_ Address of the Uniswap V3 NonfungiblePositionManager
     * @param tokenAmount_ Amount of tokens to provide as liquidity
     * @param assetAmount_ Amount of asset tokens to provide as liquidity
     * @param feeAmount_ Fee tier for the pool (500 = 0.05%, 3000 = 0.3%, 10000 = 1%)
     * @return dexPool Address of the created/existing V3 pool
     */
    function _deployUniV3(
        address tokenAddress_,
        address routerAddress_,
        uint256 tokenAmount_,
        uint256 assetAmount_,
        uint24 feeAmount_
    ) private returns (address dexPool) {
        address assetTokenAddr = router.assetToken();
        
        // Sort tokens according to V3 requirements (token0 < token1)
        bool isTokenFirst = tokenAddress_ < assetTokenAddr;
        (address token0, address token1) = isTokenFirst 
            ? (tokenAddress_, assetTokenAddr) 
            : (assetTokenAddr, tokenAddress_);
            
        (uint256 amount0, uint256 amount1) = isTokenFirst
            ? (tokenAmount_, assetAmount_)
            : (assetAmount_, tokenAmount_);

        // Get position manager and factory
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(routerAddress_);
        IUniswapV3Factory positionFactory = IUniswapV3Factory(positionManager.factory());

        // Get or create pool
        dexPool = positionFactory.getPool(token0, token1, feeAmount_);
        if (dexPool == address(0)) {
            dexPool = positionFactory.createPool(token0, token1, feeAmount_);

            // Calculate initial sqrt price and initialize pool
            uint256 price = (amount1 * 1e18) / amount0;
            uint256 sqrtPrice = Math.sqrt(price * 1e18);
            uint160 sqrtPriceX96 = uint160((sqrtPrice * (2**96)) / 1e18);
            IUniswapV3Pool(dexPool).initialize(sqrtPriceX96);
        }

        // Approve position manager to spend tokens
        IERC20(token0).forceApprove(address(positionManager), amount0);
        IERC20(token1).forceApprove(address(positionManager), amount1);

        // Calculate full range ticks
        int24 tickSpacing = IUniswapV3Pool(dexPool).tickSpacing();
        int24 tickLower = (-887272 / tickSpacing) * tickSpacing;
        int24 tickUpper = (887272 / tickSpacing) * tickSpacing;

        // Create the full range position
        positionManager.mint(INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: feeAmount_,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 3600
        }));

        return dexPool;
    }

    /**
     * @notice Deploys liquidity to a Velodrome pool
     * @dev Velodrome is similar to Uniswap V2 but with stable/volatile pool options
     * We default to volatile pools for AI tokens
     * @param tokenAddress_ Address of the token
     * @param routerAddress_ Address of the Velodrome router
     * @param tokenAmount_ Amount of tokens to provide as liquidity
     * @param assetAmount_ Amount of asset tokens to provide as liquidity
     * @return dexPool Address of the created or existing Velodrome pool
     */
    function _deployVelo(
        address tokenAddress_,
        address routerAddress_,
        uint256 tokenAmount_,
        uint256 assetAmount_
    ) private returns (address dexPool) {
        address assetTokenAddr = router.assetToken();
        IVelodromeRouter veloRouter = IVelodromeRouter(routerAddress_);
        
        // Approve Velodrome router to spend tokens
        IERC20(tokenAddress_).forceApprove(address(veloRouter), tokenAmount_);
        IERC20(assetTokenAddr).forceApprove(address(veloRouter), assetAmount_);

        // Get factory and check for existing pair
        address veloFactory = veloRouter.factory();
        bool isStable = false; // We use volatile pools for AI tokens
        
        dexPool = IVelodromeFactory(veloFactory).getPair(
            tokenAddress_,
            assetTokenAddr,
            isStable
        );

        // Create pair if it doesn't exist
        if (dexPool == address(0)) {
            dexPool = IVelodromeFactory(veloFactory).createPair(
                tokenAddress_,
                assetTokenAddr,
                isStable
            );
        }

        // Add liquidity to the pool
        veloRouter.addLiquidity(
            tokenAddress_,
            assetTokenAddr,
            isStable,
            tokenAmount_,
            assetAmount_,
            tokenAmount_ * 95 / 100,  // 5% slippage tolerance
            assetAmount_ * 95 / 100,
            address(0),
            block.timestamp + 3600
        );
            

        return dexPool;
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the initial supply for new tokens
     * @param newSupply_ New initial supply value
     */
    function setInitialSupply(uint256 newSupply_) external onlyOwner {
        initialSupply = newSupply_;
    }

    /**
     * @notice Updates the graduation threshold percentage
     * @param gradThreshold_ New threshold percentage value
     */
    function setGradThreshold(uint64 gradThreshold_) external onlyOwner {
        gradThreshold = gradThreshold_;
    }

    /**
     * @notice Updates the asset rate used in calculations
     * @param newRate_ New asset rate value
     */
    function setAssetRate(uint64 newRate_) external onlyOwner {
        require(newRate_ > 0, "Rate must be positive");
        assetRate = newRate_;
    }
    
    /**
     * @notice gets the list of dex pools for a token
     * @param token address of the token
     */
    function getDexPools(address token) external view returns (address[] memory) {
        return agentTokens[token].dexPools;
    }
}