// SPDX-License-Identifier: MIT
// Created by chirper.build
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./Factory.sol";
import "./IPair.sol";
import "./Router.sol";
import "./Token.sol";

/**
 * @title Manager
 * @dev Manages the lifecycle of AI agent tokens, from creation through bonding curve to graduation
 */
contract Manager is
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    using SafeERC20 for IERC20;

    /// @notice Address where fees are sent
    address public feeReceiver;

    /// @notice Factory contract for creating token pairs
    Factory public factory;

    /// @notice Router contract for token operations
    Router public router;

    /// @notice Initial supply for new agent tokens
    uint256 public initialSupply;

    /// @notice Fee charged for creating new agents
    uint256 public fee;

    /// @notice Constant used in bonding curve calculations
    uint256 public constant K = 3_000_000_000_000;

    /// @notice Rate used to calculate asset requirements
    uint256 public assetRate;

    /// @notice Threshold for graduation eligibility
    uint256 public graduationThreshold;

    /**
     * @notice Represents metrics for an agent token
     * @dev Tracks various financial and market metrics
     */
    struct TokenMetrics {
        address token;          // Token contract address
        string name;           // Full token name
        string baseName;       // Base name without prefix
        string ticker;         // Token ticker symbol
        uint256 supply;        // Total token supply
        uint256 price;         // Current token price
        uint256 mktCap;        // Market capitalization
        uint256 liq;           // Liquidity
        uint256 vol;           // Total volume
        uint256 vol24h;        // 24-hour volume
        uint256 lastPrice;     // Previous price
        uint256 lastUpdate;    // Last update timestamp
    }

    /**
     * @notice Represents an AI agent token
     * @dev Stores all relevant information about an agent token
     */
    struct TokenData {
        address creator;        // Creator's address
        address token;         // Token contract address
        address pair;          // Liquidity pair address
        string prompt;         // Agent's prompt/description
        string intention;      // Agent's intended purpose
        string url;           // Agent's URL
        TokenMetrics metrics; // Token metrics
        bool isTrading;       // Trading status
        bool hasGraduated;    // Graduation status
    }

    /// @notice Mapping of token address to agent token info
    mapping(address => TokenData) public agentTokens;

    /// @notice Array of all agent token addresses
    address[] public agentTokenList;

    /// @notice Emitted when a new agent token is launched
    event Launched(address indexed token, address indexed pair, uint256 index);

    /// @notice Emitted when an agent token graduates
    event Graduated(address indexed token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @param factoryAddress Address of the factory contract
     * @param routerAddress Address of the router contract
     * @param feeReceiverAddress Address to receive fees
     * @param feeAmount Fee amount in basis points (1/1000)
     * @param initSupply Initial token supply
     * @param assetRateValue Asset rate for calculations
     * @param gradThreshold Threshold for graduation
     */
    function initialize(
        address factoryAddress,
        address routerAddress,
        address feeReceiverAddress,
        uint256 feeAmount,
        uint256 initSupply,
        uint256 assetRateValue,
        uint256 gradThreshold
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        factory = Factory(factoryAddress);
        router = Router(routerAddress);

        feeReceiver = feeReceiverAddress;
        fee = (feeAmount * 1 ether) / 1000;

        initialSupply = initSupply;
        assetRate = assetRateValue;
        graduationThreshold = gradThreshold;
    }

    /**
     * @notice Approves spending of tokens
     * @param spender Address to approve
     * @param tokenAddress Token to approve
     * @param amount Amount to approve
     */
    function approve(
        address spender,
        address tokenAddress,
        uint256 amount
    ) internal returns (bool) {
        IERC20(tokenAddress).forceApprove(spender, amount);
        return true;
    }

    /**
     * @notice Updates the initial supply
     * @param newSupply New initial supply value
     */
    function setInitialSupply(uint256 newSupply) external onlyOwner {
        initialSupply = newSupply;
    }

    /**
     * @notice Updates the graduation threshold
     * @param newThreshold New threshold value
     */
    function setGraduationThreshold(uint256 newThreshold) external onlyOwner {
        graduationThreshold = newThreshold;
    }

    /**
     * @notice Updates fee parameters
     * @param newFee New fee amount
     * @param newFeeReceiver New fee receiver address
     */
    function setFee(uint256 newFee, address newFeeReceiver) external onlyOwner {
        fee = newFee;
        feeReceiver = newFeeReceiver;
    }

    /**
     * @notice Updates the asset rate
     * @param newRate New asset rate value
     */
    function setAssetRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "Rate must be positive");
        assetRate = newRate;
    }

    /**
     * @notice Launches a new agent token
     * @param name Token name
     * @param ticker Token ticker
     * @param prompt Agent's prompt
     * @param intention Agent's intention
     * @param url Agent's URL
     * @param purchaseAmount Initial purchase amount
     * @return token Token address
     * @return pair Pair address
     * @return index Token index
     */
    function launch(
        string memory name,
        string memory ticker,
        string memory prompt,
        string memory intention,
        string memory url,
        uint256 purchaseAmount
    ) external nonReentrant returns (address token, address pair, uint256 index) {
        require(purchaseAmount > fee, "Purchase amount below fee");
        
        address assetToken = router.assetToken();
        require(
            IERC20(assetToken).balanceOf(msg.sender) >= purchaseAmount,
            "Insufficient funds"
        );

        uint256 initialPurchase = purchaseAmount - fee;
        IERC20(assetToken).safeTransferFrom(msg.sender, feeReceiver, fee);
        IERC20(assetToken).safeTransferFrom(
            msg.sender,
            address(this),
            initialPurchase
        );

        Token actualToken = new Token(
            string.concat(name, "agent"),
            ticker,
            initialSupply,
            type(uint256).max
        );
        uint256 supply = actualToken.totalSupply();

        address newPair = factory.createPair(address(actualToken), assetToken);

        require(approve(address(router), address(actualToken), supply));

        uint256 k = ((K * 10000) / assetRate);
        uint256 liquidity = (((k * 10000 ether) / supply) * 1 ether) / 10000;

        router.addInitialLiquidity(address(actualToken), supply, liquidity);

        TokenMetrics memory metrics = TokenMetrics({
            token: address(actualToken),
            name: string.concat(name, "agent"),
            baseName: name,
            ticker: ticker,
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
            prompt: prompt,
            intention: intention,
            url: url,
            metrics: metrics,
            isTrading: true,
            hasGraduated: false
        });

        agentTokens[address(actualToken)] = localToken;
        agentTokenList.push(address(actualToken));

        uint256 tokenIndex = agentTokenList.length;

        emit Launched(address(actualToken), newPair, tokenIndex);

        // Initial purchase
        IERC20(assetToken).forceApprove(address(router), initialPurchase);
        router.buy(initialPurchase, address(actualToken), address(this));
        actualToken.transfer(msg.sender, actualToken.balanceOf(address(this)));

        return (address(actualToken), newPair, tokenIndex);
    }

    /**
     * @notice Sells agent tokens
     * @param amountIn Amount of tokens to sell
     * @param tokenAddress Token address
     */
    function sell(
        uint256 amountIn,
        address tokenAddress
    ) external returns (bool) {
        require(agentTokens[tokenAddress].isTrading, "Trading not active");

        address pairAddress = factory.getPair(
            tokenAddress,
            router.assetToken()
        );

        IPair pair = IPair(pairAddress);
        (uint256 reserveA, uint256 reserveB) = pair.getReserves();

        (uint256 amount0In, uint256 amount1Out) = router.sell(
            amountIn,
            tokenAddress,
            msg.sender
        );

        _updateMetrics(
            tokenAddress,
            reserveA + amount0In,
            reserveB - amount1Out,
            amount1Out,
            false
        );

        return true;
    }

    /**
     * @notice Buys agent tokens
     * @param amountIn Amount of asset tokens to spend
     * @param tokenAddress Token address to buy
     */
    function buy(
        uint256 amountIn,
        address tokenAddress
    ) external payable returns (bool) {
        require(agentTokens[tokenAddress].isTrading, "Trading not active");

        address pairAddress = factory.getPair(
            tokenAddress,
            router.assetToken()
        );

        IPair pair = IPair(pairAddress);
        (uint256 reserveA, uint256 reserveB) = pair.getReserves();

        (uint256 amount1In, uint256 amount0Out) = router.buy(
            amountIn,
            tokenAddress,
            msg.sender
        );

        uint256 newReserveA = reserveA - amount0Out;
        uint256 newReserveB = reserveB + amount1In;

        _updateMetrics(
            tokenAddress,
            newReserveA,
            newReserveB,
            amount1In,
            true
        );

        if (newReserveA <= graduationThreshold && agentTokens[tokenAddress].isTrading) {
            _graduate(tokenAddress);
        }

        return true;
    }

    /**
     * @notice Updates token metrics after trades
     * @param tokenAddress Token address
     * @param newReserveA New reserve of token A
     * @param newReserveB New reserve of token B
     * @param amount Amount involved in trade
     * @param isBuy Whether this is a buy transaction
     */
    function _updateMetrics(
        address tokenAddress,
        uint256 newReserveA,
        uint256 newReserveB,
        uint256 amount,
        bool isBuy
    ) private {
        TokenData storage token = agentTokens[tokenAddress];
        uint256 duration = block.timestamp - token.metrics.lastUpdate;

        uint256 liquidity = newReserveB * 2;
        uint256 marketCap = (token.metrics.supply * newReserveB) / newReserveA;
        uint256 price = newReserveA / newReserveB;
        uint256 volume = duration > 86400
            ? amount
            : token.metrics.vol24h + amount;
        uint256 lastPrice = duration > 86400
            ? token.metrics.price
            : token.metrics.lastPrice;

        token.metrics.price = price;
        token.metrics.mktCap = marketCap;
        token.metrics.liq = liquidity;
        token.metrics.vol = token.metrics.vol + amount;
        token.metrics.vol24h = volume;
        token.metrics.lastPrice = lastPrice;

        if (duration > 86400) {
            token.metrics.lastUpdate = block.timestamp;
        }
    }

    /**
     * @notice Graduates a token to Uniswap
     * @param tokenAddress Address of token to graduate
     */
    function _graduate(address tokenAddress) private {
        TokenData storage token = agentTokens[tokenAddress];
        require(token.isTrading && !token.hasGraduated, "Invalid graduation state");

        token.isTrading = false;
        token.hasGraduated = true;

        // Transfer to Uniswap implementation would go here
        router.graduate(tokenAddress);

        emit Graduated(tokenAddress);
    }
}