// file: contracts/core/GraduatedToken.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/**
 * @title GraduatedToken
 * @author YourName
 * @notice ERC20 token that supports bonding curve and DEX graduation
 * @dev Implementation of a token that can transition from bonding curve to DEX trading
 */
contract GraduatedToken is 
    Initializable, 
    ERC20Upgradeable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable,
    PausableUpgradeable 
{
    /// @notice Bonding curve contract address
    address public bondingContract;
    
    /// @notice Whether token has graduated to DEX trading
    bool public isGraduated;

    /// @dev Emitted when bonding contract is updated
    event BondingContractUpdated(address newContract);
    
    /// @dev Emitted when graduation status changes
    event GraduationUpdated(bool graduated);

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the token contract
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param bonding_ Bonding curve contract address
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address bonding_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();

        require(bonding_ != address(0), "Invalid bonding address");
        bondingContract = bonding_;
    }

    /**
     * @notice Mints new tokens
     * @dev Can only be called by bonding contract
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        require(msg.sender == bondingContract, "Only bonding");
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens
     * @dev Can only be called by bonding contract
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount) external {
        require(msg.sender == bondingContract, "Only bonding");
        _burn(from, amount);
    }

    /**
     * @notice Updates bonding contract address
     * @dev Can only be called by owner
     * @param newBonding New bonding contract address
     */
    function setBondingContract(address newBonding) external onlyOwner {
        require(newBonding != address(0), "Invalid address");
        bondingContract = newBonding;
        emit BondingContractUpdated(newBonding);
    }

    /**
     * @notice Graduates token to DEX trading
     * @dev Can only be called by bonding contract
     */
    function graduate() external {
        require(msg.sender == bondingContract, "Only bonding");
        require(!isGraduated, "Already graduated");
        isGraduated = true;
        emit GraduationUpdated(true);
    }

    /**
     * @notice Pauses token transfers
     * @dev Can only be called by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses token transfers
     * @dev Can only be called by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}