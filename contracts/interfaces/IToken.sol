// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface IToken is IERC20, IERC20Permit {
    // Events
    event Graduated(address[] pools);
    event TaxUpdated(uint256 buyTax, uint256 sellTax);
    event PoolUpdated(address indexed pool, bool isPool);
    event TaxExemptUpdated(address indexed account, bool isExempt);

    // View Functions
    function url() external view returns (string memory);
    function intention() external view returns (string memory);
    function buyTax() external view returns (uint256);
    function sellTax() external view returns (uint256);
    function creator() external view returns (address);
    function platformTreasury() external view returns (address);
    function manager() external view returns (address);
    function hasGraduated() external view returns (bool);
    function isTaxExempt(address account) external view returns (bool);
    function isPool(address pool) external view returns (bool);

    // State-Changing Functions
    function graduate(address[] calldata pools) external;
    function setTaxExempt(address account, bool isExempt) external;
    function setPlatformTreasury(address newTreasury) external;
    function setBuyTax(uint256 newBuyTax) external;
    function setSellTax(uint256 newSellTax) external;
}