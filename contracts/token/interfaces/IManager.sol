// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManager {
    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Supported DEX types for graduation
    enum DexType {
        UniswapV2,
        UniswapV3,
        Velodrome
    }

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Configuration for a DEX deployment
     * @param router Router contract address
     * @param fee Fee tier (for UniswapV3)
     * @param weight Liquidity allocation weight (basis points)
     * @param dexType Type of DEX
     */
    struct DexConfig {
        address router;
        uint24 fee;
        uint24 weight;
        DexType dexType;
    }

    /**
     * @notice Token information and configuration
     * @param creator Token creator address
     * @param intention Token purpose/description
     * @param url Reference URL
     * @param bondingPair Associated bonding pair
     * @param dexConfigs DEX deployment settings
     * @param dexPools Deployed DEX pool addresses
     */
    struct AgentProfile {
        address creator;
        string intention;
        string url;
        address bondingPair;
        DexConfig[] dexConfigs;
        address[] dexPools;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when an agents information is registered
     * @param token Agent address
     * @param creator Agent creator
     * @param intention Agent purpose
     * @param url Reference URL
     */
    event AgentRegistered(
        address indexed token,
        address indexed creator,
        string intention,
        string url
    );

    /**
     * @notice Emitted when an agent graduates to DEX trading
     * @param token Agent address
     * @param pools Array of deployed DEX pools
     */
    event AgentGraduated(
        address indexed token,
        address[] pools
    );

    /**
     * @notice Emitted when graduation parameters are updated
     * @param gradSlippage New slippage tolerance
     */
    event GraduationParamsUpdated(uint256 gradSlippage);

    /*//////////////////////////////////////////////////////////////
                            FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the manager contract
    function initialize(
        address factory_,
        address assetToken_,
        uint256 gradSlippage_
    ) external;

    /// @notice Registers a new token's information
    function registerAgent(
        address token,
        address bondingPair,
        string calldata url,
        string calldata intention,
        DexConfig[] calldata _dexConfigs
    ) external;

    /// @notice Handles the graduation process for a token
    function graduate(address token) external;

    /// @notice Checks if a token can graduate
    function checkGraduation(address token) external view returns (bool shouldGraduate, uint256 reserveRatio);

    /// @notice Returns a token's DEX pool addresses
    function getDexPools(address token) external view returns (address[] memory);

    /**
     * @notice Returns a token's bonding pair pool addresses
     * @param token Token address
     * @return address
     */
    function getBondingPair(
        address token
    ) external view returns (address);

    /// @notice Returns total number of registered tokens
    function tokenCount() external view returns (uint256);

    /// @notice Updates graduation slippage tolerance
    function setGradSlippage(uint256 gradSlippage_) external;

    /// @notice Returns the factory contract reference
    function factory() external view returns (address);

    /// @notice Returns the asset token used for trading
    function assetToken() external view returns (address);

    /// @notice Returns the slippage tolerance for graduation liquidity deployment
    function gradSlippage() external view returns (uint256);

    /// @notice Returns the admin role identifier
    function ADMIN_ROLE() external view returns (bytes32);

    /// @notice Returns agent profile information
    function agentProfile(address token) external view returns (
        address creator,
        string memory intention,
        string memory url,
        address bondingPair,
        DexConfig[] memory dexConfigs,
        address[] memory dexPools
    );

    /// @notice Returns the agent address at the given index
    function allAgents(uint256 index) external view returns (address);
}