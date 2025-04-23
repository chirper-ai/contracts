// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// imports
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// uniswap v2
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

// uniswap v3
import "../../interfaces/UniswapV3/IUniswapV3Pool.sol";
import "../../interfaces/UniswapV3/IUniswapV3Factory.sol";
import "../../interfaces/UniswapV3/INonfungiblePositionManager.sol";

// velodrome
import "../../interfaces/Velodrome/IVelodromePool.sol";
import "../../interfaces/Velodrome/IVelodromeRouter.sol";
import "../../interfaces/Velodrome/IVelodromeFactory.sol";

// local imports
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
        uint24 slippage;
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

    /// @notice Required graduation reserve amount
    uint256 public gradReserve;

    /// @notice Token data storage
    mapping(address => AgentProfile) public agentProfile;

    /// @notice Registered token list
    address[] public allAgents;

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAPS
    //////////////////////////////////////////////////////////////*/

    /// @dev Gap for future storage layout changes
    uint256[45] private __gap;

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

    /**
     * @notice Emitted when graduation reserve amount is updated
     * @param newGradReserve New graduation reserve amount
     */
    event GradReserveUpdated(uint256 newGradReserve);

    /**
     * @notice Emitted when a token's DEX configurations are updated
     * @param token Token address
     * @param dexConfigs New DEX configurations
     */
    event AgentTokenDexConfigsUpdated(
        address indexed token,
        DexConfig[] dexConfigs
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
     * @param gradReserve_ Target reserve ratio
     */
    function initialize(
        address factory_,
        address assetToken_,
        uint256 gradReserve_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(factory_ != address(0), "Invalid factory");
        require(assetToken_ != address(0), "Invalid asset token");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        factory = IFactory(factory_);
        assetToken = assetToken_;
        gradReserve = gradReserve_;
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
        uint256 dexConfigsLength = _dexConfigs.length;
        for (uint256 i = 0; i < dexConfigsLength; i++) {
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
     * @notice Checks if token is ready for graduation
     * @param token Token address
     * @return Graduation readiness
     */
    function checkGraduation(
        address token
    ) external view returns (bool) {
        AgentProfile storage info = agentProfile[token];
        if (info.dexPools.length > 0) return false;

        IPair pair = IPair(info.bondingPair);
        (,uint256 reserveAsset,) = pair.getReserves();

        // check reserve above grad
        if (reserveAsset >= gradReserve) return true;

        // return false
        return false;
    }

    /**
     * @notice Collects accumulated fees from all DEX pools
     * @param token Token address to collect fees for
     * @return tokenAmount Amount of token fees collected
     * @return assetAmount Amount of asset token fees collected
     */
    function collectFees(
        address token
    ) external nonReentrant returns (uint256 tokenAmount, uint256 assetAmount) {
        AgentProfile storage info = agentProfile[token];
        require(info.dexPools.length > 0, "Not graduated");

        uint256 dexConfigsLength = info.dexConfigs.length;
        for (uint256 i = 0; i < dexConfigsLength; i++) {
            DexConfig memory config = info.dexConfigs[i];
            address pool = info.dexPools[i];

            (uint256 tokenFees, uint256 assetFees) = _collectFeesFromDex(
                token,
                pool,
                config.router,
                config.dexType,
                config.fee
            );

            tokenAmount += tokenFees;
            assetAmount += assetFees;
        }

        // split fees in half for token creator and platform treasury
        uint256 platformToken = tokenAmount / 2;
        uint256 platformAsset = assetAmount / 2;
        uint256 creatorToken = tokenAmount - platformToken;
        uint256 creatorAsset = assetAmount - platformAsset;

        // require > 0
        require(creatorToken > 0 || creatorAsset > 0, "No fees to collect");

        // get token
        IToken agentToken_ = IToken(token);
        IERC20 assetToken_ = IERC20(assetToken);
        address creator = agentToken_.creator();

        // transfer to
        if (creatorToken > 0) agentToken_.transfer(creator, creatorToken);
        if (creatorAsset > 0) assetToken_.safeTransfer(creator, creatorAsset);
        if (platformToken > 0) agentToken_.transfer(factory.platformTreasury(), platformToken);
        if (platformAsset > 0) assetToken_.safeTransfer(factory.platformTreasury(), platformAsset);
    }

    /**
     * @notice Executes graduation process
     * @param token Token address
     */
    function graduate(address token) external nonReentrant {
        address router = factory.router();
        require(msg.sender == router, "Only router");
        
        AgentProfile storage info = agentProfile[token];
        require(info.dexPools.length == 0, "Already graduated");

        IPair pair = IPair(info.bondingPair);
        (uint256 tokenBalance, uint256 assetBalance,) = pair.getReserves();
        require(tokenBalance > 0 && assetBalance > 0, "Insufficient liquidity");

        // Transfer liquidity
        IRouter(router).transferLiquidityToManager(
            token,
            tokenBalance,
            assetBalance
        );

        // Deploy to DEXes
        uint256 dexConfigsLength = info.dexConfigs.length;
        address[] memory pools = new address[](dexConfigsLength);
        for (uint256 i = 0; i < dexConfigsLength; i++) {
            DexConfig memory config = info.dexConfigs[i];
            uint256 tokenAmount = (tokenBalance * config.weight) / BASIS_POINTS;
            uint256 assetAmount = (assetBalance * config.weight) / BASIS_POINTS;

            // Deploy to appropriate DEX
            if (config.dexType == DexType.UniswapV2) {
                pools[i] = _deployToV2(
                    token,
                    config.router,
                    tokenAmount,
                    assetAmount,
                    config.slippage
                );
            } else if (config.dexType == DexType.UniswapV3) {
                pools[i] = _deployToV3(
                    token,
                    config.router,
                    tokenAmount,
                    assetAmount,
                    config.fee,
                    config.slippage
                );
            } else {
                pools[i] = _deployToVelo(
                    token,
                    config.router,
                    tokenAmount,
                    assetAmount,
                    config.slippage
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
     * @notice Updates graduation reserve amount
     * @param gradReserve_ New graduation reserve
     */
    function setGradReserve(
        uint256 gradReserve_
    ) external onlyRole(ADMIN_ROLE) {
        gradReserve = gradReserve_;

        // emit event
        emit GradReserveUpdated(gradReserve_);
    }

    /**
     * @notice sets dex configs
     * @param token Token address
     * @param dexConfigs Dex configurations
     * @dev Only admin
     */
    function setTokenDexConfigs(
        address token,
        DexConfig[] calldata dexConfigs
    ) external onlyRole(ADMIN_ROLE) {
        AgentProfile storage info = agentProfile[token];
        require(info.creator != address(0), "Token not registered");

        // check dex configs
        uint24 totalWeight;
        for (uint256 i = 0; i < dexConfigs.length; i++) {
            require(dexConfigs[i].router != address(0), "Invalid router");
            require(
                dexConfigs[i].weight > 0 && 
                dexConfigs[i].weight <= BASIS_POINTS,
                "Invalid weight"
            );
            totalWeight += dexConfigs[i].weight;
        }

        // check total weight
        require(totalWeight == BASIS_POINTS, "Invalid weights");

        // update dex configs
        info.dexConfigs = dexConfigs;

        // emit event
        emit AgentTokenDexConfigsUpdated(token, dexConfigs);
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
     * @param slippage Maximum slippage
     * @return pool Pool address
     */
    function _deployToV2(
        address token,
        address routerAddress,
        uint256 tokenAmount,
        uint256 assetAmount,
        uint24 slippage
    ) internal returns (address pool) {
        IUniswapV2Router02 dexRouter = IUniswapV2Router02(routerAddress);
        IUniswapV2Factory dexFactory = IUniswapV2Factory(dexRouter.factory());

        pool = dexFactory.getPair(token, assetToken);
        if (pool == address(0)) {
            pool = dexFactory.createPair(token, assetToken);
        }

        IERC20(token).forceApprove(routerAddress, tokenAmount);
        IERC20(assetToken).forceApprove(routerAddress, assetAmount);

        // Calculate minimum amounts with slippage protection
        // slippage is in basis points (100_000 = 100%)
        uint256 minTokenAmount = (tokenAmount * (BASIS_POINTS - slippage)) / BASIS_POINTS;
        uint256 minAssetAmount = (assetAmount * (BASIS_POINTS - slippage)) / BASIS_POINTS;

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
     * @notice Deploys to Uniswap V3 (continued)
     * @param token Token address
     * @param routerAddress Position manager
     * @param tokenAmount Token liquidity
     * @param assetAmount Asset liquidity
     * @param fee Pool fee tier
     * @param slippage Maximum slippage
     * @return pool Pool address
     */
    function _deployToV3(
        address token,
        address routerAddress,
        uint256 tokenAmount,
        uint256 assetAmount,
        uint24 fee,
        uint24 slippage
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

        // Calculate minimum amounts with slippage protection
        // slippage is in basis points (100_000 = 100%)
        uint256 amount0Min = (amount0 * (BASIS_POINTS - slippage)) / BASIS_POINTS;
        uint256 amount1Min = (amount1 * (BASIS_POINTS - slippage)) / BASIS_POINTS;

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
                amount0Min: amount0Min,
                amount1Min: amount1Min,
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
     * @param slippage Maximum slippage
     * @return pool Pool address
     */
    function _deployToVelo(
        address token,
        address routerAddress,
        uint256 tokenAmount,
        uint256 assetAmount,
        uint24 slippage
    ) internal returns (address pool) {
        // Check input addresses
        require(token != address(0), "Token address is zero");
        require(routerAddress != address(0), "Router address is zero");

        // Sort tokens
        (address token0, address token1) = token < assetToken ? (token, assetToken) : (assetToken, token);
        (uint256 amount0, uint256 amount1) = token < assetToken ? (tokenAmount, assetAmount) : (assetAmount, tokenAmount);
        
        // get factory or router
        IVelodromeRouter router = IVelodromeRouter(routerAddress);
        IVelodromeFactory veloFactory = IVelodromeFactory(router.factory());
        
        // Get or create pool
        bool stable = false;
        uint24 fee = 0;
        pool = veloFactory.getPool(token0, token1, fee);
        if (pool == address(0)) {
            pool = veloFactory.createPool(token0, token1, fee);
        }
        require(pool != address(0), "Pool creation succeeded");
        
        // Approve router to spend tokens
        IERC20(token0).forceApprove(routerAddress, amount0);
        IERC20(token1).forceApprove(routerAddress, amount1);

        // Calculate minimum amounts with slippage protection
        // slippage is in basis points (100_000 = 100%)
        uint256 amount0Min = (amount0 * (BASIS_POINTS - slippage)) / BASIS_POINTS;
        uint256 amount1Min = (amount1 * (BASIS_POINTS - slippage)) / BASIS_POINTS;

        // Add liquidity
        router.addLiquidity(
            token0,
            token1,
            stable,
            amount0,
            amount1,
            amount0Min,
            amount1Min,
            address(this),
            block.timestamp
        );

        // Verify final pool state
        return pool;
    }

    /**
     * @notice Routes fee collection to appropriate DEX handler
     * @param token Token address
     * @param pool Pool address
     * @param router Router/manager address
     * @param dexType Protocol identifier
     * @param fee Fee tier (UniV3)
     */
    function _collectFeesFromDex(
        address token,
        address pool,
        address router,
        DexType dexType,
        uint24 fee
    ) internal returns (uint256 tokenAmount, uint256 assetAmount) {
        if (dexType == DexType.UniswapV2) {
            return _collectFromV2(token, pool);
        } else if (dexType == DexType.UniswapV3) {
            return _collectFromV3(token, router);
        } else {
            return _collectFromVelo(token, pool);
        }
    }

    /**
     * @notice Collects fees from Uniswap V2 pool
     * @param token Token address
     * @param pool Pool address
     */
    function _collectFromV2(
        address token,
        address pool
    ) internal returns (uint256 tokenAmount, uint256 assetAmount) {
        // V2 fees are collected automatically when LPs remove liquidity
        // or when new liquidity is added, so no explicit collection needed
        return (0, 0);
    }

    /**
     * @notice Collects fees from Uniswap V3 pool
     * @param token Token address
     * @param posManager Position manager address
     */
    function _collectFromV3(
        address token,
        address posManager
    ) internal returns (uint256 tokenAmount, uint256 assetAmount) {
        INonfungiblePositionManager manager = INonfungiblePositionManager(posManager);
        
        // Get position ID for this pool
        uint256 tokenId; // Need to track/store position IDs
        if (tokenId == 0) return (0, 0);

        // Collect fees
        (tokenAmount, assetAmount) = manager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Map amounts to correct tokens
        if (token > assetToken) {
            (tokenAmount, assetAmount) = (assetAmount, tokenAmount);
        }
    }

    /**
     * @notice Collects fees from Velodrome pool
     * @param token Token address  
     * @param pool Pool address
     */
    function _collectFromVelo(
        address token,
        address pool
    ) internal returns (uint256 tokenAmount, uint256 assetAmount) {
        // Call claimFees() which returns (amount0, amount1)
        (uint256 amount0, uint256 amount1) = IVelodromePool(pool).claimFees();
        
        // Map returned amounts to token order (token0 is always the lower address)
        if (token > assetToken) {
            (tokenAmount, assetAmount) = (amount1, amount0);
        } else {
            (tokenAmount, assetAmount) = (amount0, amount1);
        }
    }
}