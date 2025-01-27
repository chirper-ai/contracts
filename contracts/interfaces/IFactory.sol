// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFactory {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PairCreated(
        address indexed agentToken_,
        address indexed assetToken_,
        address pair_,
        uint256 index_
    );

    event TaxUpdated(
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 launchTax_,
        address taxVault_
    );

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address taxVault_,
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 launchTax_
    ) external;

    function createPair(
        address agentToken_,
        address assetToken_
    ) external returns (address);

    function getPair(
        address agentToken_,
        address assetToken_
    ) external view returns (address);

    function setRouter(address routerAddress_) external;

    function setTaxParameters(
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 launchTax_,
        address taxVault_
    ) external;

    /*//////////////////////////////////////////////////////////////
                               GETTERS
    //////////////////////////////////////////////////////////////*/

    function ADMIN_ROLE() external view returns (bytes32);
    
    function CREATOR_ROLE() external view returns (bytes32);
    
    function router() external view returns (address);

    function manager() external view returns (address);
    
    function buyTax() external view returns (uint256);
    
    function sellTax() external view returns (uint256);
    
    function launchTax() external view returns (uint256);
    
    function taxVault() external view returns (address);
    
    function pairList(uint256 index) external view returns (address);
}
