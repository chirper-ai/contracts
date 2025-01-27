// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../../interfaces/IToken.sol";
import "../../interfaces/IRouter.sol";

/**
 * @title Pair
 * @dev Implements a quadratic bonding curve automated market maker for agent tokens.
 * 
 * The bonding curve follows the formula: price = K / (supply × 1e18)
 * Where:
 * - K is a constant that determines initial pricing and curve steepness
 * - supply is the current agent token reserve in the pair
 * - 1e18 is used for fixed-point arithmetic precision
 * 
 * Key mechanics:
 * 1. Price increases as supply decreases (buying) following K/supply ratio
 * 2. Price decreases as supply increases (selling) following same ratio
 * 3. Initial purchase uses special case formula: output = (assetIn × agentReserve) / (K × 1e18)
 * 4. Subsequent trades use formulas:
 *    Buy: newReserveAgent = (reserveAgent × reserveAsset) / (reserveAsset + assetIn)
 *    Sell: newReserveAsset = (reserveAsset × scaledK) / reserveAgent
 *          where scaledK = (K × 1e18) / (reserveAgent + agentIn)
 * 5. Trading stops when agent token graduates
 * 
 * Example:
 * - K = 1e18
 * - Initial state: reserveAgent = 1e6, reserveAsset = 1e6
 * - Buy 1e5 asset tokens:
 *   newReserveAgent = (1e6 × 1e6) / (1e6 + 1e5) ≈ 9.09e5
 *   agentOut = 1e6 - 9.09e5 ≈ 9.1e4
 * 
 * Safety:
 * - Uses SafeERC20 for token transfers
 * - Includes reentrancy protection
 * - Validates all inputs and state changes
 * - Only router can execute trades
 */
contract Pair is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The bonding curve constant K that determines pricing
    uint256 public immutable K;

    /// @notice The factory contract that deployed this pair
    address public immutable factory;

    /// @notice The router contract authorized to execute trades
    address public immutable router;

    /// @notice The agent token being traded in the pair
    address public immutable agentToken;

    /// @notice The asset token used for purchases (e.g., USDC)
    address public immutable assetToken;

    /// @notice Current reserve of agent tokens held by pair
    uint256 private reserveAgent;

    /// @notice Current reserve of asset tokens held by pair
    uint256 private reserveAsset;

    /// @notice Timestamp of last reserve update for tracking purposes
    uint32 private blockTimestampLast;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when token reserves are updated
     * @param reserveAgent New reserve of agent tokens
     * @param reserveAsset New reserve of asset tokens
     */
    event ReservesUpdated(uint256 reserveAgent, uint256 reserveAsset);

    /**
     * @notice Emitted when a swap is executed
     * @param sender Address that initiated the swap via router 
     * @param agentAmountIn Amount of agent tokens sent to pair (selling)
     * @param assetAmountIn Amount of asset tokens sent to pair (buying)
     * @param agentAmountOut Amount of agent tokens sent from pair (buying)
     * @param assetAmountOut Amount of asset tokens sent from pair (selling)
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

    /// @notice Restricts function access to router contract only
    modifier onlyRouter() {
        require(msg.sender == router, "Only router");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes a new bonding curve pair
     * @param router_ Address of authorized router contract
     * @param agentToken_ Address of agent token to trade
     * @param assetToken_ Address of asset token for purchases
     * @param k_ Bonding curve constant for price calculations
     */
    constructor(
        address router_,
        address agentToken_,
        address assetToken_,
        uint256 k_
    ) {
        require(router_ != address(0), "Invalid router");
        require(agentToken_ != address(0), "Invalid agent token");
        require(assetToken_ != address(0), "Invalid asset token");
        require(k_ > 0, "Invalid K");

        factory = msg.sender;
        router = router_;
        agentToken = agentToken_;
        assetToken = assetToken_;
        K = k_;
    }

    /*//////////////////////////////////////////////////////////////
                            TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Executes token swap according to bonding curve formula
     * @dev Only callable by router contract
     * Handles two types of swaps:
     * 1. Asset tokens in -> Agent tokens out (buying)
     * 2. Agent tokens in -> Asset tokens out (selling)
     * Reverts if:
     * - Agent token has graduated
     * - Invalid input amounts
     * - Slippage exceeds limits
     * @param agentAmountIn Amount of agent tokens to sell
     * @param assetAmountIn Amount of asset tokens to spend
     * @param agentAmountOut Minimum agent tokens to receive
     * @param assetAmountOut Minimum asset tokens to receive
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
     * @notice Updates reserves to match current token balances
     * @dev Only callable by router contract
     * Used to handle direct token transfers to pair
     */
    function sync() external nonReentrant onlyRouter {
        uint256 agentBalance_ = IERC20(agentToken).balanceOf(address(this));
        uint256 assetBalance_ = IERC20(assetToken).balanceOf(address(this));
        _updateReserves(agentBalance_, assetBalance_);
    }

    /**
     * @notice Transfers agent tokens from pair to recipient
     * @dev Only callable by router contract
     * Uses SafeERC20 for transfer
     * @param to Address to receive tokens
     * @param amount Number of tokens to transfer
     */
    function transferTo(
        address to,
        uint256 amount
    ) external nonReentrant onlyRouter {
        IERC20(agentToken).safeTransfer(to, amount);
    }

    /**
     * @notice Transfers asset tokens from pair to recipient
     * @dev Only callable by router contract
     * Uses SafeERC20 for transfer
     * @param to Address to receive tokens
     * @param amount Number of tokens to transfer
     */
    function transferAsset(
        address to,
        uint256 amount
    ) external nonReentrant onlyRouter {
        IERC20(assetToken).safeTransfer(to, amount);
    }

    /**
     * @notice Approves spender to transfer tokens from pair
     * @dev Only callable by router contract
     * Only allows approval of pair's agent or asset token
     * Uses forceApprove for safety
     * @param spender Address to grant approval
     * @param token Token address to approve
     * @param amount Number of tokens to approve
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
     * @notice Returns current state of pair
     * @return reserveAgent Current agent token reserve
     * @return reserveAsset Current asset token reserve
     * @return blockTimestampLast Timestamp of last reserve update
     */
    function getReserves() external view returns (
        uint256,
        uint256,
        uint32
    ) {
        return (reserveAgent, reserveAsset, blockTimestampLast);
    }

    /**
     * @notice Calculates agent tokens received for asset tokens input
     * @dev Uses different formulas for initial vs subsequent purchases
     * @param assetAmountIn Amount of asset tokens to spend
     * @return Amount of agent tokens to receive
     */
    function getAgentAmountOut(
        uint256 assetAmountIn
    ) external view returns (uint256) {
        return _getAgentAmountOut(assetAmountIn);
    }

    /**
     * @notice Calculates asset tokens received for agent tokens input
     * @dev Uses scaled K formula accounting for reserve changes
     * @param agentAmountIn Amount of agent tokens to sell
     * @return Amount of asset tokens to receive
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
     * @notice Updates pair reserves and last update timestamp
     * @dev Emits ReservesUpdated event
     * @param newReserveAgent New agent token reserve amount
     * @param newReserveAsset New asset token reserve amount
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
     * @notice Internal calculation of agent tokens output
     * @dev Handles initial purchase as special case
     * For subsequent purchases: newReserve = (reserveAgent × reserveAsset) / (reserveAsset + input)
     * @param assetAmountIn Amount of asset tokens input
     * @return Amount of agent tokens to output
     */
    function _getAgentAmountOut(uint256 assetAmountIn) private view returns (uint256) {
        if (reserveAsset == 0) {
            // Initial purchase - special case
            uint256 output = (assetAmountIn * reserveAgent) / (K * 1e18);
            return output;
        }
        
        uint256 newReserveAgent = (reserveAgent * reserveAsset) / (reserveAsset + assetAmountIn);
        return reserveAgent - newReserveAgent;
    }

    /**
     * @notice Internal calculation of asset tokens output
     * @dev Uses scaled K to maintain price curve
     * Formula: newReserve = (reserveAsset × scaledK) / reserveAgent
     * where scaledK = (K × 1e18) / (reserveAgent + input)
     * @param agentAmountIn Amount of agent tokens input
     * @return Amount of asset tokens to output
     */
    function _getAssetAmountOut(uint256 agentAmountIn) private view returns (uint256) {
        uint256 scaledK = (K * 1e18) / (reserveAgent + agentAmountIn);
        uint256 newReserveAsset = (reserveAsset * scaledK) / reserveAgent;
    
        return reserveAsset - newReserveAsset;
    }
}