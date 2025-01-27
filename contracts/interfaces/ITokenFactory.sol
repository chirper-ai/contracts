// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ITokenFactory {
    // Events
    event TokenCreated(
        address indexed token,
        string name,
        string symbol,
        address creator,
        uint256 initialSupply
    );

    // View Functions
    function FACTORY_ROLE() external view returns (bytes32);
    function ADMIN_ROLE() external view returns (bytes32);
    function initialSupply() external view returns (uint256);
    function platformTreasury() external view returns (address);
    function manager() external view returns (address);

    // State-Changing Functions
    function initialize(
        address factory_,
        address manager_,
        uint256 initialSupply_
    ) external;

    function launch(
        string calldata name,
        string calldata symbol,
        string calldata url,
        string calldata intention,
        address creator
    ) external returns (address);

    function setInitialSupply(uint256 newSupply) external;
    function setPlatformTreasury(address newTreasury) external;
    function setManager(address newManager) external;
    function setTokenTaxExempt(address token_, address account_, bool isExempt_) external;
    function setTokenPlatformTreasury(address token_, address treasury_) external;
    function setTokenBuyTax(address token_, uint256 buyTax_) external;
    function setTokenSellTax(address token_, uint256 sellTax_) external;
}