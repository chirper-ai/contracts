// file: contracts/core/BondingManager.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./GraduatedToken.sol";
import "../interfaces/IDEXAdapter.sol";

/**
 * @title BondingManager
 * @author YourName
 * @notice Manages bonding curve lifecycle and graduation to DEX
 * @dev Core contract for token launches and DEX transitions
 */
contract BondingManager is 
    Initializable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    using SafeERC20 for IERC20;

    /// @notice Configuration for bonding curves
    struct CurveConfig {
        uint256 initialPrice;      // Starting price in base asset
        uint256 gradThreshold;     // Asset amount for graduation
        address[] dexAdapters;     // Approved DEX adapters
        uint256[] dexWeights;      // Weight for each DEX (must sum to 100)
    }

    /// @notice Data for active bonding curves
    struct CurveData {
        address token;             // Token address
        uint256 supply;           // Current supply
        uint256 balance;          // Current asset balance
        uint256 price;            // Current price
        bool graduated;           // Whether graduated
        address[] dexPairs;       // Active DEX pairs after graduation
    }

    /// @notice Base asset for all curves (e.g. USDC)
    IERC20 public baseAsset;

    /// @notice Default configuration for new curves
    CurveConfig public defaultConfig;

    /// @notice Maps token address to curve data
    mapping(address => CurveData) public curves;

    /// @notice List of all launched tokens
    address[] public tokens;

    /// @dev Emitted when a new token is launched
    event TokenLaunched(
        address indexed token,
        string name,
        string symbol,
        uint256 initialPrice
    );

    /// @dev Emitted when a trade occurs
    event Trade(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 assetAmount,
        uint256 tokenAmount
    );

    /// @dev Emitted when a token graduates to DEX
    event TokenGraduated(
        address indexed token,
        address[] dexPairs,
        uint256[] amounts
    );

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the bonding manager
     * @param baseAsset_ Base asset address
     * @param config Initial curve configuration
     */
    function initialize(
        address baseAsset_,
        CurveConfig calldata config
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();

        require(baseAsset_ != address(0), "Invalid base asset");
        _validateConfig(config);

        baseAsset = IERC20(baseAsset_);
        defaultConfig = config;
    }

    /**
     * @notice Launches a new token with bonding curve
     * @param name Token name
     * @param symbol Token symbol
     * @return token Address of the new token
     */
    function launchToken(
        string calldata name,
        string calldata symbol
    ) external nonReentrant whenNotPaused returns (address token) {
        // Deploy new token
        GraduatedToken newToken = new GraduatedToken();
        newToken.initialize(name, symbol, address(this));
        
        // Initialize curve data
        CurveData storage curve = curves[address(newToken)];
        curve.token = address(newToken);
        curve.price = defaultConfig.initialPrice;
        
        tokens.push(address(newToken));

        emit TokenLaunched(
            address(newToken),
            name,
            symbol,
            defaultConfig.initialPrice
        );

        return address(newToken);
    }

    /**
     * @notice Buy tokens from the bonding curve
     * @param token Token address
     * @param assetAmount Amount of base asset to spend
     * @return tokenAmount Amount of tokens received
     */
    function buy(
        address token,
        uint256 assetAmount
    ) external nonReentrant whenNotPaused returns (uint256 tokenAmount) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        require(!curve.graduated, "Token graduated");

        // Calculate tokens to receive
        tokenAmount = (assetAmount * 1e18) / curve.price;

        // Transfer assets
        baseAsset.safeTransferFrom(msg.sender, address(this), assetAmount);

        // Update curve state
        curve.supply += tokenAmount;
        curve.balance += assetAmount;
        curve.price = (curve.balance * 1e18) / curve.supply;

        // Mint tokens
        GraduatedToken(curve.token).mint(msg.sender, tokenAmount);

        emit Trade(token, msg.sender, true, assetAmount, tokenAmount);

        // Check graduation threshold
        if (curve.balance >= defaultConfig.gradThreshold) {
            _graduate(token);
        }
    }

    /**
     * @notice Sell tokens back to the bonding curve
     * @param token Token address
     * @param tokenAmount Amount of tokens to sell
     * @return assetAmount Amount of base asset received
     */
    function sell(
        address token,
        uint256 tokenAmount
    ) external nonReentrant whenNotPaused returns (uint256 assetAmount) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        require(!curve.graduated, "Token graduated");

        // Calculate assets to receive
        assetAmount = (tokenAmount * curve.price) / 1e18;

        // Burn tokens
        GraduatedToken(curve.token).burn(msg.sender, tokenAmount);

        // Update curve state
        curve.supply -= tokenAmount;
        curve.balance -= assetAmount;
        if (curve.supply > 0) {
            curve.price = (curve.balance * 1e18) / curve.supply;
        }

        // Transfer assets
        baseAsset.safeTransfer(msg.sender, assetAmount);

        emit Trade(token, msg.sender, false, assetAmount, tokenAmount);
    }

    /**
     * @notice Internal function to graduate token to DEX
     * @param token Token to graduate
     */
    function _graduate(address token) internal {
        CurveData storage curve = curves[token];
        require(!curve.graduated, "Already graduated");

        uint256[] memory amounts = new uint256[](defaultConfig.dexAdapters.length);
        address[] memory pairs = new address[](defaultConfig.dexAdapters.length);

        // Calculate total liquidity
        uint256 totalSupply = curve.supply;
        uint256 totalBalance = curve.balance;

        // Add liquidity to each DEX
        for (uint i = 0; i < defaultConfig.dexAdapters.length; i++) {
            IDEXAdapter adapter = IDEXAdapter(defaultConfig.dexAdapters[i]);
            uint256 assetAmount = (totalBalance * defaultConfig.dexWeights[i]) / 100;
            uint256 tokenAmount = (totalSupply * defaultConfig.dexWeights[i]) / 100;

            // Approve tokens
            IERC20(token).approve(adapter.getRouterAddress(), tokenAmount);
            baseAsset.approve(adapter.getRouterAddress(), assetAmount);

            // Add liquidity
            (uint256 amountA, uint256 amountB, ) = adapter.addLiquidity(
                IDEXAdapter.LiquidityParams({
                    tokenA: token,
                    tokenB: address(baseAsset),
                    amountA: tokenAmount,
                    amountB: assetAmount,
                    minAmountA: tokenAmount * 95 / 100, // 5% slippage
                    minAmountB: assetAmount * 95 / 100,
                    to: msg.sender,
                    deadline: block.timestamp + 300
                })
            );

            amounts[i] = amountB;
            pairs[i] = adapter.getPair(token, address(baseAsset));
        }

        // Update state
        curve.graduated = true;
        curve.dexPairs = pairs;
        GraduatedToken(token).graduate();

        emit TokenGraduated(token, pairs, amounts);
    }

    /**
     * @notice Updates the default configuration
     * @param config New configuration
     */
    function setDefaultConfig(CurveConfig calldata config) external onlyOwner {
        _validateConfig(config);
        defaultConfig = config;
    }

    /**
     * @notice Validates curve configuration
     * @param config Configuration to validate
     */
    function _validateConfig(CurveConfig memory config) internal pure {
        require(config.initialPrice > 0, "Invalid price");
        require(config.gradThreshold > 0, "Invalid threshold");
        require(
            config.dexAdapters.length == config.dexWeights.length,
            "Length mismatch"
        );
        
        uint256 totalWeight;
        for (uint i = 0; i < config.dexWeights.length; i++) {
            totalWeight += config.dexWeights[i];
        }
        require(totalWeight == 100, "Invalid weights");
    }

    /**
     * @notice Returns current price for a token
     * @param token Token address
     * @return price Current price
     */
    function getPrice(address token) external view returns (uint256) {
        CurveData storage curve = curves[token];
        require(curve.token != address(0), "Token not found");
        return curve.price;
    }

    /**
     * @notice Pauses all operations
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all operations
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}