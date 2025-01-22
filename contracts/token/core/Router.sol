// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// openzeppelin
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
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
import "../interfaces/IToken.sol";
import "../interfaces/IRouter.sol";
import "../interfaces/IFactory.sol";
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
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enum to specify the type of DEX router
    enum RouterType {
        UniswapV2,
        UniswapV3,
        Velodrome
    }

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Router information for token graduation
    struct DexRouter {
        address routerAddress; // Address of the DEX router
        uint24 feeAmount;     // Fee amount for the DEX router
        uint24 weight;        // Weight for liquidity distribution (1-100)
        RouterType routerType; // Type of DEX router
    }

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
    IFactory public factory;
    
    /// @notice Asset token used for all trading pairs
    address public assetToken;
    
    /// @notice Maximum transaction amount for a single swap
    uint256 public maxTxPercent;
    
    // Mapping to track created DEX pools for each token
    mapping(address => address[]) public tokenDexPools;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event DexPoolsCreated(address indexed token, address[] pools);

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
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        require(factory_ != address(0), "Invalid factory");
        require(maxTxPercent_ > 0, "Invalid max tx percent");
        require(maxTxPercent_ <= 100_000, "Max tx percent Exceeds 100%");

        factory = IFactory(factory_);
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
        
        // Check token hasn't graduated
        IToken token = IToken(tokenAddress_);
        require(!token.hasGraduated(), "Token graduated");

        address pair = factory.getPair(tokenAddress_, assetToken);

        // Calculate split fees using Factory's tax settings
        uint256 feePercent = factory.buyTax();
        uint256 totalFee = (feePercent * amountIn_) / 100_000;
        uint256 halfFee = totalFee / 2;
        uint256 finalAmount = amountIn_ - totalFee;
        
        address taxVault = factory.taxVault();
        address tokenOwner = token.owner();

        // Transfer tokens with split fees
        IERC20(assetToken).safeTransferFrom(to_, pair, finalAmount);
        IERC20(assetToken).safeTransferFrom(to_, taxVault, halfFee);
        IERC20(assetToken).safeTransferFrom(to_, tokenOwner, halfFee);

        uint256 amountOut = _getAmountsOut(tokenAddress_, assetToken, finalAmount);
        
        // check max transaction percent by total supply
        uint256 maxTxAmount = (IERC20(tokenAddress_).totalSupply() * maxTxPercent) / 100_000;

        // check max transaction amount
        require(amountOut <= maxTxAmount, "Exceeds max transaction");

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
        uint256 maxTxAmount = (IERC20(tokenAddress_).totalSupply() * maxTxPercent) / 100_000;

        // check max transaction amount
        require(amountIn_ <= maxTxAmount, "Exceeds max transaction");
        
        // Check token hasn't graduated
        IToken token = IToken(tokenAddress_);
        require(!token.hasGraduated(), "Token graduated");

        address pairAddress = factory.getPair(tokenAddress_, assetToken);
        IBondingPair pair = IBondingPair(pairAddress);
        
        uint256 amountOut = _getAmountsOut(tokenAddress_, address(0), amountIn_);
        IERC20(tokenAddress_).safeTransferFrom(to_, pairAddress, amountIn_);

        // Calculate split fees using Factory's tax settings
        uint256 fee = factory.sellTax();
        uint256 totalFee = (fee * amountOut) / 100_000;
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
     * @notice Handles the graduation process for a token to external DEXes
     * @param tokenAddress_ Address of token to graduate
     * @param dexRouters_ Array of DEX routers to deploy to
     * @return pairs Array of created DEX pairs
     */
    function graduate(
        address tokenAddress_,
        DexRouter[] calldata dexRouters_
    ) external onlyRole(EXECUTOR_ROLE) nonReentrant returns (address[] memory) {
        require(tokenAddress_ != address(0), "Invalid token");
        
        IToken token = IToken(tokenAddress_);
        require(!token.hasGraduated(), "Token graduated");
        
        address pairAddr = factory.getPair(tokenAddress_, assetToken);
        IBondingPair pair = IBondingPair(pairAddr);
        
        uint256 assetBalance = pair.assetBalance();
        uint256 agentBalance = pair.balance();

        require(agentBalance > 0 && assetBalance > 0, "Invalid amounts");
        require(dexRouters_.length > 0, "No DEX routers provided");

        // Approve Router to spend from bonding pair
        pair.approval(address(this), tokenAddress_, agentBalance);
        pair.approval(address(this), assetToken, assetBalance);
        
        // Validate weights sum to 100%
        uint24 totalWeight;
        for (uint i = 0; i < dexRouters_.length; i++) {
            require(dexRouters_[i].routerAddress != address(0), "Invalid router");
            require(dexRouters_[i].weight > 0 && dexRouters_[i].weight <= 100_000, "Invalid weight");
            totalWeight += dexRouters_[i].weight;
        }
        require(totalWeight == 100_000, "Weights must sum to 100_000");

        address[] memory pairs = new address[](dexRouters_.length);
        uint256 denominator = 100_000;

        for (uint256 i = 0; i < dexRouters_.length; i++) {
            DexRouter memory dexRouter = dexRouters_[i];
            
            uint256 tokenAmount = (agentBalance * dexRouter.weight) / denominator;
            uint256 assetAmount = (assetBalance * dexRouter.weight) / denominator;

            if (dexRouter.routerType == RouterType.UniswapV2) {
                pairs[i] = _deployUniV2(tokenAddress_, dexRouter.routerAddress, tokenAmount, assetAmount);
            } else if (dexRouter.routerType == RouterType.UniswapV3) {
                pairs[i] = _deployUniV3(tokenAddress_, dexRouter.routerAddress, tokenAmount, assetAmount, dexRouter.feeAmount);
            } else {
                pairs[i] = _deployVelo(tokenAddress_, dexRouter.routerAddress, tokenAmount, assetAmount);
            }
        }

        // Store created pools
        tokenDexPools[tokenAddress_] = pairs;
        emit DexPoolsCreated(tokenAddress_, pairs);

        return pairs;
    }

    /**
     * @notice Deploys liquidity from bonding curve to Uniswap V2 pool during graduation
     * @dev This function handles the entire deployment process including:
     *      1. Moving tokens from bonding pair to Router
     *      2. Creating new V2 pool if needed
     *      3. Approving and providing initial liquidity
     * 
     * The function follows these key steps:
     * - Gets or creates a new Uniswap V2 pool via factory
     * - Transfers tokens from bonding pair to Router
     * - Approves DEX router to spend tokens
     * - Adds liquidity with 5% slippage tolerance
     * 
     * Key considerations:
     * - Tokens must first be moved from bonding pair to Router
     * - Slippage protection is set to 5% (95% of intended amounts)
     * - LP tokens are sent to address(0) to avoid Router holding them
     * - Function assumes bonding pair has already approved Router
     * 
     * @param tokenAddress_ Address of the agent token being graduated
     * @param routerAddress_ Address of the Uniswap V2 router to deploy to
     * @param tokenAmount_ Amount of agent tokens to provide as liquidity
     * @param assetAmount_ Amount of asset tokens (VANA) to provide as liquidity
     * @return dexPool Address of the created or existing Uniswap V2 pool
     *
     * @custom:security This function assumes Router has EXECUTOR_ROLE
     * @custom:validation
     * - Token amounts must be pre-validated
     * - DEX router must be valid V2 implementation
     * - Bonding pair must have sufficient balances
     */
    function _deployUniV2(
        address tokenAddress_,
        address routerAddress_,
        uint256 tokenAmount_,
        uint256 assetAmount_
    ) private returns (address dexPool) {
        // Get router and factory interfaces for Uniswap V2
        // These contracts handle pool creation and liquidity provision
        IUniswapV2Router02 dexRouter = IUniswapV2Router02(routerAddress_);
        IUniswapV2Factory dexFactory = IUniswapV2Factory(dexRouter.factory());
        
        // Step 1: Transfer tokens from bonding pair to Router
        // The bonding pair holds both token types - we need to transfer both
        // to the Router before we can provide them to the DEX
        address bondingPair = factory.getPair(tokenAddress_, assetToken);
        IBondingPair(bondingPair).transferTo(address(this), tokenAmount_);   // Transfer agent tokens
        IBondingPair(bondingPair).transferAsset(address(this), assetAmount_); // Transfer asset tokens

        // Step 2: Approve DEX router to spend tokens now held by Router
        // The DEX router needs approval to move tokens from Router to the new pool
        // We use forceApprove to ensure no lingering approvals
        IERC20(tokenAddress_).forceApprove(address(dexRouter), tokenAmount_);
        IERC20(assetToken).forceApprove(address(dexRouter), assetAmount_);

        // Step 3: Get or create Uniswap V2 pool
        // Check if pool already exists for this token pair
        dexPool = dexFactory.getPair(tokenAddress_, assetToken);
        if (dexPool == address(0)) {
            // If no pool exists, create a new one via factory
            // This sets up the initial exchange rate based on first liquidity add
            dexPool = dexFactory.createPair(tokenAddress_, assetToken);
        }

        // Step 4: Add initial liquidity to the pool
        // Parameters:
        // - Both token addresses
        // - Desired amounts of each token
        // - Minimum amounts (95% of desired, allowing 5% slippage)
        // - LP token recipient (address 0 to avoid Router holding LP tokens)
        // - Deadline 1 hour from now
        dexRouter.addLiquidity(
            tokenAddress_,    // Agent token address
            assetToken,       // Asset token (VANA) address
            tokenAmount_,     // Desired agent token amount
            assetAmount_,     // Desired asset token amount
            tokenAmount_ * 95 / 100,  // Min agent tokens (5% slippage)
            assetAmount_ * 95 / 100,  // Min asset tokens (5% slippage)
            address(0),       // Send LP tokens to address(0)
            block.timestamp + 3600  // 1 hour deadline
        );

        return dexPool;
    }

    /**
     * @notice Deploys liquidity from bonding curve to Uniswap V3 pool during graduation
     * @dev This function handles the complex V3 deployment process including:
     *      1. Token sorting (V3 requires token0 < token1)
     *      2. Moving tokens from bonding pair to Router
     *      3. Creating and initializing V3 pool with correct price
     *      4. Providing full-range liquidity position
     * 
     * The function follows these key steps:
     * - Sorts tokens according to V3 requirements
     * - Transfers tokens from bonding pair to Router
     * - Creates and initializes pool with calculated sqrtPriceX96
     * - Creates full-range position (-887220 to +887220 ticks)
     * 
     * Technical notes:
     * - sqrtPriceX96 is in Q64.96 format
     * - Full range is used to mimic V2-style liquidity provision
     * - Initial price is set based on provided token amounts
     * - No price impact protection as this is initial liquidity
     * 
     * Key considerations:
     * - Token sorting is critical for V3 pools
     * - Initial price calculation must maintain precision
     * - Full range ensures maximum liquidity availability
     * - LP NFT is held by Router address
     * 
     * @param tokenAddress_ Address of the agent token being graduated
     * @param routerAddress_ Address of the Uniswap V3 NonfungiblePositionManager
     * @param tokenAmount_ Amount of agent tokens to provide as liquidity
     * @param assetAmount_ Amount of asset tokens (VANA) to provide as liquidity
     * @param feeAmount_ Fee tier for the pool (500 = 0.05%, 3000 = 0.3%, 10000 = 1%)
     * @return dexPool Address of the created or existing V3 pool
     * 
     * @custom:security
     * - Assumes Router has EXECUTOR_ROLE
     * - Maintains precision in price calculations
     * - Full range prevents price manipulation
     * 
     * @custom:validation
     * - Token amounts must be pre-validated
     * - Fee tier must be valid V3 fee
     * - Bonding pair must have sufficient balances
     */
    function _deployUniV3(
        address tokenAddress_,
        address routerAddress_,
        uint256 tokenAmount_,
        uint256 assetAmount_,
        uint24 feeAmount_
    ) private returns (address dexPool) {
        // Step 1: Sort tokens according to V3 requirements
        // Uniswap V3 requires token0 < token1 for pool creation and interaction
        // We need to sort both addresses and amounts to maintain correct order
        bool isTokenFirst = tokenAddress_ < assetToken;
        (address token0, address token1) = isTokenFirst 
            ? (tokenAddress_, assetToken) 
            : (assetToken, tokenAddress_);
            
        (uint256 amount0, uint256 amount1) = isTokenFirst
            ? (tokenAmount_, assetAmount_)
            : (assetAmount_, tokenAmount_);

        // Step 2: Get V3 contract interfaces
        // Position manager handles liquidity provision and NFT minting
        // Factory handles pool creation and initialization
        INonfungiblePositionManager positionManager = INonfungiblePositionManager(routerAddress_);
        IUniswapV3Factory positionFactory = IUniswapV3Factory(positionManager.factory());

        // Step 3: Transfer tokens from bonding pair to Router
        // Both token types need to be moved before V3 liquidity provision
        address bondingPair = factory.getPair(tokenAddress_, assetToken);
        IBondingPair(bondingPair).transferTo(address(this), tokenAmount_);
        IBondingPair(bondingPair).transferAsset(address(this), assetAmount_);

        // Step 4: Approve position manager to spend Router's tokens
        // V3 requires approval for both tokens regardless of order
        IERC20(token0).forceApprove(address(positionManager), amount0);
        IERC20(token1).forceApprove(address(positionManager), amount1);

        // Step 5: Get or create V3 pool
        dexPool = positionFactory.getPool(token0, token1, feeAmount_);
        if (dexPool == address(0)) {
            // Create new pool if it doesn't exist
            dexPool = positionFactory.createPool(token0, token1, feeAmount_);

            // Calculate initial price in sqrtPriceX96 format
            // This sets the initial exchange rate for the pool
            uint256 price = (amount1 * 1e18) / amount0;      // Calculate price with 18 decimals
            uint256 sqrtPrice = Math.sqrt(price * 1e18);     // Square root with 18 decimals
            uint160 sqrtPriceX96 = uint160((sqrtPrice * (2**96)) / 1e18);  // Convert to Q64.96

            // Initialize pool with calculated price
            IUniswapV3Pool(dexPool).initialize(sqrtPriceX96);
        }

        // Step 6: Calculate full range ticks
        // We use maximum possible range to mimic V2-style liquidity
        int24 tickSpacing = IUniswapV3Pool(dexPool).tickSpacing();
        int24 tickLower = (-887272 / tickSpacing) * tickSpacing;  // Lowest possible tick
        int24 tickUpper = (887272 / tickSpacing) * tickSpacing;   // Highest possible tick

        // Step 7: Create the full range liquidity position
        // This mint call:
        // - Creates a new NFT representing the position
        // - Transfers tokens from Router to pool
        // - Initializes full-range liquidity position
        positionManager.mint(INonfungiblePositionManager.MintParams({
            token0: token0,                  // First token in pair
            token1: token1,                  // Second token in pair
            fee: feeAmount_,                 // Pool fee tier
            tickLower: tickLower,            // Minimum tick (full range)
            tickUpper: tickUpper,            // Maximum tick (full range)
            amount0Desired: amount0,         // Amount of token0
            amount1Desired: amount1,         // Amount of token1
            amount0Min: 0,                   // No slippage protection needed
            amount1Min: 0,                   // for initial liquidity
            recipient: address(this),         // Router receives position NFT
            deadline: block.timestamp + 3600  // 1 hour deadline
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
        IVelodromeRouter veloRouter = IVelodromeRouter(routerAddress_);
        
        // First, get bonding pair and transfer tokens to Router
        address bondingPair = factory.getPair(tokenAddress_, assetToken);
        IBondingPair(bondingPair).transferTo(address(this), tokenAmount_);
        IBondingPair(bondingPair).transferAsset(address(this), assetAmount_);

        // Now approve Velodrome router to spend tokens from Router
        IERC20(tokenAddress_).forceApprove(address(veloRouter), tokenAmount_);
        IERC20(assetToken).forceApprove(address(veloRouter), assetAmount_);

        // Get factory and check for existing pair
        address veloFactory = veloRouter.factory();
        bool isStable = false; // We use volatile pools for AI tokens
        
        dexPool = IVelodromeFactory(veloFactory).getPair(
            tokenAddress_,
            assetToken,
            isStable
        );

        // Create pair if it doesn't exist
        if (dexPool == address(0)) {
            dexPool = IVelodromeFactory(veloFactory).createPair(
                tokenAddress_,
                assetToken,
                isStable
            );
        }

        // Add liquidity to the pool
        veloRouter.addLiquidity(
            tokenAddress_,
            assetToken,
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
     * @notice Sets the maximum transaction amount for a single swap
     * @param maxTxPercent_ Maximum transaction amount for a single swap
     */
    function setMaxTxPercent(uint256 maxTxPercent_) external onlyRole(ADMIN_ROLE) {
        // Ensure max transaction is within acceptable bounds
        require(maxTxPercent_ > 0, "Invalid percent");
        require(maxTxPercent_ <= 100_000, "Exceeds 100%");

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