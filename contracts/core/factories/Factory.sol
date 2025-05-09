// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// imports
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

// local imports
import "../base/Pair.sol";
import "../base/Airdrop.sol";
import "../../interfaces/IToken.sol";
import "../../interfaces/IRouter.sol";
import "../../interfaces/IManager.sol";
import "../../interfaces/ITokenFactory.sol";

/**
 * @title Factory
 * @dev Coordinates token launches using external contracts for token creation and trading
 * 
 * Core Components:
 * 1. External Contracts
 *    - TokenFactory: Creates new agent tokens
 *    - Router: Handles trading operations
 *    - Manager: Manages token lifecycle and graduation
 *    - Pair: Implements bonding curve mechanics
 * 
 * 2. Bonding Curve Configuration
 *    - K parameter determines price sensitivity
 *    - Higher K = steeper price changes (e.g., K = 1e19)
 *    - Lower K = gradual price changes (e.g., K = 1e17)
 *    - Price formula: P = K / supply
 * 
 * 3. Launch Process
 *    - Token creation via factory
 *    - Pair creation with configured K
 *    - Optional airdrop (max 5%)
 *    - Platform fee collection (1%)
 *    - Initial liquidity setup
 *    - First trade execution
 */
contract Factory is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Admin role for configuration updates
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Basis points denominator (100%)
    uint256 public constant BASIS_POINTS = 100_000;

    /// @notice Platform fee percentage (1%)
    uint256 public constant PLATFORM_FEE = 1_000;

    /// @notice Maximum initial trade size (75% of supply)
    uint256 public constant MAX_INITIAL_PURCHASE = 75_000;

    /// @notice Maximum airdrop allocation (5% of supply)
    uint256 public constant MAX_AIRDROP_PERCENTAGE = 5_000;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Optional token airdrop configuration
     * @param merkleRoot Hash root for verifying claims
     * @param claimantCount Number of eligible addresses
     * @param percentage Supply percentage for airdrop
     */
    struct AirdropParams {
        bytes32 merkleRoot;
        uint256 claimantCount;
        uint256 percentage;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Maps tokens to their trading pairs
    mapping(address => mapping(address => address)) public getPair;

    /// @notice Maps tokens to their airdrop contracts
    mapping(address => address) public tokenToAirdrop;

    /// @notice impactMultiplier for price calculation
    uint256 public impactMultiplier;

    /// @notice List of all created pair addresses
    address[] public allPairs;

    /// @notice Contract handling trades
    IRouter public router;

    /// @notice Contract managing token lifecycle
    IManager public manager;

    /// @notice Contract creating new tokens
    ITokenFactory public tokenFactory;

    /// @notice Address receiving platform fees
    address public platformTreasury;

    /// @notice Bonding curve steepness parameter
    uint256 public initialReserveAsset;

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAPS
    //////////////////////////////////////////////////////////////*/

    /// @dev Gap for future storage layout changes
    uint256[44] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Records new token launch
     * @param token New token address
     * @param pair Trading pair address
     * @param creator Launch initiator
     * @param name Token name
     * @param symbol Token symbol
     * @param airdrop Airdrop contract (if used)
     */
    event Launch(
        address indexed token,
        address indexed pair,
        address indexed creator,
        string name,
        string symbol,
        address airdrop
    );

    /**
     * @notice Emitted when impact multiplier is updated
     * @param newImpactMultiplier New impact multiplier value
     */
    event ImpactMultiplierUpdated(uint256 newImpactMultiplier);

    /**
     * @notice Emitted when initial reserve asset is updated
     * @param newInitialReserveAsset New initial reserve asset value
     */
    event InitialReserveAssetUpdated(uint256 newInitialReserveAsset);

    /**
     * @notice Emitted when platform treasury address is updated
     * @param newPlatformTreasury New platform treasury address
     */
    event PlatformTreasuryUpdated(address newPlatformTreasury);

    /**
     * @notice Emitted when manager contract is updated
     * @param newManager New manager contract address
     */
    event ManagerUpdated(address newManager);

    /**
     * @notice Emitted when router contract is updated
     * @param newRouter New router contract address
     */
    event RouterUpdated(address newRouter);

    /**
     * @notice Emitted when token factory contract is updated
     * @param newTokenFactory New token factory contract address
     */
    event TokenFactoryUpdated(address newTokenFactory);

    /**
     * @notice Emitted when a token's creator address is updated
     * @param token Token address
     * @param newCreator New creator address
     */
    event TokenCreatorUpdated(address token, address newCreator);

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
     * @notice Sets initial contract configuration
     * @param initialReserveAsset_ Initial reserve asset amount
     * @param impactMultiplier_ Impact multiplier for price calculation
     */
    function initialize(
        uint256 initialReserveAsset_,
        uint256 impactMultiplier_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        
        require(impactMultiplier_ > 0, "Invalid Impact Multiplier");
        require(initialReserveAsset_ > 0, "Invalid Initial Reserve");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        impactMultiplier = impactMultiplier_;
        initialReserveAsset = initialReserveAsset_;
        platformTreasury = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            LAUNCH FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Launches new agent token with bonding curve
     * @param name Token name
     * @param symbol Token symbol
     * @param url Reference URL
     * @param intention Token purpose
     * @param initialPurchase First trade size in asset tokens
     * @param dexConfigs DEX listing parameters
     * @param airdropParams Optional airdrop configuration
     * @return token New token address
     * @return pair New pair address
     */
    function launch(
        string calldata name,
        string calldata symbol,
        string calldata url,
        string calldata intention,
        uint256 initialPurchase,
        IManager.DexConfig[] calldata dexConfigs,
        AirdropParams calldata airdropParams
    ) external nonReentrant returns (address token, address pair) {
        IERC20 assetToken = IERC20(router.assetToken());
        
        // Create and configure token
        IToken agentToken = _createToken(name, symbol, url, intention);
        pair = _createPair(agentToken, assetToken);
        manager.registerAgent(address(agentToken), pair, url, intention, dexConfigs);
        
        // Setup token distribution
        uint256 liquiditySupply = _setupAirdropAndFees(agentToken, airdropParams);
        
        // Initialize trading
        _setupLiquidityAndTrading(
            agentToken, assetToken, initialPurchase, liquiditySupply
        );
        
        emit Launch(address(agentToken), pair, msg.sender, name, symbol, tokenToAirdrop[address(agentToken)]);
        return (address(agentToken), pair);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL SETUP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates new token via factory
     * @param name Token name
     * @param symbol Token symbol
     * @param url Token URL
     * @param intention Token purpose
     * @return IToken interface to new token
     */
    function _createToken(
        string calldata name,
        string calldata symbol,
        string calldata url,
        string calldata intention
    ) internal returns (IToken) {
        return IToken(tokenFactory.launch(
            name,
            symbol,
            url,
            intention,
            msg.sender
        ));
    }

    /**
     * @notice Creates bonding pair contract
     * @param agentToken Agent token interface
     * @param assetToken Asset token interface  
     * @return pair New pair address
     */
    function _createPair(
        IERC20 agentToken,
        IERC20 assetToken
    ) internal returns (address pair) {
        require(address(agentToken) != address(assetToken), "Identical addresses");

        Pair newPair = new Pair(
            address(router),
            address(agentToken),
            address(assetToken),
            initialReserveAsset,
            impactMultiplier
        );
        pair = address(newPair);

        getPair[address(agentToken)][address(assetToken)] = pair;
        getPair[address(assetToken)][address(agentToken)] = pair;
        allPairs.push(pair);
        
        return pair;
    }

    /**
     * @notice Sets up airdrop if enabled and collects platform fee
     * @param agentToken Token to distribute
     * @param params Airdrop configuration
     * @return liquiditySupply Remaining supply for liquidity
     */
    function _setupAirdropAndFees(
        IToken agentToken,
        AirdropParams calldata params
    ) internal returns (uint256) {
        uint256 liquiditySupply = agentToken.totalSupply();
        
        if (params.claimantCount > 0) {
            (,uint256 airdropAmount) = _createAirdrop(agentToken, params);
            liquiditySupply -= airdropAmount;
        }
        
        uint256 platformFee = (liquiditySupply * PLATFORM_FEE) / BASIS_POINTS;
        agentToken.transfer(platformTreasury, platformFee);
        liquiditySupply -= platformFee;

        return liquiditySupply;
    }

    /**
     * @notice Creates airdrop contract if enabled  
     * @param agentToken Token to airdrop
     * @param params Airdrop configuration
     * @return airdrop New airdrop contract address
     * @return airdropAmount Tokens allocated for airdrop
     */
    function _createAirdrop(
        IToken agentToken,
        AirdropParams calldata params
    ) internal returns (address airdrop, uint256 airdropAmount) {
        require(params.percentage > 0 && params.percentage <= MAX_AIRDROP_PERCENTAGE, "Invalid percentage");
        require(params.merkleRoot != bytes32(0), "Invalid merkle root");
        
        airdropAmount = (agentToken.totalSupply() * params.percentage) / BASIS_POINTS;
        
        Airdrop newAirdrop = new Airdrop(
            address(agentToken),
            params.merkleRoot,
            params.claimantCount
        );
        
        airdrop = address(newAirdrop);
        tokenToAirdrop[address(agentToken)] = airdrop;
        agentToken.transfer(airdrop, airdropAmount);

        return (airdrop, airdropAmount);
    }

    /**
     * @notice Sets up trading and executes first trade
     * @param agentToken Agent token interface
     * @param assetToken Asset token interface
     * @param initialPurchase Initial trade size
     * @param liquiditySupply Initial liquidity
     */
    function _setupLiquidityAndTrading(
        IToken agentToken,
        IERC20 assetToken,
        uint256 initialPurchase,
        uint256 liquiditySupply
    ) internal {
        agentToken.approve(address(router), type(uint256).max);
        assetToken.approve(address(router), initialPurchase);
        
        // transfer asset tokens to factory
        bool assetTransferSuccessful = assetToken.transferFrom(msg.sender, address(this), initialPurchase);

        // check if asset transfer was successful
        require(assetTransferSuccessful, "Asset transfer failed");

        // add initial liquidity
        router.addInitialLiquidity(address(agentToken), address(assetToken), liquiditySupply, 0);
        
        address[] memory path = new address[](2);
        path[0] = address(assetToken);
        path[1] = address(agentToken);

        uint256[] memory amounts = router.getAmountsOut(initialPurchase, path);
        require(amounts[1] <= ((agentToken.totalSupply() * MAX_INITIAL_PURCHASE) / BASIS_POINTS), "Initial purchase too large");
        
        router.swapExactTokensForTokens(
            initialPurchase,
            0,
            path,
            msg.sender,
            block.timestamp
        );
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS  
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates bonding curve parameter
     * @param impactMultiplier_ New impactMultiplier value for price calculation
     */
    function setImpactMultiplier(uint256 impactMultiplier_) external onlyRole(ADMIN_ROLE) {
        require(impactMultiplier_ > 0, "Invalid Impact Multiplier");
        require(impactMultiplier_ != impactMultiplier, "Identical Impact Multiplier");
        impactMultiplier = impactMultiplier_;

        emit ImpactMultiplierUpdated(impactMultiplier_);
    }

    /**
     * @notice Updates initial reserve asset
     * @param initialReserveAsset_ New K value for price calculation
     */
    function setInitialReserveAsset(uint256 initialReserveAsset_) external onlyRole(ADMIN_ROLE) {
        require(initialReserveAsset_ > 0, "Invalid asset reserve");
        require(initialReserveAsset_ != initialReserveAsset, "Identical asset reserve");
        initialReserveAsset = initialReserveAsset_;

        emit InitialReserveAssetUpdated(initialReserveAsset_);
    }

    /**
     * @notice Updates fee collection address
     * @param newPlatformTreasury New treasury address 
     */
    function setPlatformTreasury(address newPlatformTreasury) external onlyRole(ADMIN_ROLE) {
        require(newPlatformTreasury != address(0), "Invalid treasury");
        require(newPlatformTreasury != platformTreasury, "Identical treasury");
        platformTreasury = newPlatformTreasury;

        emit PlatformTreasuryUpdated(newPlatformTreasury);
    }

    /**
     * @notice Updates manager contract
     * @param manager_ New manager contract address
     */
    function setManager(address manager_) external onlyRole(ADMIN_ROLE) {
        require(manager_ != address(0), "Invalid manager");
        require(manager_ != address(manager), "Identical manager");
        manager = IManager(manager_);

        emit ManagerUpdated(manager_);
    }

    /**
     * @notice Updates router contract  
     * @param router_ New router contract address
     */
    function setRouter(address router_) external onlyRole(ADMIN_ROLE) {
        require(router_ != address(0), "Invalid router");
        require(router_ != address(router), "Identical router");
        router = IRouter(router_);

        emit RouterUpdated(router_);
    }

    /**
     * @notice Updates token factory contract
     * @param tokenFactory_ New factory contract address
     */
    function setTokenFactory(address tokenFactory_) external onlyRole(ADMIN_ROLE) {
        require(tokenFactory_ != address(0), "Invalid factory");
        require(tokenFactory_ != address(tokenFactory), "Identical factory");
        tokenFactory = ITokenFactory(tokenFactory_);

        emit TokenFactoryUpdated(tokenFactory_);
    }

    /**
     * @notice Sets creator address for existing token
     * @param token Token address
     * @param newCreator New creator address
     */
    function setTokenCreator(address token, address newCreator) external onlyRole(ADMIN_ROLE) {
        IToken(token).setCreator(newCreator);

        emit TokenCreatorUpdated(token, newCreator);
    }
}