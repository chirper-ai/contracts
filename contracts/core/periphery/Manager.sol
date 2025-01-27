// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "../../interfaces/UniswapV3/IUniswapV3Pool.sol";
import "../../interfaces/UniswapV3/IUniswapV3Factory.sol";
import "../../interfaces/UniswapV3/INonfungiblePositionManager.sol";
import "../../interfaces/Velodrome/IVelodromeRouter.sol";
import "../../interfaces/Velodrome/IVelodromeFactory.sol";
import "../../interfaces/IRouter.sol";
import "../../interfaces/IFactory.sol";
import "../../interfaces/IPair.sol";
import "../../interfaces/IToken.sol";
import "../../libraries/TickMath.sol";

/**
 * @title Manager
 * @dev Orchestrates token graduation from bonding curves to DEX trading
 * 
 * Core Functionality:
 * 1. Token Lifecycle Management
 *    - Tracks token metadata and configuration
 *    - Monitors graduation readiness
 *    - Manages token state transitions
 * 
 * 2. Graduation Process
 *    - Triggered when token reserve ratio <= threshold
 *    - Migrates liquidity from bonding curve
 *    - Deploys to multiple DEXes based on weights
 *    - Supports Uniswap V2/V3 and Velodrome
 * 
 * 3. DEX Integration
 *    - Custom deployment logic per DEX type
 *    - Optimal liquidity distribution
 *    - Automatic pool creation and initialization
 * 
 * Example Graduation Flow:
 * 1. Token reaches 50% reserve ratio
 * 2. Router triggers graduation
 * 3. Bonding curve liquidity withdrawn
 * 4. Distributed to DEXes: 
 *    - 40% to Uniswap V3 (0.3% fee tier)
 *    - 30% to Uniswap V2
 *    - 30% to Velodrome
 * 5. Token unlocked for DEX trading
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

    /// @notice Supported DEX protocols
    enum DexType {
        UniswapV2,   // Standard AMM pools
        UniswapV3,   // Concentrated liquidity pools
        Velodrome    // Solidly-style pools
    }

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice DEX deployment parameters
     * @param router Protocol router/manager address
     * @param fee Liquidity pool fee tier (UniV3)
     * @param weight Percentage of total liquidity (basis points)
     * @param dexType Protocol identifier
     */
    struct DexConfig {
        address router;
        uint24 fee;
        uint24 weight;
        DexType dexType;
    }

    /**
     * @notice Token registration and tracking data
     * @param creator Token deployer address
     * @param intention Token purpose description
     * @param url Project documentation URL
     * @param bondingPair Initial trading pair address
     * @param mainPool Primary DEX pool post-graduation 
     * @param dexConfigs Distribution parameters for graduation
     * @param dexPools Active DEX pool addresses
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

    /// @notice Administrative access control
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Basis points scaling (100%)
    uint256 private constant BASIS_POINTS = 100_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Token factory contract
    IFactory public factory;

    /// @notice Trading pair denominator token
    address public assetToken;

    /// @notice Required reserve ratio for graduation (%)
    uint256 public gradThreshold;

    /// @notice Token data storage
    mapping(address => AgentProfile) public agentProfile;

    /// @notice Registered token list
    address[] public allAgents;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Token registration completed
     * @param token Token contract address
     * @param creator Token owner address
     * @param intention Project description
     * @param url Documentation link
     */
    event AgentRegistered(
        address indexed token,
        address indexed creator,
        string intention,
        string url
    );

    /**
     * @notice Token graduated to DEX trading
     * @param token Token contract address
     * @param pools Active DEX pool addresses
     */
    event AgentGraduated(
        address indexed token,
        address[] pools
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
     * @notice Configures contract parameters
     * @param factory_ Token factory address
     * @param assetToken_ Quote token address
     * @param gradThreshold_ Target reserve ratio
     */
    function initialize(
        address factory_,
        address assetToken_,
        uint256 gradThreshold_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(factory_ != address(0), "Invalid factory");
        require(assetToken_ != address(0), "Invalid asset token");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        factory = IFactory(factory_);
        assetToken = assetToken_;
        gradThreshold = gradThreshold_;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Stores token configuration
     * @param token Token address
     * @param bondingPair Trading pair address
     * @param url Documentation URL
     * @param intention Token description
     * @param _dexConfigs Graduation parameters
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

        agentProfile[token] = AgentProfile({
            creator: tx.origin,
            url: url,
            intention: intention,
            bondingPair: bondingPair,
            mainPool: address(0),
            dexConfigs: _dexConfigs,
            dexPools: new address[](0)
        });

        allAgents.push(token);
        emit AgentRegistered(token, tx.origin, intention, url);
    }

    /**
     * @notice Evaluates graduation eligibility
     * @param token Token address
     * @return shouldGraduate Graduation status
     * @return reserveRatio Current ratio
     */
    function checkGraduation(
        address token
    ) external view returns (bool shouldGraduate, uint256 reserveRatio) {
        AgentProfile storage info = agentProfile[token];
        if (info.dexPools.length > 0) return (false, 0);

        IPair pair = IPair(info.bondingPair);
        (uint256 reserveAgent,,) = pair.getReserves();
        uint256 totalSupply = IERC20(token).totalSupply();
        
        if (totalSupply == 0 || reserveAgent == 0) return (false, 0);

        reserveRatio = (reserveAgent * BASIS_POINTS) / totalSupply;
        return (reserveRatio <= gradThreshold, reserveRatio);
    }

    /**
     * @notice Executes graduation process
     * @param token Token address
     */
    function graduate(address token) external nonReentrant {
        require(msg.sender == factory.router(), "Only router");
        
        AgentProfile storage info = agentProfile[token];
        require(info.dexPools.length == 0, "Already graduated");

        IPair pair = IPair(info.bondingPair);
        (uint256 tokenBalance, uint256 assetBalance,) = pair.getReserves();
        require(tokenBalance > 0 && assetBalance > 0, "Insufficient liquidity");

        // Transfer liquidity
        IRouter(factory.router()).transferLiquidityToManager(
            token,
            tokenBalance,
            assetBalance
        );

        // Deploy to DEXes
        address[] memory pools = new address[](info.dexConfigs.length);
        for (uint i = 0; i < info.dexConfigs.length; i++) {
            DexConfig memory config = info.dexConfigs[i];
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

        info.dexPools = pools;
        info.mainPool = pools[0];
        IToken(token).graduate(pools);

        emit AgentGraduated(token, pools);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retrieves DEX pool addresses
     * @param token Token address
     * @return Active pool addresses
     */
    function getDexPools(
        address token
    ) external view returns (address[] memory) {
        return agentProfile[token].dexPools;
    }

    /**
     * @notice Gets bonding pair address
     * @param token Token address
     * @return Pair address
     */
    function getBondingPair(
        address token
    ) external view returns (address) {
        return agentProfile[token].bondingPair;
    }

    /**
     * @notice Counts registered tokens
     * @return Total token count
     */
    function tokenCount() external view returns (uint256) {
        return allAgents.length;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates graduation threshold
     * @param gradThreshold_ New threshold value
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
     * @notice Deploys to Uniswap V2
     * @param token Token address
     * @param routerAddress Router contract
     * @param tokenAmount Token liquidity
     * @param assetAmount Asset liquidity
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

        pool = dexFactory.getPair(token, assetToken);
        if (pool == address(0)) {
            pool = dexFactory.createPair(token, assetToken);
        }

        IERC20(token).forceApprove(routerAddress, tokenAmount);
        IERC20(assetToken).forceApprove(routerAddress, assetAmount);

        dexRouter.addLiquidity(
            token,
            assetToken,
            tokenAmount,
            assetAmount,
            0,
            0,
            address(0),
            block.timestamp
        );

        return pool;
    }

    /**
     * @notice Deploys to Uniswap V3 (continued)
     * @param token Token address
     * @param routerAddress Position manager
     * @param tokenAmount Token liquidity
     * @param assetAmount Asset liquidity
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

        (address token0, address token1) = token < assetToken ? (token, assetToken) : (assetToken, token);
        (uint256 amount0, uint256 amount1) = token < assetToken ? (tokenAmount, assetAmount) : (assetAmount, tokenAmount);

        pool = v3Factory.getPool(token0, token1, fee);
        
        if (pool == address(0)) {
            pool = v3Factory.createPool(token0, token1, fee);

            // Initialize pool
            uint256 price = (amount1 * 1e18) / amount0;
            uint256 sqrtPrice = Math.sqrt(price * 1e18);
            uint160 sqrtPriceX96 = uint160((sqrtPrice * (2**96)) / 1e18);
            
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }

        IERC20(token0).forceApprove(address(posManager), amount0);
        IERC20(token1).forceApprove(address(posManager), amount1);

        // Calculate full range ticks
        int24 tickSpacing = IUniswapV3Pool(pool).tickSpacing();
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        // Mint full range position
        posManager.mint(
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
        );

        return pool;
    }

    /**
     * @notice Deploys to Velodrome
     * @param token Token address
     * @param routerAddress Router contract
     * @param tokenAmount Token liquidity
     * @param assetAmount Asset liquidity
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

        IERC20(token).forceApprove(routerAddress, tokenAmount);
        IERC20(assetToken).forceApprove(routerAddress, assetAmount);

        // Use volatile pool type
        bool stable = false;
        pool = veloFactory.getPair(token, assetToken, stable);
        if (pool == address(0)) {
            pool = veloFactory.createPair(token, assetToken, stable);
        }

        router.addLiquidity(
            token,
            assetToken,
            stable,
            tokenAmount,
            assetAmount,
            0,
            0,
            address(this),
            block.timestamp
        );

        return pool;
    }
}