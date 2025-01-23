// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./BondingPair.sol";
import "./Token.sol";
import "./TaxVault.sol";
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
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Basis points denominator for percentage calculations (100%)
    uint256 private constant BASIS_POINTS = 100_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Bidirectional mapping of token addresses to their trading pairs
    mapping(address => mapping(address => address)) public getPair;

    /// @notice Maps token addresses to their tax vaults
    mapping(address => address) public getTokenTaxVault;

    /// @notice Sequential list of all created pair addresses for enumeration
    address[] public allPairs;

    /// @notice Router contract that handles trading operations
    IRouter public router;

    /// @notice TaxVault contract for collecting and distributing fees
    address public taxVault;

    /// @notice Initial token supply for new tokens (in whole tokens)
    uint256 public initialSupply;

    /// @notice Default minimum distribution amount for new vaults
    uint256 public defaultMinDistribution;

    /// @notice Platform treasury address that receives platform's share of taxes
    address public platformTreasury;

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

    /**
     * @notice Asset rate for scaling liquidity requirements
     * @dev Measured in basis points (1/100th of 1%)
     * Used to determine initial asset token requirements:
     * - 10000 = 10% (moderate liquidity)
     * - 20000 = 20% (higher liquidity)
     * - 5000 = 5% (lower liquidity)
     * Formula: requiredAssets = (assetRate * totalSupply) / BASIS_POINTS
     */
    uint64 public assetRate;

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
     * @param initialPrice Starting price calculated from K and supply
     */
    event Launch(
        address indexed token,
        address indexed pair,
        address indexed creator,
        string name,
        string symbol,
        uint256 initialPrice
    );

    /**
     * @notice Emitted when router address is updated
     * @param oldRouter Previous router address
     * @param newRouter New router address
     */
    event RouterUpdated(address oldRouter, address newRouter);

    /**
     * @notice Emitted when tax vault address is updated
     * @param oldVault Previous vault address
     * @param newVault New vault address
     */
    event TaxVaultUpdated(address oldVault, address newVault);

    /**
     * @notice Emitted when K constant is updated
     * @param oldK Previous K value
     * @param newK New K value
     */
    event KUpdated(uint256 oldK, uint256 newK);

    /**
     * @notice Emitted when asset rate is updated
     * @param oldRate Previous rate
     * @param newRate New rate
     */
    event AssetRateUpdated(uint64 oldRate, uint64 newRate);

    /**
     * @notice Emitted when initial supply is updated
     * @param oldSupply Previous supply amount
     * @param newSupply New supply amount
     */
    event InitialSupplyUpdated(uint256 oldSupply, uint256 newSupply);

    /**
     * @notice Emitted when a new tax vault is created
     * @param token Address of the new token contract
     * @param vault Address of the new tax vault contract
     */
    event VaultCreated(address indexed token, address indexed vault);

    /**
     * @notice Emitted when platform treasury address is updated
     * @param oldTreasury Previous treasury address
     * @param newTreasury New treasury address
     */
    event PlatformTreasuryUpdated(address oldTreasury, address newTreasury);

    /**
     * @notice Emitted when default minimum distribution amount is updated
     * @param oldAmount Previous minimum distribution amount
     * @param newAmount New minimum distribution amount
     */
    event MinDistributionUpdated(uint256 oldAmount, uint256 newAmount);

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
     * @param router_ Router contract address
     * @param initialSupply_ Initial token supply for new tokens
     * @param k_ Bonding curve constant (typical range: 1e17 to 1e19)
     * @param assetRate_ Required asset token rate in basis points
     * @param defaultMinDistribution_ Default minimum distribution amount
     * @param platformTreasury_ Platform treasury address
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
        address router_,
        uint256 initialSupply_,
        uint256 k_,
        uint64 assetRate_,
        uint256 defaultMinDistribution_,
        address platformTreasury_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        
        require(router_ != address(0), "Invalid router");
        require(initialSupply_ > 0, "Invalid initial supply");
        require(k_ > 0, "Invalid K");
        require(platformTreasury_ != address(0), "Invalid treasury");
        require(assetRate_ > 0 && assetRate_ <= BASIS_POINTS, "Invalid asset rate");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        router = IRouter(router_);
        initialSupply = initialSupply_;
        K = k_;
        assetRate = assetRate_;
        defaultMinDistribution = defaultMinDistribution_;
    }

    /*//////////////////////////////////////////////////////////////
                            LAUNCH FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new token and its corresponding bonding pair
     * @dev Main entry point for launching new AI agent tokens
     * 
     * This function orchestrates the complete token launch process:
     * 1. Creates a tax vault for fee collection and distribution
     * 2. Creates the actual token contract
     * 3. Creates a bonding pair for trading
     * 4. Sets up necessary approvals
     * 
     * The launch process implements a bonding curve mechanism where:
     * - Initial price = (K * BASIS_POINTS) / (initialSupply * assetRate)
     * - Price increases as supply decreases: price = K / supply
     * - Required asset tokens = (assetRate * totalSupply) / BASIS_POINTS
     * 
     * Example:
     * With K = 1e18, initialSupply = 1e6, assetRate = 10000 (10%):
     * - Initial price = (1e18 * 100000) / (1e6 * 10000) = 10000 (0.01 ETH)
     * - Initial asset requirement = (10000 * 1e6) / 100000 = 100 tokens
     * 
     * @param name Token name (e.g., "AI Agent Token")
     * @param symbol Token symbol (e.g., "AI")
     * @return token Address of the newly created token contract
     * @return pair Address of the newly created bonding pair contract
     */
    function launch(
        string calldata name,
        string calldata symbol
    ) external nonReentrant returns (address token, address pair) {
        // Create tax vault and token
        address vault = _createTaxVault(msg.sender);
        token = _createToken(name, symbol, vault);
        
        // Create trading pair
        address assetToken = router.assetToken();
        require(token != assetToken, "Invalid token pair");
        pair = _createPair(token, assetToken);

        // Setup approvals for router
        Token(token).approve(address(router), type(uint256).max);
        IERC20(assetToken).forceApprove(address(router), type(uint256).max);

        // Calculate and emit initial price
        uint256 initialPrice = (K * BASIS_POINTS) / (initialSupply * assetRate);
        emit Launch(token, pair, msg.sender, name, symbol, initialPrice);
    }

    /**
     * @notice Creates a new tax vault for token fee collection and distribution
     * @dev Sets up initial fee distribution between token creator and platform
     * 
     * The tax vault:
     * - Collects trading fees in the asset token (e.g., ETH)
     * - Distributes fees according to configured shares
     * - Initially splits fees 50/50 between creator and platform
     * - Can be reconfigured later through governance
     * 
     * @param creator Address of the token creator who receives creator share
     * @return vault Address of the created tax vault
     */
    function _createTaxVault(address creator) internal returns (address vault) {
        address[] memory initialRecipients = new address[](2);
        uint256[] memory initialShares = new uint256[](2);
        
        // Setup 50/50 split between creator and platform
        initialRecipients[0] = creator;
        initialRecipients[1] = platformTreasury;
        initialShares[0] = 50_000;  // 50%
        initialShares[1] = 50_000;  // 50%

        // Create and initialize vault
        TaxVault newVault = new TaxVault();
        newVault.initialize(
            router.assetToken(),
            address(this),
            defaultMinDistribution,
            initialRecipients,
            initialShares
        );

        vault = address(newVault);
        emit VaultCreated(address(0), vault); // Token address updated later
        return vault;
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
     * @param vault Address of the token's dedicated tax vault
     * @return token Address of the created token
     */
    function _createToken(
        string calldata name,
        string calldata symbol,
        address vault
    ) internal returns (address token) {
        // Create token with initial configuration
        Token newToken = new Token(
            name,
            symbol,
            initialSupply,
            address(router),
            vault
        );
        token = address(newToken);
        
        // Store vault mapping for token
        getTokenTaxVault[token] = vault;
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
     * @param tokenA First token in pair (typically AI agent token)
     * @param tokenB Second token in pair (typically asset token like ETH)
     * @return pair Address of the created bonding pair
     */
    function _createPair(
        address tokenA,
        address tokenB
    ) internal returns (address pair) {
        require(tokenA != tokenB, "Identical addresses");
        
        // Ensure consistent token ordering
        (address token0, address token1) = tokenA < tokenB 
            ? (tokenA, tokenB) 
            : (tokenB, tokenA);
            
        require(token0 != address(0), "Zero address");
        require(getPair[token0][token1] == address(0), "Pair exists");

        // Create bonding pair with K constant
        BondingPair newPair = new BondingPair(
            address(router),
            token0,
            token1,
            K,
            assetRate
        );
        pair = address(newPair);

        // Store bidirectional pair mappings
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        
        return pair;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the number of pairs created
    /// @return Number of pairs
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the router contract address
     * @param newRouter New router contract address
     */
    function setRouter(address newRouter) external onlyRole(ADMIN_ROLE) {
        require(newRouter != address(0), "Invalid router");
        emit RouterUpdated(address(router), newRouter);
        router = IRouter(newRouter);
    }

    /**
     * @notice Updates the tax vault address
     * @param newVault New tax vault address
     */
    function setTaxVault(address newVault) external onlyRole(ADMIN_ROLE) {
        require(newVault != address(0), "Invalid vault");
        emit TaxVaultUpdated(taxVault, newVault);
        taxVault = newVault;
    }

    /**
     * @notice Updates the K constant for future pairs
     * @param newK New K value
     * @dev Changing K affects only future pairs, not existing ones
     * Higher K = steeper price curve
     * Lower K = gentler price curve
     */
    function setK(uint256 newK) external onlyRole(ADMIN_ROLE) {
        require(newK > 0, "Invalid K");
        emit KUpdated(K, newK);
        K = newK;
    }

    /**
     * @notice Updates the asset rate for future pairs
     * @param newRate New rate in basis points
     * @dev Changing rate affects only future pairs, not existing ones
     * Higher rate = more initial liquidity required
     * Lower rate = less initial liquidity required
     */
    function setAssetRate(uint64 newRate) external onlyRole(ADMIN_ROLE) {
        require(newRate > 0 && newRate <= BASIS_POINTS, "Invalid rate");
        emit AssetRateUpdated(assetRate, newRate);
        assetRate = newRate;
    }

    /**
     * @notice Updates the initial supply for new tokens
     * @param newSupply New initial supply amount
     */
    function setInitialSupply(uint256 newSupply) external onlyRole(ADMIN_ROLE) {
        require(newSupply > 0, "Invalid supply");
        emit InitialSupplyUpdated(initialSupply, newSupply);
        initialSupply = newSupply;
    }

    /**
     * @notice Updates the default minimum distribution amount for new vaults
     * @param newAmount New minimum distribution amount
     */
    function setDefaultMinDistribution(uint256 newAmount) external onlyRole(ADMIN_ROLE) {
        emit MinDistributionUpdated(defaultMinDistribution, newAmount);
        defaultMinDistribution = newAmount;
    }

    /**
     * @notice Updates the platform treasury address
     * @param newTreasury New treasury address
     */
    function setPlatformTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury");
        emit PlatformTreasuryUpdated(platformTreasury, newTreasury);
        platformTreasury = newTreasury;
    }
}