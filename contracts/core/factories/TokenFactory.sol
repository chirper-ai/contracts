// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

// locals
import "../base/Token.sol";

/**
 * @title TokenFactory
 * @dev Factory contract for creating new AI agent tokens with standardized configuration.
 * 
 * This contract handles token creation and initial setup, including:
 * 1. Token deployment with standard parameters
 * 2. Initial supply management
 * 3. Tax exemption configuration
 * 4. Platform treasury integration
 * 
 * The factory uses role-based access control to ensure only authorized
 * contracts (like the main Factory) can create tokens.
 */
contract TokenFactory is Initializable, AccessControlUpgradeable {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for contracts authorized to create tokens
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");

    /// @notice Role identifier for admin functions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Initial token supply for new tokens (in whole tokens)
    uint256 public initialSupply;

    /// @notice Platform treasury address for fee collection
    address public platformTreasury;

    /// @notice Manager contract that handles token lifecycle
    address public manager;

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAPS
    //////////////////////////////////////////////////////////////*/

    /// @dev Gap for future storage layout changes
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a new token is created
     * @param token The address of the created token contract
     * @param name Token name
     * @param symbol Token symbol
     * @param creator Address that will receive creator fees
     * @param initialSupply Initial token supply
     */
    event TokenCreated(
        address indexed token,
        string name,
        string symbol,
        address creator,
        uint256 initialSupply
    );

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the token factory with required parameters
     * @param factory_ Address of the main Factory contract
     * @param manager_ Manager contract address
     * @param initialSupply_ Initial token supply for new tokens
     */
    function initialize(
        address factory_,
        address manager_,
        uint256 initialSupply_
    ) external initializer {
        __AccessControl_init();
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(FACTORY_ROLE, factory_);
        
        require(initialSupply_ > 0, "Invalid supply");
        require(manager_ != address(0), "Invalid manager");

        initialSupply = initialSupply_;
        platformTreasury = msg.sender;
        manager = manager_;
    }

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
    ) external onlyRole(FACTORY_ROLE) returns (address) {
        // Deploy new token with standard configuration
        Token newToken = new Token(
            name,
            symbol,
            initialSupply,
            url,
            intention,
            manager,
            creator
        );

        // token address
        address token = address(newToken);

        // move all token to factory
        newToken.transfer(msg.sender, initialSupply);
        
        // emit created
        emit TokenCreated(
            token,
            name,
            symbol,
            creator,
            initialSupply
        );

        // return token
        return token;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the initial supply for new tokens
     * @param newSupply New initial supply amount
     */
    function setInitialSupply(uint256 newSupply) external onlyRole(ADMIN_ROLE) {
        require(newSupply > 0, "Invalid supply");
        initialSupply = newSupply;
    }

    /**
     * @notice Updates the platform treasury address
     * @param newTreasury New treasury address
     */
    function setPlatformTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        require(newTreasury != address(0), "Invalid treasury");
        platformTreasury = newTreasury;
    }

    /**
     * @notice Updates the manager contract address
     * @param newManager New manager address
     */
    function setManager(address newManager) external onlyRole(ADMIN_ROLE) {
        require(newManager != address(0), "Invalid manager");
        manager = newManager;
    }
}