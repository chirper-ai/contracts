// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface IToken is IERC20, IERC20Permit {
    // Events
    event Graduated(address[] pools);
    event PoolUpdated(address indexed pool, bool isPool);

    // View Functions
    function url() external view returns (string memory);
    function decimals() external view returns (uint8);
    function intention() external view returns (string memory);
    function creator() external view returns (address);
    function manager() external view returns (address);
    function hasGraduated() external view returns (bool);
    function isPool(address pool) external view returns (bool);

    // State-Changing Functions
    function graduate(address[] calldata pools) external;
    function setCreator(address newCreator) external;
}