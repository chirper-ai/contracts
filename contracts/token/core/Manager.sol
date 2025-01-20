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
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import "./Factory.sol";
import "./Router.sol";
import "./Token.sol";

// interfaces
import "../interfaces/IBondingPair.sol";

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
    uint256 public K;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

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

    /// @notice Router information for token graduation
    struct DexRouter {
        address routerAddress;  // Address of the DEX router
        uint256 weight;        // Weight for liquidity distribution (1-100)
    }

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
     * @param creator Address of the token creator
     * @param token Address of the token contract
     * @param intention Purpose of the token
     * @param url Reference URL for the token
     * @param metrics Comprehensive token metrics
     * @param isTrading Whether the token is currently trading
     * @param hasGraduated Whether the token has graduated to DEXes
     * @param bondingPair Address of the bonding curve pair
     * @param dexRouters Array of DEX routers and their weights
     * @param dexPools Array of DEX pairs created during graduation
     * @param mainDexPool This is at the end
     */
    struct TokenData {
        address creator;
        address token;
        string intention;
        string url;
        TokenMetrics metrics;
        bool isTrading;
        bool hasGraduated;
        address bondingPair;     
        DexRouter[] dexRouters; 
        address[] dexPools;      // This is at the end
        address mainDexPool;
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
     * @param kConstant_ Bonding curve constant
     * @param assetRateValue_ Asset rate for calculations
     * @param gradThresholdPercent_ Graduation threshold percentage
     */
    function initialize(
        address factory_,
        address router_,
        uint256 initSupply_,
        uint256 kConstant_,
        uint256 assetRateValue_,
        uint256 gradThresholdPercent_
    ) external initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        
        require(factory_ != address(0), "Invalid factory");
        require(router_ != address(0), "Invalid router");

        K = kConstant_;
        factory = Factory(factory_);
        router = Router(router_);
        initialSupply = initSupply_;
        assetRate = assetRateValue_;
        gradThresholdPercent = gradThresholdPercent_;
    }

    /*//////////////////////////////////////////////////////////////
                         CORE TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function launch(
        string memory name_,
        string memory ticker_,
        string memory intention_,
        string memory url_,
        uint256 purchaseAmount_,
        DexRouter[] memory dexRouters_
    ) external nonReentrant returns (address token, address pair, uint256 index) {
        require(dexRouters_.length > 0, "Must provide at least one DEX router");
        
        uint256 totalWeight;
        for(uint i = 0; i < dexRouters_.length; i++) {
            require(dexRouters_[i].routerAddress != address(0), "Invalid router address");
            require(dexRouters_[i].weight > 0 && dexRouters_[i].weight <= 100_000, "Invalid weight");
            totalWeight += dexRouters_[i].weight;
        }
        require(totalWeight == 100_000, "Weights must sum to 100_000");

        address assetToken_ = router.assetToken();
        require(
            IERC20(assetToken_).balanceOf(msg.sender) >= purchaseAmount_,
            "Insufficient funds"
        );

        uint256 launchTax = (purchaseAmount_ * factory.launchTax()) / 100_000;
        uint256 initialPurchase = purchaseAmount_ - launchTax;
        
        // Transfer launch tax to tax vault
        IERC20(assetToken_).safeTransferFrom(msg.sender, factory.taxVault(), launchTax);
        IERC20(assetToken_).safeTransferFrom(
            msg.sender,
            address(this),
            initialPurchase
        );

        // Create token (decimal scaling handled by Token contract)
        Token actualToken = new Token(
            string.concat(name_, "agent"), 
            ticker_,
            initialSupply,
            address(this),
            factory.buyTax(),
            factory.sellTax(),
            factory.taxVault()
        );

        address newBondingPair = factory.createPair(address(actualToken), assetToken_);
        uint256 supply = actualToken.totalSupply();

        require(_approve(address(router), address(actualToken), supply));

        uint256 k = ((K * 100_000) / assetRate);
        uint256 liquidity = (((k * 100_000 ether) / supply) * 1 ether) / 100_000;

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
            bondingPair: newBondingPair,
            intention: intention_,
            url: url_,
            metrics: metrics,
            isTrading: true,
            hasGraduated: false,
            dexRouters: dexRouters_,
            dexPools: new address[](0),
            mainDexPool: address(0)
        });

        agentTokens[address(actualToken)] = localToken;
        agentTokenList.push(address(actualToken));

        uint256 tokenIndex = agentTokenList.length;

        emit Launched(address(actualToken), newBondingPair, tokenIndex);

        IERC20(assetToken_).forceApprove(address(router), initialPurchase);
        router.buy(initialPurchase, address(actualToken), address(this));
        
        // Check received tokens don't exceed 20% of supply
        uint256 receivedTokens = actualToken.balanceOf(address(this));
        require(
            receivedTokens <= (supply * 20_000) / 100_000,
            "Initial purchase exceeds 20% of supply"
        );
        
        actualToken.transfer(msg.sender, receivedTokens);

        return (address(actualToken), newBondingPair, tokenIndex);
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

        IBondingPair pair = IBondingPair(pairAddress);
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

        uint256 reservePercentage = (newReserveA * 100_000) / totalSupply;
        
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

        IBondingPair pair = IBondingPair(pairAddress);
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
     * @notice Internal function to handle token graduation to DEXes
     * @param tokenAddress_ Address of token to graduate
     */
    function _graduate(address tokenAddress_) private {
        TokenData storage token = agentTokens[tokenAddress_];
        require(token.isTrading && !token.hasGraduated, "Invalid graduation state");

        // Extract liquidity from bonding curve
        (uint256 tokenBalance, uint256 assetBalance) = _extractBondingCurveLiquidity(tokenAddress_);
        
        // Deploy to DEXes and store the pairs
        address[] memory newPairs = _deployToDexes(
            tokenAddress_,
            token.dexRouters,
            tokenBalance,
            assetBalance
        );

        // Update token data with new pairs
        token.dexPools = newPairs;
        token.isTrading = false;
        token.hasGraduated = true;
        token.mainDexPool = newPairs[0];

        emit Graduated(tokenAddress_);
    }

    /**
     * @notice Extracts liquidity from the bonding curve pair
     * @param tokenAddress_ Address of the token
     * @return tokenBalance Amount of tokens extracted
     * @return assetBalance Amount of asset tokens extracted
     */
    function _extractBondingCurveLiquidity(
        address tokenAddress_
    ) private returns (uint256 tokenBalance, uint256 assetBalance) {
        TokenData storage token = agentTokens[tokenAddress_];
        address assetTokenAddr = router.assetToken();
        
        IBondingPair pair = IBondingPair(token.bondingPair);
        tokenBalance = pair.balance();
        assetBalance = pair.assetBalance();
        require(tokenBalance > 0 && assetBalance > 0, "No liquidity to graduate");

        // Note: This now just extracts liquidity, graduation happens later
        router.graduate(tokenAddress_);

        require(
            IERC20(tokenAddress_).balanceOf(address(this)) >= tokenBalance &&
            IERC20(assetTokenAddr).balanceOf(address(this)) >= assetBalance,
            "Failed to receive tokens"
        );

        return (tokenBalance, assetBalance);
    }

    /**
     * @notice Deploys liquidity to multiple DEXes according to weights
     * @param tokenAddress_ Address of the token
     * @param dexRouters_ Array of DEX routers and their weights
     * @param totalTokens_ Total tokens to distribute
     * @param totalAssets_ Total asset tokens to distribute
     * @return pairs Array of created DEX pairs
     */
    function _deployToDexes(
        address tokenAddress_,
        DexRouter[] memory dexRouters_,
        uint256 totalTokens_,
        uint256 totalAssets_
    ) private returns (address[] memory pairs) {
        address assetTokenAddr = router.assetToken();
        
        address[] memory newPairs = new address[](dexRouters_.length);

        for (uint i = 0; i < dexRouters_.length; i++) {
            uint256 tokenAmount = (totalTokens_ * dexRouters_[i].weight) / 100_000;
            uint256 assetAmount = (totalAssets_ * dexRouters_[i].weight) / 100_000;

            IUniswapV2Router02 dexRouter = IUniswapV2Router02(dexRouters_[i].routerAddress);

            IERC20(tokenAddress_).forceApprove(address(dexRouter), tokenAmount);
            IERC20(assetTokenAddr).forceApprove(address(dexRouter), assetAmount);

            address dexFactory = dexRouter.factory();
            
            address dexPool = IUniswapV2Factory(dexFactory).getPair(
                tokenAddress_,
                assetTokenAddr
            );

            if (dexPool == address(0)) {
                dexPool = IUniswapV2Factory(dexFactory).createPair(
                    tokenAddress_,
                    assetTokenAddr
                );
            }
            
            require(dexPool != address(0), "Failed to get/create DEX pair");
            
            (uint256 amountToken, uint256 amountAsset, uint256 liquidity) = 
                dexRouter.addLiquidity(
                    tokenAddress_,
                    assetTokenAddr,
                    tokenAmount,
                    assetAmount,
                    tokenAmount * 95 / 100,
                    assetAmount * 95 / 100,
                    address(0),
                    block.timestamp + 3600
                );

            require(
                amountToken >= tokenAmount * 95 / 100 &&
                amountAsset >= assetAmount * 95 / 100 &&
                liquidity > 0,
                "Liquidity addition failed requirements"
            );

            newPairs[i] = dexPool;
        }
        
        Token(tokenAddress_).graduate(newPairs);

        return newPairs;
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
     * @notice Updates the asset rate used in calculations
     * @param newRate_ New asset rate value
     */
    function setAssetRate(uint256 newRate_) external onlyOwner {
        require(newRate_ > 0, "Rate must be positive");
        assetRate = newRate_;
    }
    
    /**
     * @notice gets the list of dex pools for a token
     * @param token address of the token
     */
    function getDexPools(address token) external view returns (address[] memory) {
        return agentTokens[token].dexPools;
    }
}