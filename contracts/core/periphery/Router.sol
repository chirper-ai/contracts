// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// imports
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// local imports
import "../../interfaces/IPair.sol";
import "../../interfaces/IToken.sol";
import "../../interfaces/IFactory.sol";
import "../../interfaces/IManager.sol";

/**
 * @title Router
 * @dev Handles token swaps for bonding pairs, following Uniswap interface patterns.
 * 
 * Key features:
 * 1. Implements standard Uniswap router interface
 * 2. Handles bonding curve trades
 * 3. Supports exact input/output swaps
 * 
 * All trades go through bonding pairs until graduation,
 * after which the token is no longer tradeable through this router.
 */
contract Router is 
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

    /// @notice Basis points denominator for percentage calculations
    uint256 private constant BASIS_POINTS = 100_000;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Factory contract reference
    IFactory public factory;

    /// @notice Asset token used for trading pairs
    address public assetToken;

    /// @notice Maximum percentage of total supply that can be held by a single address
    uint256 public maxHold;

    /// @notice buy tax
    uint256 public buyTax;

    /// @notice sell tax
    uint256 public sellTax;

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAPS
    //////////////////////////////////////////////////////////////*/

    /// @dev Gap for future storage layout changes
    uint256[47] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a token swap occurs
     * @param sender Address initiating the swap
     * @param agentToken Address of the agent token being traded
     * @param amountIn Amount of input tokens spent
     * @param amountOut Amount of output tokens received
     * @param isBuy True if buying agent token, false if selling
     */
    event Swap(
        address indexed sender,
        address indexed agentToken,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy
    );

    /**
     * @notice Emitted when token metrics are updated after a trade
     * @param agentToken Address of the agent token
     * @param price Current token price in asset tokens
     * @param marketCap Total market capitalization
     * @param circulatingSupply Number of tokens in circulation
     * @param liquidity Total liquidity value
     */
    event Metrics(
        address indexed agentToken,
        uint256 price,
        uint256 marketCap,
        uint256 circulatingSupply,
        uint256 liquidity
    );

    /**
     * @notice Emitted when trading fees are collected and distributed
     * @param token Address of the agent token
     * @param amount Total amount of fees collected
     * @param platformShare Amount sent to platform treasury
     * @param creatorShare Amount sent to token creator
     */
    event TaxCollected(
        address indexed token,
        uint256 amount,
        uint256 platformShare,
        uint256 creatorShare
    );

    /**
     * @notice Emitted when maximum holding limit is updated
     * @param maxHold New maximum holding percentage (in basis points)
     */
    event MaxHoldUpdated(uint256 maxHold);

    /**
     * @notice Emitted when buy tax rate is updated
     * @param buyTax New buy tax rate (in basis points)
     */
    event BuyTaxUpdated(uint256 buyTax);

    /**
     * @notice Emitted when sell tax rate is updated
     * @param sellTax New sell tax rate (in basis points)
     */
    event SellTaxUpdated(uint256 sellTax);

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
     * @notice Initializes the router with required parameters
     * @param factory_ Factory contract address
     * @param assetToken_ Asset token address
     */
    function initialize(
        address factory_,
        address assetToken_,
        uint256 maxHold_,
        uint256 buyTax_,
        uint256 sellTax_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(factory_ != address(0), "Invalid factory");
        require(assetToken_ != address(0), "Invalid asset token");
        require(IToken(assetToken_).decimals() == 18, "Asset token must have 18 decimals");


        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        factory = IFactory(factory_);
        assetToken = assetToken_;
        maxHold = maxHold_;
        buyTax = buyTax_;
        sellTax = sellTax_;
    }

    /*//////////////////////////////////////////////////////////////
                         UNISWAP-STYLE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Swaps exact tokens for tokens supporting bonding curves
     * @param amountIn Exact amount of input tokens
     * @param amountOutMin Minimum output tokens to receive
     * @param path Trading path (must be length 2)
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amounts Array of amounts for path
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "Expired");
        require(path.length == 2, "Invalid path");
        
        amounts = new uint256[](2);
        amounts[0] = amountIn;

        // Handle bonding curve routing
        if (_isAgentToken(path[0])) {
            // Selling agent token
            amounts[1] = _swapExactAgentForAsset(
                path[0],
                amountIn,
                amountOutMin,
                to
            );
        } else if (_isAgentToken(path[1])) {
            // Buying agent token
            amounts[1] = _swapExactAssetForAgent(
                path[1],
                amountIn,
                amountOutMin,
                to
            );
        } else {
            revert("Invalid path");
        }
    }

    /**
     * @notice Swaps tokens for exact tokens supporting bonding curves
     * @param amountOut Exact amount of output tokens
     * @param amountInMax Maximum input tokens to spend
     * @param path Trading path (must be length 2)
     * @param to Recipient address
     * @param deadline Transaction deadline
     * @return amounts Array of amounts for path
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "Expired");
        require(path.length == 2, "Invalid path");
        
        amounts = new uint256[](2);
        amounts[1] = amountOut;

        // Handle bonding curve routing
        if (_isAgentToken(path[0])) {
            // Selling agent token
            amounts[0] = _swapAgentForExactAsset(
                path[0],
                amountOut,
                amountInMax,
                to
            );
        } else if (_isAgentToken(path[1])) {
            // Buying agent token
            amounts[0] = _swapAssetForExactAgent(
                path[1],
                amountOut,
                amountInMax,
                to
            );
        } else {
            revert("Invalid path");
        }
    }

    /**
     * @notice Gets amounts out for a swap
     * @param amountIn Input amount
     * @param path Trading path
     * @return amounts Output amounts
     */
    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        require(path.length == 2, "Invalid path");
        amounts = new uint256[](2);
        amounts[0] = amountIn;

        uint256 preTaxAmount;
        if (_isAgentToken(path[0])) {
            // Selling agent token
            preTaxAmount = _getAssetOut(path[0], amountIn);
            (amounts[1],) = _applyTax(preTaxAmount, sellTax);
        } else if (_isAgentToken(path[1])) {
            // Buying agent token
            preTaxAmount = _getAgentOut(path[1], amountIn);
            (amounts[1],) = _applyTax(preTaxAmount, buyTax);
        } else {
            revert("Invalid path");
        }
    }

    /**
     * @notice Gets amounts in for a swap
     * @param amountOut Output amount
     * @param path Trading path
     * @return amounts Input amounts
     */
    function getAmountsIn(
        uint256 amountOut,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        require(path.length == 2, "Invalid path");
        amounts = new uint256[](2);
        amounts[1] = amountOut;

        if (_isAgentToken(path[0])) {
            // Selling agent token - adjust for sell tax
            uint256 grossAmount = (amountOut * BASIS_POINTS) / (BASIS_POINTS - sellTax);
            amounts[0] = _getAgentIn(path[0], grossAmount);
        } else if (_isAgentToken(path[1])) {
            // Buying agent token - adjust for buy tax
            uint256 grossAmount = (amountOut * BASIS_POINTS) / (BASIS_POINTS - buyTax);
            amounts[0] = _getAssetIn(path[1], grossAmount);
        } else {
            revert("Invalid path");
        }
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice adds initial liquidity to a bonding pair
     * @param agentToken_ Address of the agent token
     * @param assetToken_ Address of the asset token
     * @param amountAgentIn Amount of agent tokens being sold
     * @param amountAssetIn Amount of asset tokens being spent
     */
    function addInitialLiquidity(
        address agentToken_,
        address assetToken_,
        uint256 amountAgentIn,
        uint256 amountAssetIn
    ) external nonReentrant returns (uint256 liquidity) {
        require(msg.sender == address(factory), "only factory");
        require(assetToken == assetToken_, "invalid asset token");
        
        address pair = factory.getPair(agentToken_, assetToken_);
        require(pair != address(0), "pair doesn't exist");
        
        IPair bondingPair = IPair(pair);
        (uint256 agentReserve,,) = bondingPair.getReserves();
        require(agentReserve == 0, "already initialized");

        if(amountAgentIn > 0) {
            IERC20(agentToken_).safeTransferFrom(msg.sender, pair, amountAgentIn);

            // sync
            bondingPair.sync();
        }
        if(amountAssetIn > 0) {
            // Perform initial purchase
            bondingPair.swap(0, amountAssetIn, 0, 0);
            bondingPair.transferTo(msg.sender, amountAgentIn);
            emit Swap(msg.sender, agentToken_, amountAssetIn, amountAgentIn, true);
        }

        // update metrics
        _updateMetrics(pair, agentToken_);

        return liquidity;
    }

    /**
     * @notice transfers liquidity to manager
     * @param token Address of the agent token
     * @param tokenAmount Amount of agent tokens to transfer
     * @param assetAmount Amount of asset tokens to transfer
     */
    function transferLiquidityToManager(
        address token,
        uint256 tokenAmount,
        uint256 assetAmount
    ) external nonReentrant {
        address manager = factory.manager();
        require(msg.sender == manager, "Only manager");
        address pair = factory.getPair(token, assetToken);
        require(pair != address(0), "Pair not found");

        // should graduate
        bool shouldGraduate = IManager(manager).checkGraduation(token);

        // check should graduate
        require(shouldGraduate, "Token not ready for graduation");

        // bonding pair
        IPair bondingPair = IPair(pair);
        
        // Transfer tokens to manager
        bondingPair.transferTo(msg.sender, tokenAmount);
        bondingPair.transferAsset(msg.sender, assetAmount);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if address is an agent token
     * @param token Token address to check
     * @return bool True if token is an agent token
     */
    function _isAgentToken(address token) internal view returns (bool) {
        return factory.getPair(token, assetToken) != address(0);
    }

    /**
     * @notice Checks if a transfer would exceed max holding limit
     * @param pair Pair to check
     * @param to Recipient address
     * @param amount Amount being transferred
     */
    function _checkMaxHold(
        address pair,
        address agentToken,
        address to,
        uint256 amount
    ) internal view {
        if (to == address(0) || to == address(this)) return;

        // token
        IERC20 token = IERC20(agentToken);

        // Get total supply
        uint256 totalSupply_ = token.totalSupply();
        
        // Get new balance
        uint256 newBalance = token.balanceOf(to) + amount;
        uint256 maxHoldAmount = (totalSupply_ * maxHold) / BASIS_POINTS;

        // check max hold
        if (newBalance > maxHoldAmount) {
            // get asset token
            IERC20 actualAssetToken = IERC20(assetToken);
            
            // Skip if first buy (pair holds all tokens)
            if (actualAssetToken.balanceOf(pair) == 0) return;
        }

        // exceeds max holding
        require(newBalance <= maxHoldAmount, "Exceeds max holding");
    }

    /**
     * @notice Applies tax to an amount
     * @param amount Amount to apply tax to
     * @param taxRate Tax rate in basis points
     * @return netAmount Amount after tax
     * @return taxAmount Tax amount
     */
    function _applyTax(
        uint256 amount,
        uint256 taxRate
    ) internal pure returns (uint256 netAmount, uint256 taxAmount) {
        taxAmount = (amount * taxRate) / BASIS_POINTS;
        netAmount = amount - taxAmount;
        return (netAmount, taxAmount);
    }

    /**
     * @notice Sends tax to platform and creator
     * @param agentToken Agent token to tax
     * @param tokenAmount Amount of agent tokens to tax
     */
    function _sendTax(
        address agentToken,
        IPair pair,
        bool isAsset,
        uint256 tokenAmount
    ) internal {
        // Ensure exact 50-50 split by doing multiplication before division
        uint256 creatorToken = (tokenAmount * 50) / 100;
        uint256 platformToken = tokenAmount - creatorToken;

        // get platform tax address
        address creatorTreasury = IToken(agentToken).creator();
        address platformTreasury = factory.platformTreasury();

        // transfer
        if (isAsset) {
            // bonding pair transfer
            pair.transferAsset(platformTreasury, platformToken);
            pair.transferAsset(creatorTreasury, creatorToken);
        } else {
            // bonding pair transfer
            pair.transferTo(platformTreasury, platformToken);
            pair.transferTo(creatorTreasury, creatorToken);
        }

        // emit tax collected
        emit TaxCollected(agentToken, tokenAmount, platformToken, creatorToken);
    }

    /**
     * @notice Swaps exact agent tokens for asset tokens
     * @param agentToken Agent token to sell
     * @param amountIn Amount of agent tokens to sell
     * @param amountOutMin Minimum asset tokens to receive
     * @param to Recipient address
     * @return amountOut Amount of asset tokens received
     */
    function _swapExactAgentForAsset(
        address agentToken,
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) internal returns (uint256 amountOut) {
        // Get bonding pair
        address pair = factory.getPair(agentToken, assetToken);
        require(pair != address(0), "Pair not found");

        // bonding pair
        IPair bondingPair = IPair(pair);

        // Get gross amount out
        uint256 grossAmountOut = bondingPair.getAssetAmountOut(amountIn);
        
        // Calculate net amount after tax
        (uint256 netAmountOut, uint256 taxAmount) = _applyTax(grossAmountOut, sellTax);
        require(netAmountOut >= amountOutMin, "Insufficient output");
        
        // Transfer tokens to pair
        IERC20(agentToken).safeTransferFrom(msg.sender, pair, amountIn);
        
        // Execute swap
        bondingPair.swap(amountIn, 0, 0, grossAmountOut);
        
        // Transfer net amount to recipient
        bondingPair.transferAsset(to, netAmountOut);
        
        // Handle tax if applicable
        if(taxAmount > 0) {
            _sendTax(agentToken, bondingPair, true, taxAmount);
        }

        // emit swap using net amount
        emit Swap(msg.sender, agentToken, amountIn, netAmountOut, false);

        // update metrics
        _updateMetrics(pair, agentToken);

        // check graduation
        _checkGraduation(agentToken);

        // return net amount
        return netAmountOut;
    }

    /**
     * @notice Swaps exact asset tokens for agent tokens
     * @param agentToken Agent token to buy
     * @param amountIn Amount of asset tokens to spend
     * @param amountOutMin Minimum agent tokens to receive
     * @param to Recipient address
     * @return amountOut Amount of agent tokens received
     */
    function _swapExactAssetForAgent(
        address agentToken,
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) internal returns (uint256 amountOut) {
        // Get bonding pair
        address pair = factory.getPair(agentToken, assetToken);
        require(pair != address(0), "Pair not found");

        // bonding pair
        IPair bondingPair = IPair(pair);

        // Get gross amount out
        uint256 grossAmountOut = bondingPair.getAgentAmountOut(amountIn);
        
        // Calculate net amount after tax
        (uint256 netAmountOut, uint256 taxAmount) = _applyTax(grossAmountOut, buyTax);
        require(netAmountOut >= amountOutMin, "Insufficient output");

        // check holding with net amount
        _checkMaxHold(pair, agentToken, to, netAmountOut);
        
        // Transfer tokens to pair
        IERC20(assetToken).safeTransferFrom(msg.sender, pair, amountIn);
        
        // Execute swap with gross amount
        bondingPair.swap(0, amountIn, grossAmountOut, 0);
        
        // Transfer net amount to recipient
        bondingPair.transferTo(to, netAmountOut);
        
        // Handle tax if applicable
        if(taxAmount > 0) {
            _sendTax(agentToken, bondingPair, false, taxAmount);
        }

        // emit swap using net amount
        emit Swap(msg.sender, agentToken, amountIn, netAmountOut, true);

        // update metrics
        _updateMetrics(pair, agentToken);

        // check graduation
        _checkGraduation(agentToken);

        // return net amount
        return netAmountOut;
    }

    /**
     * @notice Swaps agent tokens for exact asset tokens
     * @param agentToken Agent token to sell
     * @param amountOut Exact amount of asset tokens to receive
     * @param amountInMax Maximum agent tokens to spend
     * @param to Recipient address
     * @return amountIn Amount of agent tokens spent
     */
    function _swapAgentForExactAsset(
        address agentToken,
        uint256 amountOut,
        uint256 amountInMax,
        address to
    ) internal returns (uint256 amountIn) {
        // Get bonding pair
        address pair = factory.getPair(agentToken, assetToken);
        require(pair != address(0), "Pair not found");

        // bonding pair
        IPair bondingPair = IPair(pair);

        // Calculate gross amount needed (pre-tax amount)
        uint256 grossAmountOut = (amountOut * BASIS_POINTS) / (BASIS_POINTS - sellTax);
        
        // Calculate required input for gross amount
        amountIn = _getAgentIn(agentToken, grossAmountOut);
        require(amountIn <= amountInMax, "Excessive input required");

        // Transfer tokens to pair
        IERC20(agentToken).safeTransferFrom(msg.sender, pair, amountIn);
        
        // Execute swap
        bondingPair.swap(amountIn, 0, 0, grossAmountOut);
        
        // Transfer net amount to recipient
        bondingPair.transferAsset(to, amountOut);
        
        // Handle tax if applicable
        uint256 taxAmount = grossAmountOut - amountOut;
        if(taxAmount > 0) {
            _sendTax(agentToken, bondingPair, true, taxAmount);
        }

        // emit swap
        emit Swap(msg.sender, agentToken, amountIn, amountOut, false);

        // update metrics
        _updateMetrics(pair, agentToken);

        // check graduation
        _checkGraduation(agentToken);

        return amountIn;
    }

    /**
     * @notice Swaps asset tokens for exact agent tokens
     * @param agentToken Agent token to buy
     * @param amountOut Exact amount of agent tokens to receive
     * @param amountInMax Maximum asset tokens to spend
     * @param to Recipient address
     * @return amountIn Amount of asset tokens spent
     */
    function _swapAssetForExactAgent(
        address agentToken,
        uint256 amountOut,
        uint256 amountInMax,
        address to
    ) internal returns (uint256 amountIn) {
        // Get bonding pair
        address pair = factory.getPair(agentToken, assetToken);
        require(pair != address(0), "Pair not found");

        // bonding pair
        IPair bondingPair = IPair(pair);

        // Calculate gross amount needed (pre-tax amount)
        uint256 grossAmountOut = (amountOut * BASIS_POINTS) / (BASIS_POINTS - buyTax);
        
        // Calculate required input for gross amount
        amountIn = _getAssetIn(agentToken, grossAmountOut);
        require(amountIn <= amountInMax, "Excessive input required");

        // check holding with net amount
        _checkMaxHold(pair, agentToken, to, amountOut);

        // Transfer tokens to pair
        IERC20(assetToken).safeTransferFrom(msg.sender, pair, amountIn);

        // Execute swap
        bondingPair.swap(0, amountIn, grossAmountOut, 0);
        
        // Transfer net amount to recipient
        bondingPair.transferTo(to, amountOut);
        
        // Handle tax if applicable
        uint256 taxAmount = grossAmountOut - amountOut;
        if(taxAmount > 0) {
            _sendTax(agentToken, bondingPair, false, taxAmount);
        }
        
        // emit swap
        emit Swap(msg.sender, agentToken, amountIn, amountOut, true);

        // update metrics
        _updateMetrics(pair, agentToken);

        // check graduation
        _checkGraduation(agentToken);

        return amountIn;
    }

    /**
     * @notice Calculates input amount needed for exact output
     */
    function _getAssetIn(
        address agentToken,
        uint256 amountOut
    ) internal view returns (uint256) {
        address pair = factory.getPair(agentToken, assetToken);
        return IPair(pair).getAssetAmountOut(amountOut);
    }

    /**
     * @notice Calculates input amount needed for exact output
     */
    function _getAgentIn(
        address agentToken,
        uint256 amountOut
    ) internal view returns (uint256) {
        address pair = factory.getPair(agentToken, assetToken);
        return IPair(pair).getAgentAmountOut(amountOut);
    }

    /**
     * @notice Calculates output amount for exact input
     */
    function _getAgentOut(
        address agentToken,
        uint256 amountIn
    ) internal view returns (uint256) {
        address pair = factory.getPair(agentToken, assetToken);
        return IPair(pair).getAgentAmountOut(amountIn);
    }

    /**
     * @notice Calculates output amount for exact input
     */
    function _getAssetOut(
        address agentToken,
        uint256 amountIn
    ) internal view returns (uint256) {
        address pair = factory.getPair(agentToken, assetToken);
        return IPair(pair).getAssetAmountOut(amountIn);
    }

    /**
     * @notice Graduates a token
     * @param agentToken Token to graduate
     */
    function _checkGraduation(address agentToken) internal {
        // get manager from factory
        IManager manager = IManager(factory.manager());

        // should graduate
        bool shouldGraduate = manager.checkGraduation(agentToken);

        // check graduation
        if (shouldGraduate) {
            // graduate
            manager.graduate(agentToken);
        }
    }

    /**
     * @notice Updates token metrics
     * @param pair Pair to update
     * @param agentToken Token to update
     */
    function _updateMetrics(address pair, address agentToken) internal {
        // bonding pair
        IPair bondingPair = IPair(pair);

        // Get pair reserves
        (uint256 agentReserve, uint256 assetReserve, ) = bondingPair.getReserves();

        // Get total supply
        uint256 totalSupply = IERC20(agentToken).totalSupply();

        // circulating supply
        uint256 circulatingSupply = totalSupply - IERC20(agentToken).balanceOf(pair);

        // Calculate price (assetReserve / agentReserve)
        uint256 price = agentReserve > 0 ? bondingPair.getAssetAmountOut(1e18) : 0;

        // Calculate market cap (circulatingSupply * price)
        uint256 marketCap = (circulatingSupply * price) / 1e18;

        // Calculate liquidity (2 * sqrt(agentReserve * assetReserve))
        uint256 liquidity = 2 * Math.sqrt(agentReserve * assetReserve);

        emit Metrics(
            agentToken,
            price,
            marketCap,
            circulatingSupply,
            liquidity
        );
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates maximum hold percentage
     * @param maxHold_ New maximum hold percentage
     */
    function setMaxHold(
        uint256 maxHold_
    ) external onlyRole(ADMIN_ROLE) {
        require(
            maxHold_ > 0 && maxHold_ <= BASIS_POINTS,
            "Invalid max hold percentage"
        );
        maxHold = maxHold_;
        emit MaxHoldUpdated(maxHold_);
    }

    /**
     * @notice Updates buy tax
     * @param buyTax_ New buy tax
     */
    function setBuyTax(
        uint256 buyTax_
    ) external onlyRole(ADMIN_ROLE) {
        buyTax = buyTax_;

        // emit event
        emit BuyTaxUpdated(buyTax_);
    }

    /**
     * @notice Updates sell tax
     * @param sellTax_ New sell tax
     */
    function setSellTax(
        uint256 sellTax_
    ) external onlyRole(ADMIN_ROLE) {
        sellTax = sellTax_;

        // emit event
        emit SellTaxUpdated(sellTax_);
    }
}