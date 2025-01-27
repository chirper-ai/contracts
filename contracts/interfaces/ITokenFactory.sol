// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
* @title ITokenFactory
* @dev Interface for TokenFactory which handles standardized token creation.
*/
interface ITokenFactory {
   /*//////////////////////////////////////////////////////////////
                                EVENTS
   //////////////////////////////////////////////////////////////*/

   event TokenCreated(
       address indexed token,
       string name,
       string symbol, 
       address creator,
       uint256 initialSupply
   );

   /*//////////////////////////////////////////////////////////////
                          TOKEN CREATION
   //////////////////////////////////////////////////////////////*/

   /**
    * @notice Creates a new token with standard configuration
    * @param name Token name
    * @param symbol Token symbol 
    * @param url Reference URL for token documentation
    * @param intention Description of token's purpose
    * @param creator Address that will receive creator fees
    * @return Address of the created token
    */
   function launch(
       string calldata name,
       string calldata symbol,
       string calldata url,
       string calldata intention,
       address creator
   ) external returns (address);

   /*//////////////////////////////////////////////////////////////
                             GETTERS
   //////////////////////////////////////////////////////////////*/

   /// @notice Gets initial token supply for new tokens
   function initialSupply() external view returns (uint256);

   /// @notice Gets platform treasury address
   function platformTreasury() external view returns (address);

   /// @notice Gets manager contract address
   function manager() external view returns (address);
}