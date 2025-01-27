// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IUniswapV3Pool {
    /// @notice The first of the two tokens of the pool, sorted by address
    /// @return The token contract address
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address
    /// @return The token contract address
    function token1() external view returns (address);

    /// @notice The pool's fee in hundredths of a bip, i.e. 1e-6
    /// @return The fee
    function fee() external view returns (uint24);

    /// @notice The pool tick spacing
    /// @dev Ticks can only be used at multiples of this value
    /// @return The tick spacing
    function tickSpacing() external view returns (int24);

    /// @notice The currently in range liquidity available to the pool
    /// @return The liquidity
    function liquidity() external view returns (uint128);

    /// @notice The current price of the pool as a sqrt(token1/token0) Q64.96 value
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// @notice Sets the initial price for the pool
    /// @dev Price is represented as a sqrt(token1/token0) Q64.96 value
    /// @param sqrtPriceX96 the initial sqrt price of the pool as a Q64.96
    function initialize(uint160 sqrtPriceX96) external;

    /// @notice Returns the current protocol fees accumulated in the pool
    /// @return token0Fees The protocol fees accumulated in token0
    /// @return token1Fees The protocol fees accumulated in token1
    function protocolFees() external view returns (uint128 token0Fees, uint128 token1Fees);

    /// @notice Returns data about a specific position in the pool
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @return liquidity The amount of liquidity in the position
    /// @return feeGrowthInside0LastX128 The fee growth of token0 inside the position
    /// @return feeGrowthInside1LastX128 The fee growth of token1 inside the position
    /// @return tokensOwed0 The computed amount of token0 owed to the position
    /// @return tokensOwed1 The computed amount of token1 owed to the position
    function positions(
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    );

    /// @notice Returns the tick spacing
    /// @dev Tick spacing is retrieved from the factory when the pool is created and stored immutably
    /// @return The tick spacing
    function getTickSpacing() external view returns (int24);

    /// @notice Returns the pool's factory address
    function factory() external view returns (address);
}