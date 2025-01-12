// file: contracts/token/core/VelodromeAdapter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IDEXAdapter.sol";
import "../interfaces/IVelodromeRouter.sol";
import "../interfaces/IVelodromeFactory.sol";

/**
 * @title VelodromeAdapter
 * @author YourName
 * @notice Adapter for Velodrome DEX integration
 * @dev Implements IDEXAdapter for Velodrome DEX
 */
contract VelodromeAdapter is IDEXAdapter {
    using SafeERC20 for IERC20;

    /// @notice Velodrome Router address
    address public immutable router;
    
    /// @notice Velodrome Factory address
    address public immutable factory;

    /// @notice Whether to use stable or volatile pools
    bool public immutable isStable;

    /**
     * @notice Creates new Velodrome adapter
     * @param router_ Router contract address
     * @param isStable_ Whether to use stable pools
     */
    constructor(address router_, bool isStable_) {
        require(router_ != address(0), "Invalid router");
        router = router_;
        factory = IVelodromeRouter(router_).factory();
        isStable = isStable_;
    }

    /**
     * @notice Adds liquidity to Velodrome pair
     * @param params Liquidity parameters
     * @return amountA Amount of tokenA used
     * @return amountB Amount of tokenB used
     * @return liquidity LP tokens minted
     */
    function addLiquidity(
        LiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Approve router if needed
        IERC20(params.tokenA).forceApprove(router, params.amountA);
        IERC20(params.tokenB).forceApprove(router, params.amountB);

        // Add liquidity
        (amountA, amountB, liquidity) = IVelodromeRouter(router).addLiquidity(
            params.tokenA,
            params.tokenB,
            isStable,
            params.amountA,
            params.amountB,
            params.minAmountA,
            params.minAmountB,
            params.to,
            params.deadline
        );

        // Clear approvals
        IERC20(params.tokenA).forceApprove(router, 0);
        IERC20(params.tokenB).forceApprove(router, 0);
    }

    /**
     * @notice Gets DEX name
     * @return DEX identifier
     */
    function getDEXName() external pure returns (string memory) {
        return "Velodrome";
    }

    /**
     * @notice Gets router address
     * @return Router contract
     */
    function getRouterAddress() external view returns (address) {
        return router;
    }

    /**
     * @notice Gets factory address
     * @return Factory contract
     */
    function getFactoryAddress() external view returns (address) {
        return factory;
    }

    /**
     * @notice Gets pair address for tokens
     * @param tokenA First token
     * @param tokenB Second token
     * @return Pair contract
     */
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address) {
        return IVelodromeFactory(factory).getPair(tokenA, tokenB, isStable);
    }
}