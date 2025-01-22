// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// openzeppelin
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// locals
import "./Token.sol";
import "../interfaces/IRouter.sol";
import "../interfaces/IFactory.sol";
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
        IRouter.DexRouter[] dexRouters;
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
        IRouter.DexRouter[] calldata dexRouters_
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
     * @notice Executes a buy order for agent tokens with automated graduation checking
     * @dev This function handles the entire buy process including:
     *      1. Token purchase through router
     *      2. Reserve metrics update
     *      3. Graduation threshold checking
     *      4. Automatic graduation triggering if threshold is met
     * 
     * The function will revert if:
     * - The token has already graduated
     * - The token's total supply is 0
     * - The router's buy operation fails
     * 
     * @param amountIn_ Amount of asset tokens to spend on the purchase
     * @param tokenAddress_ Address of the agent token to buy
     * @return success True if the buy operation and all subsequent operations succeed
     * 
     * @custom:metrics Updates token metrics via _updateMetrics()
     * @custom:graduation May trigger token graduation via _graduate() if reserve ratio hits threshold
     * @custom:requires
     * - Token must not be graduated
     * - Valid pair must exist in factory
     * - Token must have non-zero total supply
     * - Router must have sufficient approval for asset tokens
     * - Caller must have sufficient asset tokens
     */
    function buy(
        uint256 amountIn_,
        address tokenAddress_
    ) external payable returns (bool) {
        // Check if token is eligible for trading by verifying it hasn't graduated
        // This prevents trading after graduation when tokens move to external DEXes
        require(!agentTokens[tokenAddress_].hasGraduated, "Trading not active");

        // Get the bonding pair address from the factory
        // This pair manages the token/asset liquidity pool
        address pairAddress = factory.getPair(
            tokenAddress_,
            router.assetToken()
        );

        // Load the bonding pair contract and get current reserves
        // reserveA represents the agent token balance
        // We ignore reserveB (asset token) since we only need agent token reserves
        IBondingPair pair = IBondingPair(pairAddress);
        (uint256 reserveA,) = pair.getReserves();

        // Execute the buy through the router
        // amount0Out represents the amount of agent tokens the user receives
        // First return value (amountIn) is ignored since we already have it
        (,uint256 amount0Out) = router.buy(
            amountIn_,
            tokenAddress_,
            msg.sender
        );

        // Calculate new reserve after tokens are removed from the pool
        // This represents remaining agent token liquidity after the trade
        uint256 newReserveA = reserveA - amount0Out;

        // Update metrics with new reserve values
        // This tracks various token metrics for analysis and graduation criteria
        _updateMetrics(
            tokenAddress_,
            newReserveA
        );

        // Get total token supply for calculating reserve percentage
        // This is used to determine if graduation threshold is met
        uint256 totalSupply = IERC20(tokenAddress_).totalSupply();
        require(totalSupply > 0, "Invalid total supply");

        // Calculate what percentage of total supply remains in reserves
        // Multiply by 100_000 for precision (100% = 100_000)
        // This ratio determines if token is ready for graduation
        uint256 reservePercentage = (newReserveA * 100_000) / totalSupply;
        
        // If reserve percentage falls below graduation threshold
        // trigger graduation process to move token to external DEXes
        if (reservePercentage <= gradThreshold) {
            _graduate(tokenAddress_);
        }

        return true;
    }

    /**
     * @notice Executes a sell order for agent tokens
     * @dev This function handles the sell process including:
     *      1. Token sale through router
     *      2. Reserve metrics update
     *      
     * Unlike buy operations, sell operations do not trigger graduation
     * since they increase reserves rather than decrease them.
     * 
     * The function will revert if:
     * - The token has already graduated
     * - The router's sell operation fails
     * - The caller has insufficient token balance
     * - The caller has not approved sufficient tokens to the router
     * 
     * @param amountIn_ Amount of agent tokens to sell
     * @param tokenAddress_ Address of the agent token being sold
     * @return success True if the sell operation and all subsequent operations succeed
     * 
     * @custom:metrics Updates token metrics via _updateMetrics()
     * @custom:requires
     * - Token must not be graduated
     * - Valid pair must exist in factory
     * - Caller must have sufficient token balance
     * - Router must have sufficient token approval
     */
    function sell(
        uint256 amountIn_,
        address tokenAddress_
    ) external returns (bool) {
        // Check if token is eligible for trading by verifying it hasn't graduated
        // This prevents trading after graduation when tokens move to external DEXes
        require(!agentTokens[tokenAddress_].hasGraduated, "Trading not active");

        // Get the bonding pair address from the factory
        // This pair manages the token/asset liquidity pool
        address pairAddress = factory.getPair(
            tokenAddress_,
            router.assetToken()
        );

        // Load the bonding pair contract and get current reserves
        // reserveA represents the agent token balance
        // We ignore reserveB (asset token) since we only need agent token reserves
        IBondingPair pair = IBondingPair(pairAddress);
        (uint256 reserveA,) = pair.getReserves();
        
        // Execute the sell through the router
        // amount0In represents the amount of agent tokens being sold into the pool
        // Second return value (amountOut - asset tokens received) is ignored 
        // as it's handled by the router
        (uint256 amount0In,) = router.sell(
            amountIn_,
            tokenAddress_,
            msg.sender
        );

        // Update metrics with new reserve values
        // For sells, we add the incoming tokens to the reserves
        // This increases the pool's agent token balance
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
        
        // Deploy to DEXes and store the pairs
        address[] memory newPairs = router.graduate(
            tokenAddress_,
            token.dexRouters
        );

        // Update token data with new pairs
        token.dexPools = newPairs;
        token.hasGraduated = true;

        // graduate token
        Token(tokenAddress_).graduate(newPairs);

        // graduated
        emit Graduated(tokenAddress_);
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