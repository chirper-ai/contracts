// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../../interfaces/IToken.sol";
import "../../interfaces/IRouter.sol";

/**
 * @title Pair
 * @dev Implements an automated market maker for agent tokens with customizable price impact.
 * 
 * Core Mechanics:
 * 1. Trading Functions:
 *    - Buy: Spend asset tokens to receive agent tokens
 *    - Sell: Spend agent tokens to receive asset tokens
 * 
 * 2. Price Impact Formulas:
 *    For buys:
 *    agentOut = (assetIn * Ra) / ((Rs + K) * m + assetIn)
 * 
 *    For sells:
 *    assetOut = (agentIn * (Rs + K) * m) / (Ra - agentIn)
 * 
 *    Where:
 *    - Ra: Current agent token balance in pair (reserveAgent)
 *    - Rs: Current asset token balance in pair (reserveAsset)
 *    - K: Initial reserve constant for price stability (initialReserveAsset)
 *    - m: Impact multiplier for price curve steepness
 * 
 * 3. Key Properties:
 *    - Perfect symmetry: selling tokens received from a buy returns original amount (minus rounding)
 *    - Price impact increases with trade size through two mechanisms:
 *      a) Buy: Adding assetIn to denominator
 *      b) Sell: Subtracting agentIn from denominator
 *    - initialReserveAsset (K) provides price stability by acting as virtual reserve
 *    - impactMultiplier (m) controls how steeply price deteriorates with trade size
 * 
 * 4. Price Behavior:
 *    For buys:
 *    - Small trades: price ≈ Ra/((Rs + K) * m)
 *    - Large trades: price approaches Ra/1 as size increases
 *    
 *    For sells:
 *    - Small trades: price ≈ (Rs + K) * m/Ra
 *    - Large trades: price approaches 0 as agentIn approaches Ra
 * 
 * 5. Trading Rules:
 *    - Only router contract can execute trades
 *    - Trading halts when agent token graduates
 *    - Minimum trade size > 0
 *    - Maximum sell size < current reserve
 *    - Slippage protection via minimum output amounts
 * 
 * Example:
 * Initial state:
 * - Ra (reserveAgent) = 1M tokens
 * - Rs (reserveAsset) = 10 tokens
 * - K (initialReserveAsset) = 5000 tokens
 * - m (impactMultiplier) = 5
 * 
 * Buy 10 asset tokens:
 * agentOut = (10 * 1M) / ((10 + 5000) * 5 + 10)
 * ≈ 39,503 agent tokens received
 * 
 * Sell 39,503 agent tokens:
 * assetOut = (39,503 * (10 + 5000) * 5) / (1M - 39,503)
 * ≈ 10 asset tokens received (minus rounding)
 */
contract Pair is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Controls price impact severity - higher values create larger price moves
    uint256 public immutable impactMultiplier;

    /// @notice Base price constant, similar to 'K' in traditional AMMs
    uint256 public immutable initialReserveAsset;

    /// @notice Contract that deployed this pair
    address public immutable factory;

    /// @notice Only contract authorized to execute trades
    address public immutable router;

    /// @notice Token being traded (e.g., agent token)
    address public immutable agentToken;

    /// @notice Token used for purchases (e.g., USDC)
    address public immutable assetToken;

    /// @notice Current balance of agent tokens in pair
    uint256 private reserveAgent;

    /// @notice Current balance of asset tokens in pair 
    uint256 private reserveAsset;

    /// @notice Last reserve update timestamp
    uint32 private blockTimestampLast;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Token reserves have changed
     * @param reserveAgent New agent token balance
     * @param reserveAsset New asset token balance
     */
    event ReservesUpdated(uint256 reserveAgent, uint256 reserveAsset);

    /**
     * @notice Trade executed through router
     * @param sender Trade initiator 
     * @param agentAmountIn Agent tokens sold to pair
     * @param assetAmountIn Asset tokens spent
     * @param agentAmountOut Agent tokens bought
     * @param assetAmountOut Asset tokens received
     */
    event Swap(
        address indexed sender,
        uint256 agentAmountIn,
        uint256 assetAmountIn,
        uint256 agentAmountOut,
        uint256 assetAmountOut
    );

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Only router can call
    modifier onlyRouter() {
        require(msg.sender == router, "Only router");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates new trading pair
     * @param router_ Authorized router contract
     * @param agentToken_ Token being traded
     * @param assetToken_ Token used for purchases
     * @param initialReserve_ Base price constant 
     * @param impactMultiplier_ Price impact control
     */
    constructor(
        address router_,
        address agentToken_,
        address assetToken_,
        uint256 initialReserve_,
        uint256 impactMultiplier_
    ) {
        require(router_ != address(0), "Invalid router");
        require(agentToken_ != address(0), "Invalid agent token");
        require(assetToken_ != address(0), "Invalid asset token");
        require(initialReserve_ > 0, "Invalid K");

        factory = msg.sender;
        router = router_;
        agentToken = agentToken_;
        assetToken = assetToken_;
        impactMultiplier = impactMultiplier_;
        initialReserveAsset = initialReserve_;
    }

    /*//////////////////////////////////////////////////////////////
                            TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute trade via bonding curve
     * @dev Handles both:
     * 1. Asset -> Agent (buy)
     * 2. Agent -> Asset (sell)
     * @param agentAmountIn Agent tokens to sell
     * @param assetAmountIn Asset tokens to spend
     * @param agentAmountOut Min agent tokens to receive
     * @param assetAmountOut Min asset tokens to receive
     */
    function swap(
        uint256 agentAmountIn,
        uint256 assetAmountIn,
        uint256 agentAmountOut,
        uint256 assetAmountOut
    ) external nonReentrant onlyRouter {
        require(!IToken(agentToken).hasGraduated(), "Already graduated");
        require(
            (agentAmountIn > 0 && assetAmountOut > 0) || 
            (assetAmountIn > 0 && agentAmountOut > 0),
            "Invalid amounts"
        );

        if (assetAmountIn > 0) {
            uint256 actualAgentOut = _getAgentAmountOut(assetAmountIn);
            require(actualAgentOut >= agentAmountOut, "Insufficient output");
            _updateReserves(
                reserveAgent - actualAgentOut,
                reserveAsset + assetAmountIn
            );
            agentAmountOut = actualAgentOut;
            assetAmountOut = 0;
        } else {
            uint256 actualAssetOut = _getAssetAmountOut(agentAmountIn);
            require(actualAssetOut >= assetAmountOut, "Insufficient output");
            _updateReserves(
                reserveAgent + agentAmountIn,
                reserveAsset - actualAssetOut
            );
            agentAmountOut = 0;
            assetAmountOut = actualAssetOut;
        }

        emit Swap(
            msg.sender,
            agentAmountIn,
            assetAmountIn,
            agentAmountOut,
            assetAmountOut
        );
    }

    /**
     * @notice Update reserves after direct token transfer
     */
    function sync() external nonReentrant onlyRouter {
        uint256 agentBalance_ = IERC20(agentToken).balanceOf(address(this));
        uint256 assetBalance_ = IERC20(assetToken).balanceOf(address(this));
        _updateReserves(agentBalance_, assetBalance_);
    }

    /**
     * @notice Transfer agent tokens from pair
     * @param to Recipient address
     * @param amount Number of tokens
     */
    function transferTo(
        address to,
        uint256 amount
    ) external nonReentrant onlyRouter {
        IERC20(agentToken).safeTransfer(to, amount);
    }

    /**
     * @notice Transfer asset tokens from pair 
     * @param to Recipient address
     * @param amount Number of tokens
     */
    function transferAsset(
        address to,
        uint256 amount
    ) external nonReentrant onlyRouter {
        IERC20(assetToken).safeTransfer(to, amount);
    }

    /**
     * @notice Approve token spending
     * @param spender Address to approve
     * @param token Token to approve
     * @param amount Number of tokens
     */
    function approval(
        address spender,
        address token,
        uint256 amount
    ) external nonReentrant onlyRouter {
        require(
            token == agentToken || token == assetToken,
            "Invalid token"
        );
        IERC20(token).forceApprove(spender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current reserves and timestamp
     * @return reserveAgent Current agent token reserve
     * @return reserveAsset Current asset token reserve
     * @return blockTimestampLast Last update timestamp
     */
    function getReserves() external view returns (
        uint256,
        uint256,
        uint32
    ) {
        return (reserveAgent, reserveAsset, blockTimestampLast);
    }

    /**
     * @notice Calculate agent tokens received for asset spent
     * @param assetAmountIn Asset tokens to spend
     * @return Agent tokens to receive
     */
    function getAgentAmountOut(
        uint256 assetAmountIn
    ) external view returns (uint256) {
        return _getAgentAmountOut(assetAmountIn);
    }

    /**
     * @notice Calculate asset tokens received for agent spent
     * @param agentAmountIn Agent tokens to sell
     * @return Asset tokens to receive
     */
    function getAssetAmountOut(
        uint256 agentAmountIn
    ) external view returns (uint256) {
        return _getAssetAmountOut(agentAmountIn);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update reserves and timestamp
     * @param newReserveAgent New agent balance
     * @param newReserveAsset New asset balance
     */
    function _updateReserves(
        uint256 newReserveAgent,
        uint256 newReserveAsset
    ) private {
        reserveAgent = newReserveAgent;
        reserveAsset = newReserveAsset;
        blockTimestampLast = uint32(block.timestamp);

        emit ReservesUpdated(newReserveAgent, newReserveAsset);
    }

    /**
     * @notice Calculate agent tokens out for asset tokens in
     * @dev Implements the core buy formula for converting asset tokens to agent tokens
     * 
     * Let:
     * - y = agentOut
     * - x = assetIn
     * - Ra = reserveAgent
     * - Rs = reserveAsset
     * - K = initialReserveAsset
     * - m = impactMultiplier
     * 
     * Buy formula:
     * y = (x * Ra) / ((Rs + K) * m + x)
     * 
     * Key properties:
     * 1. Price impact increases with trade size due to x in denominator
     * 2. initialReserveAsset (K) acts as a "virtual reserve" to set initial price level
     * 3. impactMultiplier (m) controls how steeply price deteriorates with size
     * 4. When x approaches 0, price approaches Ra/((Rs + K) * m)
     * 5. When x becomes very large, price approaches Ra/1
     * 
     * Example:
     * For small trade of 1 asset token:
     * - Impact of +x in denominator is minimal
     * - Price ≈ Ra/((Rs + K) * m)
     * 
     * For large trade of 1000 asset tokens:
     * - Impact of +x in denominator becomes significant
     * - Results in worse price per token than smaller trade
     * 
     * @param assetAmountIn Asset tokens to spend
     * @return Agent tokens to receive
     */
    function _getAgentAmountOut(uint256 assetAmountIn) private view returns (uint256) {
        require(assetAmountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        
        // Calculate effective asset reserves (including initial reserve for price stability)
        uint256 effectiveAssetReserves = reserveAsset + initialReserveAsset;
        
        // Calculate amplified reserves using impact multiplier
        uint256 amplifiedReserves = effectiveAssetReserves * impactMultiplier;
        
        // Compute numerator: input amount * current agent token reserves
        uint256 numerator = assetAmountIn * reserveAgent;
        
        // Compute denominator: amplified reserves + input amount
        uint256 denominator = amplifiedReserves + assetAmountIn;

        // Calculate output amount maintaining precision through division
        uint256 result = numerator / denominator;

        // fix rounding errors
        if (numerator % denominator > 0) {
            result += 1;
        }

        // return result
        return result;
    }

    /**
     * @notice Calculate asset tokens out for agent tokens in
     * @dev Mathematically derived inverse of the buy formula to ensure symmetric trading
     * 
     * Let:
     * - y = agentOut (from buy)
     * - x = assetIn (buy) or assetOut (sell)
     * - Ra = reserveAgent
     * - Rs = reserveAsset
     * - K = initialReserveAsset
     * - m = impactMultiplier
     * 
     * Buy formula:
     * y = (x * Ra) / ((Rs + K) * m + x)
     * 
     * To derive sell formula:
     * 1. y * ((Rs + K) * m + x) = x * Ra
     * 2. y * (Rs + K) * m + y * x = x * Ra
     * 3. x * (y - Ra) = -y * (Rs + K) * m
     * 4. x = (y * (Rs + K) * m) / (Ra - y)
     * 
     * Therefore sell formula:
     * assetOut = (agentIn * (reserveAsset + initialReserveAsset) * impactMultiplier) / (reserveAgent - agentIn)
     * 
     * Key properties:
     * 1. Perfect symmetry: selling tokens received from a buy returns original amount (minus rounding)
     * 2. Price impact scales with trade size through denominator term (reserveAgent - agentIn)
     * 3. Maintains consistent pricing with buy formula through use of same constants
     * 
     * @param agentAmountIn Agent tokens to sell
     * @return Asset tokens to receive
     */
    function _getAssetAmountOut(uint256 agentAmountIn) private view returns (uint256) {
        require(agentAmountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(agentAmountIn < reserveAgent, "EXCESSIVE_INPUT_AMOUNT"); // Prevent negative denominator

        // Calculate effective asset reserves (including initial reserve for price stability)
        uint256 effectiveAssetReserves = reserveAsset + initialReserveAsset;

        // Compute numerator first: multiply input by reserves and impact multiplier
        uint256 numerator = agentAmountIn * effectiveAssetReserves * impactMultiplier;

        // Compute denominator: difference between reserve and input amount
        uint256 denominator = reserveAgent - agentAmountIn;

        // Calculate output amount maintaining precision through division
        uint256 result = numerator / denominator;

        // fix rounding errors
        if (numerator % denominator > 0) {
            result += 1;
        }

        // return result
        return result;
    }
}