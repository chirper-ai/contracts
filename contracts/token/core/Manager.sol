// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V2
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

// Uniswap V3
import "../interfaces/UniswapV3/IUniswapV3Pool.sol";
import "../interfaces/UniswapV3/IUniswapV3Factory.sol";
import "../interfaces/UniswapV3/INonfungiblePositionManager.sol";

// Velodrome
import "../interfaces/Velodrome/IVelodromeRouter.sol";
import "../interfaces/Velodrome/IVelodromeFactory.sol";

// Local interfaces
import "../interfaces/IRouter.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IBondingPair.sol";
import "../interfaces/IToken.sol";

/**
 * @title Manager
 * @dev Manages the lifecycle of AI agent tokens and handles graduation to DEXes.
 * 
 * This contract is responsible for:
 * 1. Token lifecycle and information tracking
 * 2. Graduation process orchestration
 * 3. DEX deployment and liquidity management
 * 4. Token state management
 */
contract Manager is 
    Initializable, 
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Supported DEX types for graduation
    enum DexType {
        UniswapV2,
        UniswapV3,
        Velodrome
    }

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configuration for a DEX deployment
     * @param router Router contract address
     * @param fee Fee tier (for UniswapV3)
     * @param weight Liquidity allocation weight (basis points)
     * @param dexType Type of DEX
     */
    struct DexConfig {
        address router;
        uint24 fee;
        uint24 weight;
        DexType dexType;
    }

    /**
     * @notice Token information and configuration
     * @param creator Token creator address
     * @param intention Token purpose/description
     * @param url Reference URL
     * @param bondingPair Associated bonding pair
     * @param dexConfigs DEX deployment settings
     * @param dexPools Deployed DEX pool addresses
     */
    struct TokenInfo {
        address creator;
        string intention;
        string url;
        address bondingPair;
        DexConfig[] dexConfigs;
        address[] dexPools;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Basis points denominator for percentage calculations
    uint256 private constant BASIS_POINTS = 100_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Factory contract reference
    IFactory public factory;

    /// @notice Asset token used for trading
    address public assetToken;

    /// @notice Slippage tolerance for graduation liquidity deployment
    uint256 public gradSlippage;

    /// @notice Maps token addresses to their information
    mapping(address => TokenInfo) public tokenInfo;

    /// @notice List of all launched tokens
    address[] public allTokens;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a token's information is registered
     * @param token Token address
     * @param creator Token creator
     * @param intention Token purpose
     * @param url Reference URL
     */
    event TokenRegistered(
        address indexed token,
        address indexed creator,
        string intention,
        string url
    );

    /**
     * @notice Emitted when a token graduates to DEX trading
     * @param token Token address
     * @param pools Array of deployed DEX pools
     */
    event TokenGraduated(
        address indexed token,
        address[] pools
    );

    /**
     * @notice Emitted when graduation parameters are updated
     * @param gradSlippage New slippage tolerance
     */
    event GraduationParamsUpdated(uint256 gradSlippage);

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
     * @notice Initializes the manager contract
     * @param factory_ Factory contract address
     * @param assetToken_ Asset token address
     * @param gradSlippage_ Graduation slippage tolerance
     */
    function initialize(
        address factory_,
        address assetToken_,
        uint256 gradSlippage_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(factory_ != address(0), "Invalid factory");
        require(assetToken_ != address(0), "Invalid asset token");
        require(
            gradSlippage_ > 0 && gradSlippage_ <= BASIS_POINTS,
            "Invalid slippage"
        );

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        factory = IFactory(factory_);
        assetToken = assetToken_;
        gradSlippage = gradSlippage_;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers a new token's information
     * @param token Token address
     * @param intention Token purpose
     * @param url Reference URL
     * @param configs DEX deployment configurations
     */
    function registerToken(
        address token,
        string calldata intention,
        string calldata url,
        DexConfig[] calldata configs
    ) external {
        require(msg.sender == address(factory), "Only factory");
        require(tokenInfo[token].creator == address(0), "Already registered");

        // Validate DEX configs
        uint24 totalWeight;
        for (uint i = 0; i < configs.length; i++) {
            require(configs[i].router != address(0), "Invalid router");
            require(
                configs[i].weight > 0 && 
                configs[i].weight <= BASIS_POINTS,
                "Invalid weight"
            );
            totalWeight += configs[i].weight;
        }
        require(totalWeight == BASIS_POINTS, "Invalid weights");

        // Get bonding pair
        address bondingPair = factory.getPair(token, assetToken);
        require(bondingPair != address(0), "Invalid pair");

        // Store token information
        tokenInfo[token] = TokenInfo({
            creator: tx.origin,
            intention: intention,
            url: url,
            bondingPair: bondingPair,
            dexConfigs: configs,
            dexPools: new address[](0)
        });

        allTokens.push(token);

        emit TokenRegistered(token, tx.origin, intention, url);
    }

    /**
     * @notice Handles the graduation process for a token
     * @param token Token address
     */
    function graduate(address token) external nonReentrant {
        TokenInfo storage info = tokenInfo[token];
        require(msg.sender == info.bondingPair, "Only bonding pair");
        require(info.dexPools.length == 0, "Already graduated");

        // Get bonding pair liquidity
        IBondingPair pair = IBondingPair(info.bondingPair);
        uint256 tokenBalance = pair.balance();
        uint256 assetBalance = pair.assetBalance();

        require(
            tokenBalance > 0 && assetBalance > 0,
            "Insufficient liquidity"
        );

        // Deploy to configured DEXes
        address[] memory pools = new address[](info.dexConfigs.length);

        for (uint i = 0; i < info.dexConfigs.length; i++) {
            DexConfig memory config = info.dexConfigs[i];
            
            // Calculate proportional liquidity
            uint256 tokenAmount = (tokenBalance * config.weight) / BASIS_POINTS;
            uint256 assetAmount = (assetBalance * config.weight) / BASIS_POINTS;

            // Deploy to appropriate DEX
            if (config.dexType == DexType.UniswapV2) {
                pools[i] = _deployToV2(
                    token,
                    config.router,
                    tokenAmount,
                    assetAmount
                );
            } else if (config.dexType == DexType.UniswapV3) {
                pools[i] = _deployToV3(
                    token,
                    config.router,
                    tokenAmount,
                    assetAmount,
                    config.fee
                );
            } else {
                pools[i] = _deployToVelo(
                    token,
                    config.router,
                    tokenAmount,
                    assetAmount
                );
            }
        }

        // Update token state
        info.dexPools = pools;
        IToken(token).graduate(pools);

        emit TokenGraduated(token, pools);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns a token's DEX pool addresses
     * @param token Token address
     * @return Pool addresses
     */
    function getDexPools(
        address token
    ) external view returns (address[] memory) {
        return tokenInfo[token].dexPools;
    }

    /**
     * @notice Returns total number of registered tokens
     * @return Token count
     */
    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    /**
     * @notice Returns a page of token addresses
     * @param offset Starting index
     * @param limit Maximum number of items
     * @return tokens Token addresses
     */
    function getTokens(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory tokens) {
        require(offset < allTokens.length, "Invalid offset");
        uint256 end = Math.min(offset + limit, allTokens.length);
        uint256 length = end - offset;

        tokens = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            tokens[i] = allTokens[offset + i];
        }

        return tokens;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates graduation slippage tolerance
     * @param gradSlippage_ New slippage tolerance
     */
    function setGradSlippage(
        uint256 gradSlippage_
    ) external onlyRole(ADMIN_ROLE) {
        require(
            gradSlippage_ > 0 && gradSlippage_ <= BASIS_POINTS,
            "Invalid slippage"
        );
        gradSlippage = gradSlippage_;
        emit GraduationParamsUpdated(gradSlippage_);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL DEX FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys liquidity to Uniswap V2
     * @param token Token address
     * @param routerAddress V2 router address
     * @param tokenAmount Token liquidity amount
     * @param assetAmount Asset token liquidity amount
     * @return pool Pool address
     */
    function _deployToV2(
        address token,
        address routerAddress,
        uint256 tokenAmount,
        uint256 assetAmount
    ) internal returns (address pool) {
        IUniswapV2Router02 router = IUniswapV2Router02(routerAddress);
        IUniswapV2Factory dexFactory = IUniswapV2Factory(router.factory());

        // Get or create pool
        pool = dexFactory.getPair(token, assetToken);
        if (pool == address(0)) {
            pool = dexFactory.createPair(token, assetToken);
        }

        // Calculate minimum amounts with slippage protection
        uint256 minTokenAmount = (tokenAmount * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS;
        uint256 minAssetAmount = (assetAmount * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS;

        // Transfer tokens from bonding pair
        TokenInfo storage info = tokenInfo[token];
        IBondingPair(info.bondingPair).transferTo(address(this), tokenAmount);
        IBondingPair(info.bondingPair).transferAsset(address(this), assetAmount);

        // Approve and add liquidity
        IERC20(token).forceApprove(routerAddress, tokenAmount);
        IERC20(assetToken).forceApprove(routerAddress, assetAmount);

        router.addLiquidity(
            token,
            assetToken,
            tokenAmount,
            assetAmount,
            minTokenAmount,
            minAssetAmount,
            address(this),
            block.timestamp
        );

        return pool;
    }

    /**
     * @notice Deploys liquidity to Uniswap V3
     * @param token Token address
     * @param routerAddress V3 position manager address
     * @param tokenAmount Token liquidity amount
     * @param assetAmount Asset token liquidity amount
     * @param fee Pool fee tier
     * @return pool Pool address
     */
    function _deployToV3(
        address token,
        address routerAddress,
        uint256 tokenAmount,
        uint256 assetAmount,
        uint24 fee
    ) internal returns (address pool) {
        INonfungiblePositionManager posManager = INonfungiblePositionManager(routerAddress);
        IUniswapV3Factory v3Factory = IUniswapV3Factory(posManager.factory());

        // Sort tokens (required by V3)
        (address token0, address token1) = token < assetToken 
            ? (token, assetToken) 
            : (assetToken, token);
        
        (uint256 amount0, uint256 amount1) = token < assetToken
            ? (tokenAmount, assetAmount)
            : (assetAmount, tokenAmount);

        // Transfer tokens from bonding pair
        TokenInfo storage info = tokenInfo[token];
        IBondingPair(info.bondingPair).transferTo(address(this), tokenAmount);
        IBondingPair(info.bondingPair).transferAsset(address(this), assetAmount);

        // Approve tokens to position manager
        IERC20(token0).forceApprove(routerAddress, amount0);
        IERC20(token1).forceApprove(routerAddress, amount1);

        // Get or create pool
        pool = v3Factory.getPool(token0, token1, fee);
        if (pool == address(0)) {
            pool = v3Factory.createPool(token0, token1, fee);

            // Calculate initial sqrt price
            uint256 price = (amount1 * 1e18) / amount0;
            uint160 sqrtPriceX96 = uint160(Math.sqrt(price) * 2**96);
            
            // Initialize pool
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }

        // Calculate tick range for position
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        // Create position with full range
        posManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: (amount0 * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS,
                amount1Min: (amount1 * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        return pool;
    }

    /**
     * @notice Deploys liquidity to Velodrome
     * @param token Token address
     * @param routerAddress Velodrome router address
     * @param tokenAmount Token liquidity amount
     * @param assetAmount Asset token liquidity amount
     * @return pool Pool address
     */
    function _deployToVelo(
        address token,
        address routerAddress,
        uint256 tokenAmount,
        uint256 assetAmount
    ) internal returns (address pool) {
        IVelodromeRouter router = IVelodromeRouter(routerAddress);
        IVelodromeFactory veloFactory = IVelodromeFactory(router.factory());
        
        // Get bonding pair and transfer tokens
        TokenInfo storage info = tokenInfo[token];
        IBondingPair(info.bondingPair).transferTo(address(this), tokenAmount);
        IBondingPair(info.bondingPair).transferAsset(address(this), assetAmount);

        // Approve tokens to router
        IERC20(token).forceApprove(routerAddress, tokenAmount);
        IERC20(assetToken).forceApprove(routerAddress, assetAmount);

        // Get or create pool (use volatile pool)
        bool stable = false;
        pool = veloFactory.getPair(token, assetToken, stable);
        if (pool == address(0)) {
            pool = veloFactory.createPair(token, assetToken, stable);
        }

        // Calculate minimum amounts
        uint256 minTokenAmount = (tokenAmount * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS;
        uint256 minAssetAmount = (assetAmount * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS;

        // Add liquidity
        router.addLiquidity(
            token,
            assetToken,
            stable,
            tokenAmount,
            assetAmount,
            minTokenAmount,
            minAssetAmount,
            address(this),
            block.timestamp
        );

        return pool;
    }
}