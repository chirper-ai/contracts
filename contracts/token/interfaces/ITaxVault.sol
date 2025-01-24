// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITaxVault {
    struct Recipient {
        address recipient;
        uint256 share;
        bool isActive;
    }

    function registerAgent(
        address token,
        address creator,
        address platformTreasury
    ) external returns (bool);

    function distribute(address token) external;

    function updateRecipients(
        address token,
        Recipient[] calldata recipients
    ) external;

    function getRecipients(
        address token
    ) external view returns (Recipient[] memory);

    function getRegisteredTokens() external view returns (address[] memory);

    function tokenCount() external view returns (uint256);

    function assetToken() external view returns (address);

    function factory() external view returns (address);
}