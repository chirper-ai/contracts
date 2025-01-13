// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IDEXInterfaces.sol";
import "../interfaces/IVelodromeFactory.sol";
import "../interfaces/IVelodromeRouter.sol";
import "../interfaces/IVelodromePair.sol";
import "../libraries/ErrorLibrary.sol";
import "../libraries/Constants.sol";

contract VelodromeAdapter is IDEXAdapter {
    using SafeERC20 for IERC20;

    address public immutable router;
    address public immutable factory;
    bool public immutable stable;  // Velodrome specific: stable or volatile pair

    constructor(address router_, bool stable_) {
        ErrorLibrary.validateAddress(router_, "router");
        router = router_;

        address factoryAddr = IVelodromeRouter(router_).factory();
        ErrorLibrary.validateAddress(factoryAddr, "factory");
        factory = factoryAddr;

        stable = stable_;
    }

    function addLiquidity(
        LiquidityParams calldata params
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        ErrorLibrary.validateAddress(params.tokenA, "tokenA");
        ErrorLibrary.validateAddress(params.tokenB, "tokenB");
        ErrorLibrary.validateAddress(params.to, "to");
        ErrorLibrary.validateAmount(params.amountA, "amountA");
        ErrorLibrary.validateAmount(params.amountB, "amountB");
        ErrorLibrary.validateDeadline(params.deadline);

        if (params.minAmountA < (params.amountA * Constants.MAX_GRADUATION_SLIPPAGE) / Constants.BASIS_POINTS) {
            revert ErrorLibrary.InvalidAmount(params.minAmountA, "minAmountA too low");
        }
        if (params.minAmountB < (params.amountB * Constants.MAX_GRADUATION_SLIPPAGE) / Constants.BASIS_POINTS) {
            revert ErrorLibrary.InvalidAmount(params.minAmountB, "minAmountB too low");
        }

        IERC20(params.tokenA).safeIncreaseAllowance(router, params.amountA);
        IERC20(params.tokenB).safeIncreaseAllowance(router, params.amountB);

        try IVelodromeRouter(router).addLiquidity(
            params.tokenA,
            params.tokenB,
            stable,  // Velodrome specific
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
        } catch {
            IERC20(params.tokenA).safeDecreaseAllowance(router, params.amountA);
            IERC20(params.tokenB).safeDecreaseAllowance(router, params.amountB);
            revert ErrorLibrary.DexOperationFailed(
                "addLiquidity",
                "Router operation failed"
            );
        }

        if (params.amountA > amountA) {
            IERC20(params.tokenA).safeDecreaseAllowance(router, params.amountA - amountA);
        }
        if (params.amountB > amountB) {
            IERC20(params.tokenB).safeDecreaseAllowance(router, params.amountB - amountB);
        }

        if (amountA < params.minAmountA) {
            revert ErrorLibrary.ExcessiveSlippage(params.minAmountA, amountA);
        }
        if (amountB < params.minAmountB) {
            revert ErrorLibrary.ExcessiveSlippage(params.minAmountB, amountB);
        }
    }

    function getDEXName() external pure returns (string memory) {
        return "Velodrome";
    }

    function getRouterAddress() external view returns (address) {
        return router;
    }

    function getFactoryAddress() external view returns (address) {
        return factory;
    }

    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address) {
        ErrorLibrary.validateAddress(tokenA, "tokenA");
        ErrorLibrary.validateAddress(tokenB, "tokenB");
        
        address pair = IVelodromeFactory(factory).getPair(tokenA, tokenB, stable);
        
        if (pair == address(0)) {
            revert ErrorLibrary.InvalidOperation("getPair: Pair does not exist");
        }
        
        return pair;
    }

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair) {
        ErrorLibrary.validateAddress(tokenA, "tokenA");
        ErrorLibrary.validateAddress(tokenB, "tokenB");
        require(tokenA != tokenB, "Identical addresses");

        (address token0, address token1) = tokenA < tokenB 
            ? (tokenA, tokenB) 
            : (tokenB, tokenA);
        
        require(token0 != address(0), "Zero address");

        pair = IVelodromeFactory(factory).getPair(token0, token1, stable);
        
        if (pair == address(0)) {
            try IVelodromeFactory(factory).createPair(token0, token1, stable) returns (address newPair) {
                pair = newPair;
                require(pair != address(0), "Failed to create pair");
            } catch {
                revert ErrorLibrary.DexOperationFailed(
                    "createPair",
                    "Factory operation failed"
                );
            }
        }
        
        return pair;
    }
}
