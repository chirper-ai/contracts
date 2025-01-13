// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IDEXInterfaces.sol";

contract UniswapAdapter is IDEXAdapter {
    address public immutable router;
    address public immutable factory;

    constructor(address _router) {
        require(_router != address(0), "Invalid router address");
        router = _router;
        factory = IDEXRouter(_router).factory();
    }

    function getRouterAddress() external view returns (address) {
        return router;
    }

    function getFactoryAddress() external view returns (address) {
        return factory;
    }

    function getDEXName() external pure returns (string memory) {
        return "Uniswap V2";
    }

    function getPair(address tokenA, address tokenB) public view returns (address) {
        return IDEXFactory(factory).getPair(tokenA, tokenB);
    }

    function createPair(address tokenA, address tokenB) external returns (address) {
        address pair = getPair(tokenA, tokenB);
        if (pair != address(0)) {
            return pair;
        }
        return IDEXFactory(factory).createPair(tokenA, tokenB);
    }

    function addLiquidity(
        LiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Transfer tokens from sender to this contract
        IERC20(params.tokenA).transferFrom(msg.sender, address(this), params.amountA);
        IERC20(params.tokenB).transferFrom(msg.sender, address(this), params.amountB);

        // Verify transfers succeeded
        require(IERC20(params.tokenA).balanceOf(address(this)) >= params.amountA, "Transfer A failed");
        require(IERC20(params.tokenB).balanceOf(address(this)) >= params.amountB, "Transfer B failed");

        // Approve router to spend tokens
        IERC20(params.tokenA).approve(router, params.amountA);
        IERC20(params.tokenB).approve(router, params.amountB);

        try IDEXRouter(router).addLiquidity(
            params.tokenA,
            params.tokenB,
            params.amountA,
            params.amountB,
            params.minAmountA,
            params.minAmountB,
            params.to,
            params.deadline
        ) returns (uint256 _amountA, uint256 _amountB, uint256 _liquidity) {
            amountA = _amountA;
            amountB = _amountB;
            liquidity = _liquidity;
        } catch Error(string memory reason) {
            // Reset approvals on failure
            IERC20(params.tokenA).approve(router, 0);
            IERC20(params.tokenB).approve(router, 0);
            
            // Return tokens on failure
            if (IERC20(params.tokenA).balanceOf(address(this)) > 0) {
                IERC20(params.tokenA).transfer(msg.sender, params.amountA);
            }
            if (IERC20(params.tokenB).balanceOf(address(this)) > 0) {
                IERC20(params.tokenB).transfer(msg.sender, params.amountB);
            }
            
            revert(string(abi.encodePacked("Router addLiquidity failed: ", reason)));
        }

        // Reset approvals
        IERC20(params.tokenA).approve(router, 0);
        IERC20(params.tokenB).approve(router, 0);

        // Return any unused tokens
        uint256 unusedA = IERC20(params.tokenA).balanceOf(address(this));
        uint256 unusedB = IERC20(params.tokenB).balanceOf(address(this));
        
        if (unusedA > 0) {
            IERC20(params.tokenA).transfer(msg.sender, unusedA);
        }
        if (unusedB > 0) {
            IERC20(params.tokenB).transfer(msg.sender, unusedB);
        }

        return (amountA, amountB, liquidity);
    }
}