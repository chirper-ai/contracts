// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IPair {
    // Events
    event ReservesUpdated(uint256 reserveAgent, uint256 reserveAsset);
    event Swap(
        address indexed sender,
        uint256 agentAmountIn,
        uint256 assetAmountIn,
        uint256 agentAmountOut,
        uint256 assetAmountOut
    );

    // View Functions
    function K() external view returns (uint256);
    function factory() external view returns (address);
    function router() external view returns (address);
    function agentToken() external view returns (address);
    function assetToken() external view returns (address);
    function getReserves() external view returns (uint256, uint256, uint32);
    function getAgentAmountOut(uint256 assetAmountIn) external view returns (uint256);
    function getAssetAmountOut(uint256 agentAmountIn) external view returns (uint256);

    // State-Changing Functions
    function swap(
        uint256 agentAmountIn,
        uint256 assetAmountIn,
        uint256 agentAmountOut,
        uint256 assetAmountOut
    ) external;
    function sync() external;
    function transferTo(address to, uint256 amount) external;
    function transferAsset(address to, uint256 amount) external;
    function approval(address spender, address token, uint256 amount) external;
}