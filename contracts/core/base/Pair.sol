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
 * The bonding curve uses the formula: price = K / (supply²)
 * Where:
 * - K is a constant that determines curve steepness
 * - supply is the current token reserve in the pair
 * 
 * Key mechanics:
 * 1. Price increases quadratically as supply decreases (buying)
 * 2. Price decreases quadratically as supply increases (selling)
 * 3. Square root calculations determine output amounts
 * 4. Graduation threshold triggers when reserve ratio hits target
 * 
 * Example:
 * - K = 1e18, supply = 1e6 tokens
 * - Initial price = 1e18 / (1e6)² = 1e6 asset tokens per token
 * - After buying to reduce supply to 9e5:
 *   New price = 1e18 / (9e5)² ≈ 1.23e6 (23% increase)
 * 
 * Buy formula: newReserveAgent = sqrt(K / newReserveAsset)
 * Sell formula: newReserveAsset = K / (newReserveAgent²)
 */
contract Pair is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The bonding curve constant K
    uint256 public immutable K;

    /// @notice The factory that created this pair
    address public immutable factory;

    /// @notice The router contract that handles trading
    address public immutable router;

    /// @notice The agent token in the pair
    address public immutable agentToken;

    /// @notice The asset token in the pair (e.g., USDC)
    address public immutable assetToken;

    /// @notice Reserve of agent tokens
    uint256 private reserveAgent;

    /// @notice Reserve of asset tokens
    uint256 private reserveAsset;

    /// @notice Block timestamp of last swap
    uint32 private blockTimestampLast;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when reserves are updated
     * @param reserveAgent New agent token reserve
     * @param reserveAsset New asset token reserve
     */
    event ReservesUpdated(uint256 reserveAgent, uint256 reserveAsset);

    /**
     * @notice Emitted when tokens are swapped
     * @param sender Address initiating the swap
     * @param agentAmountIn Amount of agent tokens in (if selling)
     * @param assetAmountIn Amount of asset tokens in (if buying)
     * @param agentAmountOut Amount of agent tokens out (if buying)
     * @param assetAmountOut Amount of asset tokens out (if selling)
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

    /// @notice Ensures caller is the router contract
    modifier onlyRouter() {
        require(msg.sender == router, "Only router");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new bonding pair
     * @param router_ Router contract address
     * @param agentToken_ Agent token address
     * @param assetToken_ Asset token address
     * @param k_ Bonding curve constant
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
     * @notice Executes a swap according to bonding curve formula
     * @dev Called by Router to execute trades
     * Can be either:
     * 1. Asset tokens in -> Agent tokens out (buying)
     * 2. Agent tokens in -> Asset tokens out (selling)
     * @param agentAmountIn Amount of agent tokens being sold
     * @param assetAmountIn Amount of asset tokens being spent
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
            // Selling agent tokens  
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
     * @notice Synchronizes reserves with current balances
     */
    function sync() external nonReentrant onlyRouter {
        uint256 agentBalance_ = IERC20(agentToken).balanceOf(address(this));
        uint256 assetBalance_ = IERC20(assetToken).balanceOf(address(this));
        _updateReserves(agentBalance_, assetBalance_);
    }

    /**
     * @notice Transfers tokens from the pair
     * @param to Address to transfer to
     * @param amount Amount to transfer
     */
    function transferTo(
        address to,
        uint256 amount
    ) external nonReentrant onlyRouter {
        IERC20(agentToken).safeTransfer(to, amount);
    }

    /**
     * @notice Transfers asset tokens from the pair
     * @param to Address to transfer to
     * @param amount Amount to transfer
     */
    function transferAsset(
        address to,
        uint256 amount
    ) external nonReentrant onlyRouter {
        IERC20(assetToken).safeTransfer(to, amount);
    }

    /**
     * @notice Approves router to spend tokens
     * @param spender Address to approve
     * @param token Token to approve
     * @param amount Amount to approve
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
     * @notice Returns current reserves
     * @return Agent token reserve
     * @return Asset token reserve
     * @return Last update timestamp
     */
    function getReserves() external view returns (
        uint256,
        uint256,
        uint32
    ) {
        return (reserveAgent, reserveAsset, blockTimestampLast);
    }

    /**
     * @notice Calculates output amount of agent tokens for given input of asset tokens
     * @param assetAmountIn Amount of asset tokens to spend
     * @return Amount of agent tokens received
     */
    function getAgentAmountOut(
        uint256 assetAmountIn
    ) external view returns (uint256) {
        return _getAgentAmountOut(assetAmountIn);
    }

    /**
     * @notice Calculates output amount of asset tokens for given input of agent tokens
     * @param agentAmountIn Amount of agent tokens to sell
     * @return Amount of asset tokens received
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
     * @notice Updates reserves and timestamp
     * @param newReserveAgent New agent token reserve
     * @param newReserveAsset New asset token reserve
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
     * @notice Calculates agent tokens received for asset tokens spent
     * @param assetAmountIn Amount of asset tokens to spend
     * @return Amount of agent tokens received
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
     * @notice Calculates asset tokens received for agent tokens spent
     * @param agentAmountIn Amount of agent tokens to sell
     * @return Amount of asset tokens received
     */
    function _getAssetAmountOut(uint256 agentAmountIn) private view returns (uint256) {
        uint256 scaledK = (K * 1e18) / (reserveAgent + agentAmountIn);
        uint256 newReserveAsset = (reserveAsset * scaledK) / reserveAgent;
    
        return reserveAsset - newReserveAsset;
    }
}