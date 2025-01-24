// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
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

// tick math
import "../libraries/TickMath.sol";

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
    struct AgentProfile {
        address creator;
        string intention;
        string url;
        address bondingPair;
        address mainPool;
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

    /// @notice Graduation threshold for bonding pair liquidity
    uint256 public gradThreshold;

    /// @notice Maps token addresses to their information
    mapping(address => AgentProfile) public agentProfile;

    /// @notice List of all launched tokens
    address[] public allAgents;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an agents information is registered
     * @param token Agent address
     * @param creator Agent creator
     * @param intention Agent purpose
     * @param url Reference URL
     */
    event AgentRegistered(
        address indexed token,
        address indexed creator,
        string intention,
        string url
    );

    /**
     * @notice Emitted when an agent graduates to DEX trading
     * @param token Agent address
     * @param pools Array of deployed DEX pools
     */
    event AgentGraduated(
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
        uint256 gradSlippage_,
        uint256 gradThreshold_
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
        gradThreshold = gradThreshold_;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Registers a new token's information
     * @param token Token address
     * @param bondingPair Bonding pair address
     * @param url Reference URL
     * @param intention Token purpose
     * @param _dexConfigs DEX deployment configurations
     */
    function registerAgent(
        address token,
        address bondingPair,
        string calldata url,
        string calldata intention,
        DexConfig[] calldata _dexConfigs
    ) external {
        require(msg.sender == address(factory), "Only factory");
        require(agentProfile[token].creator == address(0), "Already registered");

        // Validate DEX configs
        uint24 totalWeight;
        for (uint i = 0; i < _dexConfigs.length; i++) {
            require(_dexConfigs[i].router != address(0), "Invalid router");
            require(
                _dexConfigs[i].weight > 0 && 
                _dexConfigs[i].weight <= BASIS_POINTS,
                "Invalid weight"
            );
            totalWeight += _dexConfigs[i].weight;
        }
        require(totalWeight == BASIS_POINTS, "Invalid weights");

        // Store token information
        agentProfile[token] = AgentProfile({
            creator: tx.origin,
            url: url,
            intention: intention,
            bondingPair: bondingPair,
            mainPool: address(0),
            dexConfigs: _dexConfigs,
            dexPools: new address[](0)
        });

        // all agents
        allAgents.push(token);

        // emit registration event
        emit AgentRegistered(token, tx.origin, intention, url);
    }

    /**
     * @notice Checks if token should graduate based on reserve ratio
     * @param token Agent token address
     * @return shouldGraduate True if graduation conditions are met
     * @return reserveRatio Current reserve ratio if available
     */
    function checkGraduation(
        address token
    ) external view returns (bool shouldGraduate, uint256 reserveRatio) {
        AgentProfile storage info = agentProfile[token];
        
        // Already graduated
        if (info.dexPools.length > 0) {
            return (false, 0);
        }

        // Get bonding pair info
        IBondingPair pair = IBondingPair(info.bondingPair);
        (uint256 reserveAgent,,) = pair.getReserves();
        
        // Calculate reserve ratio
        uint256 totalSupply = IERC20(token).totalSupply();
        if (totalSupply == 0 || reserveAgent == 0) {
            return (false, 0);
        }

        reserveRatio = (reserveAgent * BASIS_POINTS) / totalSupply;

        // return graduation conditions
        return (reserveRatio <= gradThreshold, reserveRatio);
    }

    /**
     * @notice Handles the graduation process for a token
     * @param token Token address
     */
    function graduate(address token) external nonReentrant {
        AgentProfile storage info = agentProfile[token];
        require(msg.sender == factory.router(), "Only router");
        require(info.dexPools.length == 0, "Already graduated");

        // Get bonding pair liquidity
        IBondingPair pair = IBondingPair(info.bondingPair);
        (uint256 tokenBalance, uint256 assetBalance,) = pair.getReserves();

        require(
            tokenBalance > 0 && assetBalance > 0,
            "Insufficient liquidity"
        );

        // Transfer tokens from bonding pair
        IRouter(factory.router()).transferLiquidityToManager(
            token,
            tokenBalance,
            assetBalance
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
        info.mainPool = pools[0];
        IToken(token).graduate(pools);

        emit AgentGraduated(token, pools);
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
        return agentProfile[token].dexPools;
    }

    /**
     * @notice Returns total number of registered tokens
     * @return Token count
     */
    function tokenCount() external view returns (uint256) {
        return allAgents.length;
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

    /**
     * @notice Updates graduation threshold
     * @param gradThreshold_ New threshold
     */
    function setGradThreshold(
        uint256 gradThreshold_
    ) external onlyRole(ADMIN_ROLE) {
        gradThreshold = gradThreshold_;
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
        IUniswapV2Router02 dexRouter = IUniswapV2Router02(routerAddress);
        IUniswapV2Factory dexFactory = IUniswapV2Factory(dexRouter.factory());

        // Get or create pool
        pool = dexFactory.getPair(token, assetToken);
        if (pool == address(0)) {
            pool = dexFactory.createPair(token, assetToken);
        }

        // Calculate minimum amounts with slippage protection
        uint256 minTokenAmount = (tokenAmount * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS;
        uint256 minAssetAmount = (assetAmount * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS;

        // Approve and add liquidity
        IERC20(token).forceApprove(routerAddress, tokenAmount);
        IERC20(assetToken).forceApprove(routerAddress, assetAmount);

        dexRouter.addLiquidity(
            token,
            assetToken,
            tokenAmount,
            assetAmount,
            minTokenAmount,
            minAssetAmount,
            address(0),
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
        console.log("\n=== Starting V3 Deployment ===");
        
        INonfungiblePositionManager posManager = INonfungiblePositionManager(routerAddress);
        IUniswapV3Factory v3Factory = IUniswapV3Factory(posManager.factory());

        // Sort tokens and amounts
        (address token0, address token1) = token < assetToken ? (token, assetToken) : (assetToken, token);
        (uint256 amount0, uint256 amount1) = token < assetToken ? (tokenAmount, assetAmount) : (assetAmount, tokenAmount);

        console.log("Token ordering:");
        console.log(" - token0:", token0);
        console.log(" - token1:", token1);
        console.log(" - amount0:", amount0);
        console.log(" - amount1:", amount1);

        // Get or create pool
        pool = v3Factory.getPool(token0, token1, fee);
        console.log("\nPool status:", pool != address(0) ? "exists" : "needs creation");
        
        if (pool == address(0)) {
            console.log("\nCreating new pool...");
            pool = v3Factory.createPool(token0, token1, fee);
            console.log("Pool created at:", pool);

            // Initialize pool
            uint256 price = (amount1 * 1e18) / amount0;
            uint256 sqrtPrice = Math.sqrt(price * 1e18);
            uint160 sqrtPriceX96 = uint160((sqrtPrice * (2**96)) / 1e18);
            
            console.log("\nPool initialization:");
            console.log(" - raw price:", price);
            console.log(" - sqrt price:", sqrtPrice);
            console.log(" - sqrtPriceX96:", sqrtPriceX96);
            
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
            console.log("Pool initialized successfully");
        }

        // Get pool state
        (uint160 currentSqrtPrice, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();
        console.log("\nCurrent pool state:");
        console.log(" - sqrt price:", currentSqrtPrice);
        console.log(" - tick:", uint24(currentTick));
        console.log(" - liquidity:", IUniswapV3Pool(pool).liquidity());

        // Approve tokens
        IERC20(token0).forceApprove(address(posManager), amount0);
        IERC20(token1).forceApprove(address(posManager), amount1);

        console.log("\nToken approvals and balances:");
        console.log(" - token0 approved:", IERC20(token0).allowance(address(this), address(posManager)));
        console.log(" - token1 approved:", IERC20(token1).allowance(address(this), address(posManager)));
        console.log(" - token0 balance:", IERC20(token0).balanceOf(address(this)));
        console.log(" - token1 balance:", IERC20(token1).balanceOf(address(this)));

        // Calculate ticks
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        console.log("\nPosition parameters:");
        console.log(" - tick spacing:", uint24(tickSpacing));
        console.log(" - tick lower:", uint24(tickLower * -1));
        console.log(" - tick upper:", uint24(tickUpper));
        console.log(" - amount0 min:", (amount0 * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS);
        console.log(" - amount1 min:", (amount1 * (BASIS_POINTS - gradSlippage)) / BASIS_POINTS);

        // Mint position
        console.log("\nAttempting to mint position...");
        try posManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 3600
            })
        ) returns (uint256 tokenId, uint128 liquidity, uint256 amount0Added, uint256 amount1Added) {
            console.log("Mint succeeded:");
            console.log(" - tokenId:", tokenId);
            console.log(" - liquidity:", liquidity);
            console.log(" - amount0:", amount0Added);
            console.log(" - amount1:", amount1Added);
        } catch (bytes memory reason) {
            console.log("Mint failed! Error data:");
            console.logBytes(reason);
            revert("V3: Mint failed");
        }

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