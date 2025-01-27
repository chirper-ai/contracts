// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "./IManager.sol";

interface IFactory {
    // Structs
    struct AirdropParams {
        bytes32 merkleRoot;
        uint256 claimantCount;
        uint256 percentage;
    }

    // Events
    event Launch(
        address indexed token,
        address indexed pair,
        address indexed creator,
        string name,
        string symbol,
        address airdrop
    );

    // Constants
    function ADMIN_ROLE() external view returns (bytes32);
    function BASIS_POINTS() external view returns (uint256);
    function PLATFORM_FEE() external view returns (uint256);
    function MAX_INITIAL_PURCHASE() external view returns (uint256);
    function MAX_AIRDROP_PERCENTAGE() external view returns (uint256);

    // View Functions
    function getPair(address token1, address token2) external view returns (address);
    function tokenToAirdrop(address token) external view returns (address);
    function allPairs(uint256 index) external view returns (address);
    function router() external view returns (address);
    function manager() external view returns (address);
    function tokenFactory() external view returns (address);
    function platformTreasury() external view returns (address);
    function K() external view returns (uint256);

    // State-Changing Functions
    function initialize(uint256 k_) external;
    function launch(
        string calldata name,
        string calldata symbol,
        string calldata url,
        string calldata intention,
        uint256 initialPurchase,
        IManager.DexConfig[] calldata dexConfigs,
        AirdropParams calldata airdropParams
    ) external returns (address token, address pair);
    function setK(uint256 newK) external;
    function setPlatformTreasury(address newPlatformTreasury) external;
    function setManager(address manager_) external;
    function setRouter(address router_) external;
    function setTokenFactory(address tokenFactory_) external;
}