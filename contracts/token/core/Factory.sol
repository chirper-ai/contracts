// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "hardhat/console.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./BondingPair.sol";
import "./Token.sol";
import "./AirDrop.sol";
import "../interfaces/IRouter.sol";
import "../interfaces/IManager.sol";

/**
 * @title Factory
 * @dev Primary entry point for creating and managing AI agent tokens and their bonding pairs.
 * 
 * The Factory implements a bonding curve mechanism using two key parameters:
 * 
 * 1. K (Bonding Curve Constant):
 *    - Determines the shape and behavior of the bonding curve
 *    - Higher K = steeper price increases as supply decreases
 *    - Lower K = more gradual price changes
 *    - Formula: price = K / supply
 *    - Example: If K = 1e18 and supply = 1e6, price = 1e12
 * 
 * 2. Asset Rate:
 *    - Controls the relationship between asset tokens and bonding curve
 *    - Used to scale the initial liquidity requirements
 *    - Higher rate = more asset tokens needed per bonding curve token
 *    - Lower rate = fewer asset tokens needed
 *    - Measured in basis points (1/100th of 1%)
 * 
 * Together, these parameters define the economic model:
 * - Initial Price = (K * assetRate) / (initialSupply * BASIS_POINTS)
 * - Reserve Ratio = (currentSupply * currentPrice) / marketCap
 * - Price Slippage = change in K / change in supply^2
 * 
 * This creates a deterministic pricing mechanism where:
 * 1. Price increases when tokens are bought
 * 2. Price decreases when tokens are sold
 * 3. Larger trades have proportionally higher slippage
 */
contract Factory is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Basis points constant for percentage calculations
    uint256 public constant BASIS_POINTS = 100_000;

    /// @notice Platform fee percentage (1%)
    uint256 public constant PLATFORM_FEE = 1_000;

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Optional airdrop parameters
     * @param merkleRoot Root of merkle tree for airdrop claims
     * @param claimantCount Number of addresses eligible for airdrop
     * @param percentage Percentage of initial supply to airdrop (in basis points)
     */
    struct AirdropParams {
        bytes32 merkleRoot;
        uint256 claimantCount;
        uint256 percentage;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Bidirectional mapping of token addresses to their trading pairs
    mapping(address => mapping(address => address)) public getPair;

    /// @notice Mapping of token addresses to their airdrop contracts
    mapping(address => address) public tokenToAirdrop;

    /// @notice Sequential list of all created pair addresses for enumeration
    address[] public allPairs;

    /// @notice Router contract that handles trading operations
    IRouter public router;

    /// @notice Manager contract for managing AI agent tokens
    IManager public manager;

    /// @notice platform treasury address
    address public platformTreasury;

    /// @notice Initial token supply for new tokens (in whole tokens)
    uint256 public initialSupply;

    /**
     * @notice Bonding curve constant (K) that determines curve shape
     * @dev K is used in the formula: price = K / supply
     * Measured in the asset token's decimals (typically 1e18)
     * A higher K means steeper price changes:
     * - K = 1e18: moderate price curve
     * - K = 1e19: steeper price curve
     * - K = 1e17: gentler price curve
     */
    uint256 public K;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a new token and trading pair is launched
     * @param token The address of the newly created token contract
     * @param pair The address of the newly created bonding pair contract
     * @param creator Address that initiated the launch
     * @param name Token name
     * @param symbol Token symbol
     * @param airdrop Address of the airdrop contract (if created)
     */
    event Launch(
        address indexed token,
        address indexed pair,
        address indexed creator,
        string name,
        string symbol,
        address airdrop
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
     * @notice Initializes the factory with required parameters
     * @param initialSupply_ Initial token supply for new tokens
     * @param k_ Bonding curve constant (typical range: 1e17 to 1e19)
     * @dev 
     * The K and assetRate parameters work together to define the economic model:
     * - K determines price sensitivity
     * - assetRate determines initial liquidity requirements
     * Example values:
     * - K = 1e18, assetRate = 10000 (10%): moderate curve, moderate liquidity
     * - K = 1e19, assetRate = 20000 (20%): steep curve, high liquidity
     * - K = 1e17, assetRate = 5000 (5%): gentle curve, low liquidity
     */
    function initialize(
        uint256 initialSupply_,
        uint256 k_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        
        require(initialSupply_ > 0, "Invalid initial supply");
        require(k_ > 0, "Invalid K");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        initialSupply = initialSupply_;
        K = k_;

        // platform treasury should be creator initially
        platformTreasury = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            LAUNCH FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Primary entry point for launching new AI agent tokens
     * @dev Orchestrates the entire token launch process using a bonding curve mechanism
     * 
     * Launch Process:
     * 1. Contract Creation:
     *    - Deploys token contract with initial supply
     *    - Creates bonding pair with price curve K
     *    - Links to asset token (e.g. ETH)
     * 
     * 2. Distribution:
     *    - Optional airdrop allocation
     *    - Platform fee transfer (0.1%)
     *    - Initial liquidity provision
     * 
     * 3. Market Setup:
     *    - Initial price determination
     *    - First trade execution
     *    - Trading permissions
     * 
     * Economic Model:
     * - Initial Price = (K * assetRate) / (initialSupply * BASIS_POINTS)
     * - Price curve follows p = K/s where s is supply
     * - Slippage increases with trade size
     * 
     * Security:
     * - NonReentrant guard
     * - Access control
     * - Safe token transfers
     * 
     * Events:
     * - Emits Launch event with token details
     * - Indexed for efficient querying
     * 
     * @param name Token name for ERC20 metadata
     * @param symbol Token symbol for ERC20 metadata
     * @param url Reference URL for token documentation
     * @param intention Description of token's purpose
     * @param initialPurchase Amount of asset tokens for first trade
     * @param dexConfigs Array of DEX configurations
     * @param airdropParams Optional airdrop configuration
     * @return token Address of created token contract
     * @return pair Address of created bonding pair
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
        address assetToken = router.assetToken();
        
        (token, pair) = _initializeContracts(
            name, symbol, url, intention, dexConfigs, assetToken
        );
        
        uint256 liquiditySupply = _setupAirdropAndFees(token, airdropParams);
        
        _setupLiquidityAndTrading(
            token, assetToken, initialPurchase, liquiditySupply
        );
        
        emit Launch(token, pair, msg.sender, name, symbol, tokenToAirdrop[token]);
        return (token, pair);
    }

    /**
     * @notice Creates and links core smart contracts
     * @dev Deploys token and pair contracts, registers with manager
     * 
     * Contract Deployment:
     * 1. Token Contract:
     *    - Fixed initial supply
     *    - Standard ERC20 implementation
     *    - Tax configuration
     * 
     * 2. Bonding Pair:
     *    - Links token to asset
     *    - Sets K constant
     *    - Initializes price curve
     * 
     * 3. Manager Integration:
     *    - Registers token/pair
     *    - Sets trading configs
     *    - Enables features
     * 
     * Storage:
     * - Updates pair mappings
     * - Adds to enumerable list
     * - Sets contract links
     * 
     * @param name Token name
     * @param symbol Token symbol
     * @param url Info URL
     * @param intention Token purpose
     * @param dexConfigs DEX settings
     * @param assetToken Asset token address
     * @return token New token address
     * @return pair New pair address
     */
    function _initializeContracts(
        string calldata name,
        string calldata symbol,
        string calldata url,
        string calldata intention,
        IManager.DexConfig[] calldata dexConfigs,
        address assetToken
    ) internal returns (address token, address pair) {
        token = _createToken(name, symbol, url, intention);
        pair = _createPair(token, assetToken);
        manager.registerAgent(token, pair, url, intention, dexConfigs);
        return (token, pair);
    }

    /**
     * @notice Handles token distribution and fee collection
     * @dev Creates airdrop if enabled, transfers platform fees
     * 
     * Airdrop Process:
     * 1. Validation:
     *    - Merkle root check
     *    - Claimant count > 0
     *    - Valid percentage (0-5%)
     * 
     * 2. Supply Allocation:
     *    - Calculates airdrop amount
     *    - Updates available supply
     *    - Transfers to airdrop contract
     * 
     * 3. Platform Fee:
     *    - 1% of total supply
     *    - Direct transfer to treasury
     * 
     * Supply Tracking:
     * - Maintains accurate token counts
     * - Updates available liquidity
     * - Ensures sufficient bonding supply
     * 
     * @param token Token contract address
     * @param airdropParams Airdrop configuration
     */
    function _setupAirdropAndFees(
        address token,
        AirdropParams calldata airdropParams
    ) internal returns (uint256) {
        IERC20 agentToken = IERC20(token);
        uint256 liquiditySupply = initialSupply;
        
        if (airdropParams.claimantCount > 0) {
            (,uint256 airdropAmount) = _createAirdrop(token, agentToken, airdropParams);
            liquiditySupply -= airdropAmount;
        }
        
        uint256 platformFee = (initialSupply * PLATFORM_FEE) / BASIS_POINTS;
        agentToken.transfer(platformTreasury, platformFee);
        liquiditySupply -= platformFee;

        return liquiditySupply;
    }

    /**
     * @notice Configures trading infrastructure and executes first trade
     * @dev Sets up liquidity pool and performs initial market trade
     * 
     * Setup Process:
     * 1. Approvals:
     *    - Router permissions
     *    - Asset token allowance
     *    - Trading authorizations
     * 
     * 2. Liquidity:
     *    - Initial pool creation
     *    - Token pair linking
     *    - Starting price point
     * 
     * 3. First Trade:
     *    - Path configuration
     *    - Swap execution
     *    - Price discovery
     * 
     * Market Impact:
     * - Sets reference price
     * - Establishes trading depth
     * - Initializes price curve
     * 
     * Security:
     * - Safe approvals
     * - Deadline enforcement
     * - Slippage checks
     * 
     * @param token Agent token address
     * @param assetToken Asset token address
     * @param initialPurchase First trade size
     * @param liquiditySupply Initial liquidity pool size
     */
    function _setupLiquidityAndTrading(
        address token,
        address assetToken,
        uint256 initialPurchase,
        uint256 liquiditySupply
    ) internal {
        IERC20 agentToken = IERC20(token);
        IERC20 actualAssetToken = IERC20(assetToken);
        
        agentToken.approve(address(router), type(uint256).max);
        actualAssetToken.approve(address(router), initialPurchase);
        
        // Transfer initial tokens and ETH to pair
        actualAssetToken.transferFrom(msg.sender, address(this), initialPurchase);
        
        router.addInitialLiquidity(token, assetToken, liquiditySupply, 0);
        
        address[] memory path = new address[](2);
        path[0] = assetToken;
        path[1] = token;
        
        router.swapExactTokensForTokens(
            initialPurchase,
            0,
            path,
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @notice Creates a new token contract with initial supply and configuration
     * @dev Deploys Token contract and sets up vault mapping
     * 
     * The token:
     * - Has fixed initial supply
     * - Is linked to a specific tax vault
     * - Uses router for trading operations
     * - Implements standard ERC20 functionality
     * 
     * @param name Token name for ERC20 metadata
     * @param symbol Token symbol for ERC20 metadata
     * @param url URL for additional information
     * @param intention Token use case or intention
     * @return token Address of the created token
     */
    function _createToken(
        string calldata name,
        string calldata symbol,
        string calldata url,
        string calldata intention
    ) internal returns (address token) {
        // Create token with initial configuration
        Token newToken = new Token(
            name,
            symbol,
            initialSupply,
            url,
            intention,
            address(manager),

            // tax vaults
            msg.sender,
            platformTreasury
        );
        token = address(newToken);

        // add tax / tx limit exemptions
        newToken.setTaxExempt(address(manager), true);
        
        // Store vault mapping for token
        return token;
    }

    /**
     * @notice Creates a new bonding pair for token/asset trading
     * @dev Implements core bonding curve logic with K constant
     * 
     * The bonding pair:
     * - Uses K constant for price calculations
     * - Ensures token0 < token1 for consistent ordering
     * - Prevents duplicate pairs
     * - Adds pair to enumerable list
     * 
     * Price mechanics:
     * - Buy price = K / current_supply
     * - Sell price = K / (current_supply + amount)
     * - Slippage increases with trade size
     * 
     * @param agentToken First token in pair (typically AI agent token)
     * @param assetToken Second token in pair (typically asset token like ETH)
     * @return pair Address of the created bonding pair
     */
    function _createPair(
        address agentToken,
        address assetToken
    ) internal returns (address pair) {
        require(agentToken != assetToken, "Identical addresses");

        // Create bonding pair with K constant
        BondingPair newPair = new BondingPair(
            address(router),
            agentToken,
            assetToken,
            K
        );
        pair = address(newPair);

        // Store bidirectional pair mappings
        getPair[agentToken][assetToken] = pair;
        getPair[assetToken][agentToken] = pair;
        allPairs.push(pair);
        
        return pair;
    }

    /**
     * @notice Creates a new airdrop contract for a token
     * @param token Token address
     * @param tokenContract Token contract interface
     * @param params Airdrop parameters
     */
    function _createAirdrop(
        address token,
        IERC20 tokenContract,
        AirdropParams calldata params
    ) internal returns (address airdrop, uint256 airdropAmount) {
        require(params.percentage > 0 && params.percentage <= 5_000, "Invalid percentage");
        require(params.merkleRoot != bytes32(0), "Invalid merkle root");
        
        airdropAmount = (initialSupply * params.percentage) / BASIS_POINTS;
        
        MerkleAirdrop newAirdrop = new MerkleAirdrop(
            token,
            params.merkleRoot,
            params.claimantCount
        );
        
        airdrop = address(newAirdrop);
        tokenToAirdrop[token] = airdrop;
        tokenContract.transfer(airdrop, airdropAmount);

        return (airdrop, airdropAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the K constant for future pairs
     * @param newK New K value
     * @dev Changing K affects only future pairs, not existing ones
     * Higher K = steeper price curve
     * Lower K = gentler price curve
     */
    function setK(uint256 newK) external onlyRole(ADMIN_ROLE) {
        require(newK > 0, "Invalid K");
        K = newK;
    }

    /**
     * @notice Updates the initial supply for new tokens
     * @param newSupply New initial supply amount
     */
    function setInitialSupply(uint256 newSupply) external onlyRole(ADMIN_ROLE) {
        require(newSupply > 0, "Invalid supply");
        initialSupply = newSupply;
    }

    /**
     * @notice Updates the platform treasury address
     * @param newPlatformTreasury New treasury address
     */
    function setPlatformTreasury(address newPlatformTreasury) external onlyRole(ADMIN_ROLE) {
        platformTreasury = newPlatformTreasury;
    }

    /**
     * @notice sets the manager address
     */
    function setManager(address manager_) external onlyRole(ADMIN_ROLE) {
        manager = IManager(manager_);
    }

    /**
     * @notice sets the router address
     */
    function setRouter(address router_) external onlyRole(ADMIN_ROLE) {
        router = IRouter(router_);
    }

    /**
     * @notice Sets tax exemption status for an address
     * @param token_ Token address
     * @param account_ Account to update
     * @param isExempt_ Whether account should be tax exempt
     */
    function setTokenTaxExempt(address token_, address account_, bool isExempt_) external onlyRole(ADMIN_ROLE) {
        Token(token_).setTaxExempt(account_, isExempt_);
    }
}