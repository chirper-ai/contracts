// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import "./Factory.sol";
import "./IPair.sol";
import "./Router.sol";
import "./Token.sol";

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
    uint256 public constant K = 3_000_000_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V2 Router contract interface
    IUniswapV2Router02 public uniswapRouter;

    /// @notice Maximum transaction percentage (1-100)
    uint256 public maxTxPercent;

    /// @notice Factory contract for creating token pairs
    Factory public factory;

    /// @notice Router contract for token trading operations
    Router public router;

    /// @notice Initial token supply for new agent tokens
    uint256 public initialSupply;

    /// @notice Rate used in asset requirement calculations
    uint256 public assetRate;

    /// @notice Percentage threshold required for graduation eligibility
    uint256 public gradThresholdPercent;

    /*//////////////////////////////////////////////////////////////
                                  STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Comprehensive metrics tracking for an agent token
     * @param token Address of the token contract
     * @param name Full name of the token including "agent" suffix
     * @param baseName Original name without suffix
     * @param ticker Trading symbol for the token
     * @param supply Total token supply
     * @param price Current token price
     * @param mktCap Market capitalization
     * @param liq Total liquidity
     * @param vol Lifetime trading volume
     * @param vol24h Rolling 24-hour trading volume
     * @param lastPrice Price at last update
     * @param lastUpdate Timestamp of last metrics update
     */
    struct TokenMetrics {
        address token;
        string name;
        string baseName;
        string ticker;
        uint256 supply;
        uint256 price;
        uint256 mktCap;
        uint256 liq;
        uint256 vol;
        uint256 vol24h;
        uint256 lastPrice;
        uint256 lastUpdate;
    }

    /**
     * @notice Comprehensive data structure for an AI agent token
     * @param creator Address that created the token
     * @param token Address of the token contract
     * @param pair Address of the primary trading pair
     * @param prompt Description of the agent's behavior
     * @param intention Stated purpose of the agent
     * @param url Reference URL for the agent
     * @param metrics Current token metrics
     * @param isTrading Whether trading is currently enabled
     * @param hasGraduated Whether token has graduated to Uniswap
     */
    struct TokenData {
        address creator;
        address token;
        address pair;
        string prompt;
        string intention;
        string url;
        TokenMetrics metrics;
        bool isTrading;
        bool hasGraduated;
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
     * @param assetRateValue_ Asset rate for calculations
     * @param gradThresholdPercent_ Graduation threshold percentage
     * @param maxTxPercent_ Maximum transaction percentage
     * @param uniswapRouterAddress_ Address of Uniswap V2 Router
     */
    function initialize(
        address factory_,
        address router_,
        uint256 initSupply_,
        uint256 assetRateValue_,
        uint256 gradThresholdPercent_,
        uint256 maxTxPercent_,
        address uniswapRouterAddress_
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        
        require(maxTxPercent_ <= 100, "Max transaction cannot exceed 100%");
        require(factory_ != address(0), "Invalid factory");
        require(router_ != address(0), "Invalid router");

        factory = Factory(factory_);
        router = Router(router_);
        initialSupply = initSupply_;
        assetRate = assetRateValue_;
        gradThresholdPercent = gradThresholdPercent_;
        maxTxPercent = maxTxPercent_;
        uniswapRouter = IUniswapV2Router02(uniswapRouterAddress_);
    }

    /*//////////////////////////////////////////////////////////////
                         CORE TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates and launches a new agent token
     * @param name_ Base name for the token
     * @param ticker_ Trading symbol
     * @param prompt_ Agent's behavioral description
     * @param intention_ Agent's purpose
     * @param url_ Reference URL
     * @param purchaseAmount_ Initial purchase amount
     * @return token Token address
     * @return pair Pair address
     * @return index Token index in list
     */
    function launch(
        string memory name_,
        string memory ticker_,
        string memory prompt_,
        string memory intention_,
        string memory url_,
        uint256 purchaseAmount_
    ) external nonReentrant returns (address token, address pair, uint256 index) {
        address assetToken_ = router.assetToken();
        require(
            IERC20(assetToken_).balanceOf(msg.sender) >= purchaseAmount_,
            "Insufficient funds"
        );

        uint256 launchTax = (purchaseAmount_ * factory.launchTax()) / 10000;
        uint256 initialPurchase = purchaseAmount_ - launchTax;
        
        // Transfer launch tax to tax vault
        IERC20(assetToken_).safeTransferFrom(msg.sender, factory.taxVault(), launchTax);
        IERC20(assetToken_).safeTransferFrom(
            msg.sender,
            address(this),
            initialPurchase
        );

        // Create token with factory reference
        Token actualToken = new Token(
            string.concat(name_, "agent"), 
            ticker_,
            initialSupply,
            maxTxPercent,
            address(factory),
            address(this)
        );
        uint256 supply = actualToken.totalSupply();

        address newPair = factory.createPair(address(actualToken), assetToken_);

        require(_approve(address(router), address(actualToken), supply));

        uint256 k = ((K * 10000) / assetRate);
        uint256 liquidity = (((k * 10000 ether) / supply) * 1 ether) / 10000;

        router.addInitialLiquidity(address(actualToken), supply, liquidity);

        TokenMetrics memory metrics = TokenMetrics({
            token: address(actualToken),
            name: string.concat(name_, "agent"),
            baseName: name_,
            ticker: ticker_,
            supply: supply,
            price: supply / liquidity,
            mktCap: liquidity,
            liq: liquidity * 2,
            vol: 0,
            vol24h: 0,
            lastPrice: supply / liquidity,
            lastUpdate: block.timestamp
        });

        TokenData memory localToken = TokenData({
            creator: msg.sender,
            token: address(actualToken),
            pair: newPair,
            prompt: prompt_,
            intention: intention_,
            url: url_,
            metrics: metrics,
            isTrading: true,
            hasGraduated: false
        });

        agentTokens[address(actualToken)] = localToken;
        agentTokenList.push(address(actualToken));

        uint256 tokenIndex = agentTokenList.length;

        emit Launched(address(actualToken), newPair, tokenIndex);

        IERC20(assetToken_).forceApprove(address(router), initialPurchase);
        router.buy(initialPurchase, address(actualToken), address(this));
        actualToken.transfer(msg.sender, actualToken.balanceOf(address(this)));

        return (address(actualToken), newPair, tokenIndex);
    }

    /**
     * @notice Executes a buy order for agent tokens
     * @param amountIn_ Amount of asset tokens to spend
     * @param tokenAddress_ Address of token to buy
     * @return success Whether the operation succeeded
     */
    function buy(
        uint256 amountIn_,
        address tokenAddress_
    ) external payable returns (bool) {
        require(agentTokens[tokenAddress_].isTrading, "Trading not active");

        address pairAddress = factory.getPair(
            tokenAddress_,
            router.assetToken()
        );

        IPair pair = IPair(pairAddress);
        (uint256 reserveA, uint256 reserveB) = pair.getReserves();

        (uint256 amount1In, uint256 amount0Out) = router.buy(
            amountIn_,
            tokenAddress_,
            msg.sender
        );

        uint256 newReserveA = reserveA - amount0Out;
        uint256 newReserveB = reserveB + amount1In;

        _updateMetrics(
            tokenAddress_,
            newReserveA,
            newReserveB,
            amount1In
        );

        uint256 totalSupply = IERC20(tokenAddress_).totalSupply();
        require(totalSupply > 0, "Invalid total supply");

        uint256 reservePercentage = (newReserveA * 100) / totalSupply;
        
        if (reservePercentage <= gradThresholdPercent) {
            _graduate(tokenAddress_);
        }

        return true;
    }

    /**
     * @notice Executes a sell order for agent tokens
     * @param amountIn_ Amount of tokens to sell
     * @param tokenAddress_ Address of token to sell
     * @return success Whether the operation succeeded
     */
    function sell(
        uint256 amountIn_,
        address tokenAddress_
    ) external returns (bool) {
        require(agentTokens[tokenAddress_].isTrading, "Trading not active");

        address pairAddress = factory.getPair(
            tokenAddress_,
            router.assetToken()
        );

        IPair pair = IPair(pairAddress);
        (uint256 reserveA, uint256 reserveB) = pair.getReserves();
        
        (uint256 amount0In, uint256 amount1Out) = router.sell(
            amountIn_,
            tokenAddress_,
            msg.sender
        );

        _updateMetrics(
            tokenAddress_,
            reserveA + amount0In,
            reserveB - amount1Out,
            amount1Out
        );

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates token metrics after a trade
     * @param tokenAddress_ Address of the token
     * @param newReserveA_ New reserve of token A
     * @param newReserveB_ New reserve of token B
     * @param amount_ Amount involved in trade
     */
    function _updateMetrics(
        address tokenAddress_,
        uint256 newReserveA_,
        uint256 newReserveB_,
        uint256 amount_
    ) private {
        TokenData storage token = agentTokens[tokenAddress_];
        uint256 duration = block.timestamp - token.metrics.lastUpdate;
        
        uint256 liquidity = newReserveB_ * 2;
        uint256 marketCap = (token.metrics.supply * newReserveB_) / newReserveA_;
        uint256 price = newReserveA_ / newReserveB_;
        uint256 volume = duration > 86400
            ? amount_
            : token.metrics.vol24h + amount_;
        uint256 lastPrice = duration > 86400
            ? token.metrics.price
            : token.metrics.lastPrice;

        token.metrics.price = price;
        token.metrics.mktCap = marketCap;
        token.metrics.liq = liquidity;
        token.metrics.vol = token.metrics.vol + amount_;
        token.metrics.vol24h = volume;
        token.metrics.lastPrice = lastPrice;

        if (duration > 86400) {
            token.metrics.lastUpdate = block.timestamp;
        }
    }

    /**
     * @notice Internal function to handle token graduation to Uniswap
     * @param tokenAddress_ Address of token to graduate
     */
    function _graduate(address tokenAddress_) private {
        TokenData storage token = agentTokens[tokenAddress_];
        require(token.isTrading && !token.hasGraduated, "Invalid graduation state");

        address bondingPair = factory.getPair(tokenAddress_, router.assetToken());
        address assetTokenAddr = router.assetToken();
        
        IPair pair = IPair(bondingPair);
        uint256 tokenBalance = pair.balance();
        uint256 assetBalance = pair.assetBalance();
        require(tokenBalance > 0 && assetBalance > 0, "No liquidity to graduate");

        router.graduate(tokenAddress_);

        require(
            IERC20(tokenAddress_).balanceOf(address(this)) >= tokenBalance &&
            IERC20(assetTokenAddr).balanceOf(address(this)) >= assetBalance,
            "Failed to receive tokens"
        );

        IERC20(tokenAddress_).forceApprove(address(uniswapRouter), tokenBalance);
        IERC20(assetTokenAddr).forceApprove(address(uniswapRouter), assetBalance);
        
        address uniswapFactory = uniswapRouter.factory();
        address uniswapPair = IUniswapV2Factory(uniswapFactory).getPair(tokenAddress_, assetTokenAddr);
        
        if (uniswapPair == address(0)) {
            uniswapPair = IUniswapV2Factory(uniswapFactory).createPair(tokenAddress_, assetTokenAddr);
        }
        require(uniswapPair != address(0), "Failed to get/create Uniswap pair");

        // Set token as graduated
        Token(tokenAddress_).graduate(uniswapPair);

        (uint256 amountToken, uint256 amountAsset, uint256 liquidity) = 
            uniswapRouter.addLiquidity(
                tokenAddress_,
                assetTokenAddr,
                tokenBalance,
                assetBalance,
                tokenBalance * 95 / 100,
                assetBalance * 95 / 100,
                address(0),
                block.timestamp + 3600
            );
        
        require(
            amountToken >= tokenBalance * 95 / 100 &&
            amountAsset >= assetBalance * 95 / 100 &&
            liquidity > 0,
            "Liquidity addition failed"
        );

        token.isTrading = false;
        token.hasGraduated = true;
        token.pair = uniswapPair;

        emit Graduated(tokenAddress_);
    }

    /**
     * @notice Internal helper to approve token spending
     * @param spender_ Address to approve
     * @param tokenAddress_ Token to approve
     * @param amount_ Amount to approve
     * @return success Whether the approval succeeded
     */
    function _approve(
        address spender_,
        address tokenAddress_,
        uint256 amount_
    ) internal returns (bool) {
        IERC20(tokenAddress_).forceApprove(spender_, amount_);
        return true;
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
     * @param newThresholdPercent_ New threshold percentage value
     */
    function setGradThresholdPercent(uint256 newThresholdPercent_) external onlyOwner {
        gradThresholdPercent = newThresholdPercent_;
    }

    /**
     * @notice Updates the maximum transaction percentage
     * @param maxTxPercent_ New maximum transaction percentage (1-100)
     */
    function setMaxTxPercent(uint256 maxTxPercent_) external onlyOwner {
        require(maxTxPercent_ <= 100, "Max transaction cannot exceed 100%");
        maxTxPercent = maxTxPercent_;
    }

    /**
     * @notice Updates the asset rate used in calculations
     * @param newRate_ New asset rate value
     */
    function setAssetRate(uint256 newRate_) external onlyOwner {
        require(newRate_ > 0, "Rate must be positive");
        assetRate = newRate_;
    }

    /*//////////////////////////////////////////////////////////////
                         FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Allows contract to receive ETH
    receive() external payable {}
}