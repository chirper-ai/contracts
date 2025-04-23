// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IRouter {
    // Events
    event Swap(
        address indexed sender,
        address indexed agentToken,
        uint256 amountIn,
        uint256 amountOut,
        bool isBuy
    );
    event Metrics(
        address indexed agentToken,
        uint256 price,
        uint256 marketCap,
        uint256 circulatingSupply,
        uint256 liquidity
    );
    event MaxHoldUpdated(uint256 maxHold);

    // View Functions
    function ADMIN_ROLE() external view returns (bytes32);
    function factory() external view returns (address);
    function assetToken() external view returns (address);
    function maxHold() external view returns (uint256);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);

    // State-Changing Functions
    function initialize(address factory_, address assetToken_, uint256 maxHold_) external;
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function addInitialLiquidity(
        address agentToken_,
        address assetToken_,
        uint256 amountAgentIn,
        uint256 amountAssetIn
    ) external returns (uint256 liquidity);
    function transferLiquidityToManager(
        address token,
        uint256 tokenAmount,
        uint256 assetAmount
    ) external;
    function setMaxHold(uint256 maxHold_) external;
}