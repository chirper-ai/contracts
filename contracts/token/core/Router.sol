// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IBondingPair.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IToken.sol";

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

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Factory contract reference
    IFactory public factory;

    /// @notice Asset token used for trading pairs
    address public assetToken;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on successful swap
    event Swap(
        address indexed sender,
        address indexed agentToken,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy
    );

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
        address assetToken_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(factory_ != address(0), "Invalid factory");
        require(assetToken_ != address(0), "Invalid asset token");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        factory = IFactory(factory_);
        assetToken = assetToken_;
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

        if (_isAgentToken(path[0])) {
            // Selling agent token
            amounts[1] = _getAssetOut(path[0], amountIn);
        } else if (_isAgentToken(path[1])) {
            // Buying agent token
            amounts[1] = _getAgentOut(path[1], amountIn);
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
            // Selling agent token
            amounts[0] = _getAgentIn(path[0], amountOut);
        } else if (_isAgentToken(path[1])) {
            // Buying agent token
            amounts[0] = _getAssetIn(path[1], amountOut);
        } else {
            revert("Invalid path");
        }
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
        
        try IBondingPair(pair).getAssetAmountOut(amountIn) returns (uint256 quote) {
            require(quote >= amountOutMin, "Insufficient output");
            
            // Transfer tokens to pair
            IERC20(agentToken).safeTransferFrom(msg.sender, pair, amountIn);
            
            // Execute swap
            IBondingPair(pair).swap(amountIn, 0, 0, quote);
            IBondingPair(pair).transferAsset(to, quote);
            
            emit Swap(msg.sender, agentToken, amountIn, quote, false);
            return quote;
        } catch Error(string memory reason) {
            if (keccak256(bytes(reason)) == keccak256(bytes("GraduationRequired"))) {
                revert("Token graduating");
            }
            revert(reason);
        }
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
        
        try IBondingPair(pair).getAgentAmountOut(amountIn) returns (uint256 quote) {
            require(quote >= amountOutMin, "Insufficient output");
            
            // Transfer tokens to pair
            IERC20(assetToken).safeTransferFrom(msg.sender, pair, amountIn);
            
            // Execute swap
            IBondingPair(pair).swap(0, amountIn, quote, 0);
            IBondingPair(pair).transferTo(to, quote);
            
            emit Swap(msg.sender, agentToken, amountIn, quote, true);
            return quote;
        } catch Error(string memory reason) {
            if (keccak256(bytes(reason)) == keccak256(bytes("GraduationRequired"))) {
                revert("Token graduating");
            }
            revert(reason);
        }
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

        // Calculate required input
        amountIn = _getAgentIn(agentToken, amountOut);
        require(amountIn <= amountInMax, "Excessive input required");

        try {
            // Transfer tokens to pair
            IERC20(agentToken).safeTransferFrom(msg.sender, pair, amountIn);
            
            // Execute swap
            IBondingPair(pair).swap(amountIn, 0, 0, amountOut);
            IBondingPair(pair).transferAsset(to, amountOut);
            
            emit Swap(msg.sender, agentToken, amountIn, amountOut, false);
            return amountIn;
        } catch Error(string memory reason) {
            if (keccak256(bytes(reason)) == keccak256(bytes("GraduationRequired"))) {
                revert("Token graduating");
            }
            revert(reason);
        }
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

        // Calculate required input
        amountIn = _getAssetIn(agentToken, amountOut);
        require(amountIn <= amountInMax, "Excessive input required");

        try {
            // Transfer tokens to pair
            IERC20(assetToken).safeTransferFrom(msg.sender, pair, amountIn);
            
            // Execute swap
            IBondingPair(pair).swap(0, amountIn, amountOut, 0);
            IBondingPair(pair).transferTo(to, amountOut);
            
            emit Swap(msg.sender, agentToken, amountIn, amountOut, true);
            return amountIn;
        } catch Error(string memory reason) {
            if (keccak256(bytes(reason)) == keccak256(bytes("GraduationRequired"))) {
                revert("Token graduating");
            }
            revert(reason);
        }
    }

    /**
     * @notice Calculates input amount needed for exact output
     */
    function _getAssetIn(
        address agentToken,
        uint256 amountOut
    ) internal view returns (uint256) {
        address pair = factory.getPair(agentToken, assetToken);
        return IBondingPair(pair).getAssetAmountOut(amountOut);
    }

    /**
     * @notice Calculates input amount needed for exact output
     */
    function _getAgentIn(
        address agentToken,
        uint256 amountOut
    ) internal view returns (uint256) {
        address pair = factory.getPair(agentToken, assetToken);
        return IBondingPair(pair).getAgentAmountOut(amountOut);
    }

    /**
     * @notice Calculates output amount for exact input
     */
    function _getAgentOut(
        address agentToken,
        uint256 amountIn
    ) internal view returns (uint256) {
        address pair = factory.getPair(agentToken, assetToken);
        return IBondingPair(pair).getAgentAmountOut(amountIn);
    }

    /**
     * @notice Calculates output amount for exact input
     */
    function _getAssetOut(
        address agentToken,
        uint256 amountIn
    ) internal view returns (uint256) {
        address pair = factory.getPair(agentToken, assetToken);
        return IBondingPair(pair).getAssetAmountOut(amountIn);
    }
}