// SPDX-License-Identifier: MIT
// Created by chirper.build
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
 * @dev Manages the lifecycle of AI agent tokens, from creation through bonding curve to graduation
 */
contract Manager is
    Initializable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable
{
    using SafeERC20 for IERC20;
    
    /// @notice WETH address
    IUniswapV2Router02 public uniswapRouter;

    /// @notice Maximum transaction percentage (e.g. 100 = 100%)
    uint256 public maxTxPercent;  // Renamed from maxTx

    /// @notice Factory contract for creating token pairs
    Factory public factory;

    /// @notice Router contract for token operations
    Router public router;

    /// @notice Initial supply for new agent tokens
    uint256 public initialSupply;

    /// @notice Fee charged for creating new agents
    uint256 public launchFeePercent;

    /// @notice Address where fees are sent
    address public launchFeeReceiver;

    /// @notice Constant used in bonding curve calculations
    uint256 public constant K = 3_000_000_000;

    /// @notice Rate used to calculate asset requirements
    uint256 public assetRate;

    /// @notice Threshold for graduation eligibility
    uint256 public gradThresholdPercent;

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
     * @param feePercent Fee percent
     * @param initSupply Initial token supply
     * @param assetRateValue Asset rate for calculations
     * @param gradThresholdPercent_ Threshold percent for graduation
     */
    function initialize(
        address factoryAddress,
        address routerAddress,
        address feeReceiverAddress,
        uint256 feePercent,
        uint256 initSupply,
        uint256 assetRateValue,
        uint256 gradThresholdPercent_,
        uint256 maxTxPercent_,
        address uniswapRouterAddress  // Add this parameter
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();

        factory = Factory(factoryAddress);
        router = Router(routerAddress);

        launchFeeReceiver = feeReceiverAddress;
        launchFeePercent = feePercent;

        uniswapRouter = IUniswapV2Router02(uniswapRouterAddress);
        initialSupply = initSupply;
        assetRate = assetRateValue;
        gradThresholdPercent = gradThresholdPercent_;
        maxTxPercent = maxTxPercent_;  // Store percentage directly
        
        require(maxTxPercent <= 100, "Max transaction cannot exceed 100%");
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
     * @param newThresholdPercent New threshold value
     */
    function setGradThresholdPercent(uint256 newThresholdPercent) external onlyOwner {
        gradThresholdPercent = newThresholdPercent;
    }

    /**
     * @notice Updates fee parameters
     * @param newFeePercent New fee percentage
     * @param newFeeReceiverAddress New fee receiver address
     */
    function setFee(uint256 newFeePercent, address newFeeReceiverAddress) external onlyOwner {
        launchFeePercent = newFeePercent;
        launchFeeReceiver = newFeeReceiverAddress;
    }

    /**
     * @notice Updates the maximum transaction amount
     * @param maxTxPercent_ New maximum transaction percentage
     */
    function setMaxTxPercent(uint256 maxTxPercent_) external onlyOwner {
        require(maxTxPercent_ <= 100, "Max transaction cannot exceed 100%");
        maxTxPercent = maxTxPercent_;
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
        address assetToken = router.assetToken();
        require(
            IERC20(assetToken).balanceOf(msg.sender) >= purchaseAmount,
            "Insufficient funds"
        );

        uint256 fee = (purchaseAmount * (launchFeePercent / 100)) / 100;
        uint256 initialPurchase = purchaseAmount - fee;
        IERC20(assetToken).safeTransferFrom(msg.sender, launchFeeReceiver, fee);
        IERC20(assetToken).safeTransferFrom(
            msg.sender,
            address(this),
            initialPurchase
        );

        // Pass maxTx to token constructor
        Token actualToken = new Token(
            string.concat(name, "agent"), 
            ticker,
            initialSupply,
            maxTxPercent
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
            amount1Out
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
            amount1In
        );

        // Check graduation conditions with safe math
        uint256 totalSupply = IERC20(tokenAddress).totalSupply();
        require(totalSupply > 0, "Invalid total supply");

        uint256 reservePercentage = (newReserveA * 100) / totalSupply;
        
        // Check if we should graduate
        if (reservePercentage <= gradThresholdPercent) {
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
     */
    function _updateMetrics(
        address tokenAddress,
        uint256 newReserveA,
        uint256 newReserveB,
        uint256 amount
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

        // 1. Get the bonding curve pair and asset token
        address bondingPair = factory.getPair(tokenAddress, router.assetToken());
        address assetTokenAddr = router.assetToken();
        
        // 2. Get current balances from bonding curve pair
        IPair pair = IPair(bondingPair);
        uint256 tokenBalance = pair.balance();
        uint256 assetBalance = pair.assetBalance();
        require(tokenBalance > 0 && assetBalance > 0, "No liquidity to graduate");

        // 3. Transfer all tokens from bonding curve to this contract
        router.graduate(tokenAddress);

        // 4. Verify we received both tokens
        require(
            IERC20(tokenAddress).balanceOf(address(this)) >= tokenBalance &&
            IERC20(assetTokenAddr).balanceOf(address(this)) >= assetBalance,
            "Failed to receive tokens"
        );

        // 5. Approve tokens for Uniswap
        IERC20(tokenAddress).forceApprove(address(uniswapRouter), tokenBalance);
        IERC20(assetTokenAddr).forceApprove(address(uniswapRouter), assetBalance);
        
        // 6. Get or create Uniswap pair
        address uniswapFactory = uniswapRouter.factory();
        address uniswapPair = IUniswapV2Factory(uniswapFactory).getPair(tokenAddress, assetTokenAddr);
        
        if (uniswapPair == address(0)) {
            uniswapPair = IUniswapV2Factory(uniswapFactory).createPair(tokenAddress, assetTokenAddr);
        }
        require(uniswapPair != address(0), "Failed to get/create Uniswap pair");

        // 7. Add liquidity to Uniswap
        (uint256 amountToken, uint256 amountAsset, uint256 liquidity) = 
            uniswapRouter.addLiquidity(
                tokenAddress,           // tokenA
                assetTokenAddr,         // tokenB
                tokenBalance,           // amountADesired
                assetBalance,           // amountBDesired
                tokenBalance * 95 / 100, // amountAMin (5% slippage)
                assetBalance * 95 / 100, // amountBMin (5% slippage)
                address(0),             // LP tokens will be burned
                block.timestamp + 3600  // 1 hour deadline
            );
        
        require(
            amountToken >= tokenBalance * 95 / 100 &&
            amountAsset >= assetBalance * 95 / 100 &&
            liquidity > 0,
            "Liquidity addition failed"
        );

        // 8. Update token state
        token.isTrading = false;
        token.hasGraduated = true;
        token.pair = uniswapPair;

        emit Graduated(tokenAddress);
    }

    // Add helper function to receive ETH
    receive() external payable {}
}