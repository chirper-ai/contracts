// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

interface IManager {
    // Enums
    enum DexType {
        UniswapV2,
        UniswapV3,
        Velodrome
    }

    // Structs
    struct DexConfig {
        address router;
        uint24 fee;
        uint24 weight;
        DexType dexType;
        uint24 slippage;
    }

    struct AgentProfile {
        address creator;
        string intention;
        string url;
        address bondingPair;
        address mainPool;
        DexConfig[] dexConfigs;
        address[] dexPools;
    }

    // Events
    event AgentRegistered(
        address indexed token,
        address indexed creator,
        string intention,
        string url
    );
    event AgentGraduated(
        address indexed token,
        address[] pools
    );

    // View Functions
    function ADMIN_ROLE() external view returns (bytes32);
    function factory() external view returns (address);
    function assetToken() external view returns (address);
    function gradThreshold() external view returns (uint256);
    function agentProfile(address token) external view returns (
        address creator,
        string memory intention,
        string memory url,
        address bondingPair,
        address mainPool,
        DexConfig[] memory dexConfigs,
        address[] memory dexPools
    );
    function allAgents(uint256 index) external view returns (address);
    function getDexPools(address token) external view returns (address[] memory);
    function getBondingPair(address token) external view returns (address);
    function tokenCount() external view returns (uint256);
    function checkGraduation(address token) external view returns (bool);

    // State-Changing Functions
    function initialize(address factory_, address assetToken_, uint256 gradThreshold_) external;
    function registerAgent(
        address token,
        address bondingPair,
        string calldata url,
        string calldata intention,
        DexConfig[] calldata _dexConfigs
    ) external;
    function graduate(address token) external;
    function setGradThreshold(uint256 gradThreshold_) external;
}