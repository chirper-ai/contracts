// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockVelodromePool
 * @notice Mock implementation of Velodrome V2 pool for testing
 */
contract MockVelodromePool is ERC20 {
    address public token0;
    address public token1;
    bool public stable;
    address public factory;
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public blockTimestampLast;

    constructor(
        address _token0,
        address _token1,
        bool _stable,
        address _factory
    ) ERC20("Velodrome V2", "VELO-V2-LP") {
        token0 = _token0;
        token1 = _token1;
        stable = _stable;
        factory = _factory;
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;

        if (totalSupply() == 0) {
            liquidity = Math.sqrt(amount0 * amount1);
        } else {
            liquidity = Math.min(
                (amount0 * totalSupply()) / reserve0,
                (amount1 * totalSupply()) / reserve1
            );
        }

        require(liquidity > 0, "ILM"); // Insufficient liquidity minted
        _mint(to, liquidity);

        _update(balance0, balance1);
        return liquidity;
    }

    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        amount0 = (liquidity * balance0) / totalSupply();
        amount1 = (liquidity * balance1) / totalSupply();

        if (amount0 == 0 || amount1 == 0) revert("ILB"); // Insufficient liquidity burned
        _burn(address(this), liquidity);

        IERC20(token0).transfer(to, amount0);
        IERC20(token1).transfer(to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1);
    }

    function getReserves() public view returns (
        uint256 _reserve0,
        uint256 _reserve1,
        uint256 _blockTimestampLast
    ) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function _update(uint256 balance0, uint256 balance1) private {
        reserve0 = balance0;
        reserve1 = balance1;
        blockTimestampLast = block.timestamp;
    }
}

/**
 * @title MockVelodromeFactory
 * @notice Mock implementation of Velodrome V2 factory for testing
 */
contract MockVelodromeFactory {
    mapping(address => mapping(address => mapping(bool => address))) public getPair;
    address[] public allPairs;
    address public voter;
    address public emergencyCouncil;
    bool public isPaused;

    constructor() {
        voter = msg.sender;
        emergencyCouncil = msg.sender;
    }

    function createPool(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair) {
        require(tokenA != tokenB, "IA"); // Identical addresses
        (address token0, address token1) = tokenA < tokenB 
            ? (tokenA, tokenB) 
            : (tokenB, tokenA);
        require(token0 != address(0), "ZA"); // Zero address
        require(getPair[token0][token1][stable] == address(0), "PE"); // Pool exists

        MockVelodromePool pool = new MockVelodromePool(
            token0,
            token1,
            stable,
            address(this)
        );
        
        pair = address(pool);
        getPair[token0][token1][stable] = pair;
        getPair[token1][token0][stable] = pair;
        allPairs.push(pair);

        return pair;
    }

    function getFee(address /*pool*/, bool /*stable*/) external pure returns (uint256) {
        return 1; // 0.01% fee for testing
    }
}

/**
 * @title MockVelodromeRouter
 * @notice Mock implementation of Velodrome V2 router for testing
 */
contract MockVelodromeRouter {
    address public immutable factory;
    address public immutable weth;
    address public voter;

    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    constructor(address _factory, address _weth) {
        factory = _factory;
        weth = _weth;
        voter = msg.sender;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity) {
        require(deadline >= block.timestamp, "Expired");
        
        address pair = MockVelodromeFactory(factory).getPair(tokenA, tokenB, stable);
        if (pair == address(0)) {
            pair = MockVelodromeFactory(factory).createPool(tokenA, tokenB, stable);
        }

        // Transfer tokens
        IERC20(tokenA).transferFrom(msg.sender, pair, amountADesired);
        IERC20(tokenB).transferFrom(msg.sender, pair, amountBDesired);

        // Add liquidity
        liquidity = MockVelodromePool(pair).mint(to);
        
        // Calculate actual amounts
        (uint256 reserve0, uint256 reserve1,) = MockVelodromePool(pair).getReserves();
        amountA = reserve0 - (tokenA < tokenB ? reserve0 : reserve1);
        amountB = reserve1 - (tokenA < tokenB ? reserve1 : reserve0);

        require(amountA >= amountAMin, "Insufficient A");
        require(amountB >= amountBMin, "Insufficient B");

        return (amountA, amountB, liquidity);
    }

    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        require(tokenA != tokenB, "IA");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ZA");
    }

    function quoteLiquidity(
        uint amountA,
        uint amountB,
        uint reserveA,
        uint reserveB
    ) public pure returns (uint amountB_) {
        amountB_ = (amountA * reserveB) / reserveA;
    }
}