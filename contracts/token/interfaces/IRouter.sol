// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRouter {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event PairCreated(
        address indexed agentToken_,
        address indexed assetToken_,
        address pair_,
        uint256 index_
    );

    event TaxUpdated(
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 launchTax_,
        address taxVault_
    );

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function initialize(
        address factory_,
        address assetToken_,
        uint256 maxTxPercent_
    ) external;

    function buy(
        uint256 amountIn_,
        address tokenAddress_,
        address to_
    ) external returns (uint256, uint256);

    function sell(
        uint256 amountIn_,
        address tokenAddress_,
        address to_
    ) external returns (uint256, uint256);

    function addInitialLiquidity(
        address tokenAddress_,
        uint256 amountToken_,
        uint256 amountAsset_
    ) external returns (uint256, uint256);

    function graduate(address tokenAddress_) external;

    function setMaxTxPercent(uint256 maxTxPercent_) external;

    function getAmountsOut(
        address token_,
        address assetToken_,
        uint256 amountIn_
    ) external view returns (uint256);

    function approve(
        address pair_,
        address asset_,
        address spender_,
        uint256 amount_
    ) external;

    /*//////////////////////////////////////////////////////////////
                               GETTERS
    //////////////////////////////////////////////////////////////*/
    function ADMIN_ROLE() external view returns (bytes32);
    
    function EXECUTOR_ROLE() external view returns (bytes32);
    
    function factory() external view returns (address);
    
    function assetToken() external view returns (address);
    
    function maxTxPercent() external view returns (uint256);
}
