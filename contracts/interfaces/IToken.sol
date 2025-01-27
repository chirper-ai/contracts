// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IToken is IERC20 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event Graduated();
    event PoolUpdated(address pool_, bool isPool_);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function graduate(address[] memory pools_) external;

    function excludeFromTax(address account_) external;

    function setPool(address account_, bool isPool_) external;

    function setTaxParameters(uint256 buyTax_, uint256 sellTax_) external;

    function setTaxVault(address taxVault_) external;

    /*//////////////////////////////////////////////////////////////
                               GETTERS
    //////////////////////////////////////////////////////////////*/
    function buyTax() external view returns (uint256);
    
    function sellTax() external view returns (uint256);
    
    function taxVault() external view returns (address);
    
    function manager() external view returns (address);
    
    function hasGraduated() external view returns (bool);
    
    function isPool(address account) external view returns (bool);
    
    function owner() external view returns (address);
}
