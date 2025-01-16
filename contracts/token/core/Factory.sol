// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./BondingPair.sol";

/**
 * @title Factory
 * @dev Creates and manages trading pairs and platform-wide tax settings
 * This contract serves as the central registry for all trading pairs and
 * handles unified tax configuration for the entire platform.
 */
contract Factory is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Role identifier for pair creation operations
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Bidirectional mapping of token addresses to their trading pairs
    mapping(address => mapping(address => address)) private pairs;

    /// @notice Sequential list of all created pair addresses
    address[] public pairList;

    /// @notice Address of the router contract that handles trading operations
    address public router;

    /// @notice Buy tax percentage in basis points (1/100th of 1%)
    uint256 public buyTax;
    
    /// @notice Sell tax percentage in basis points (1/100th of 1%)
    uint256 public sellTax;

    /// @notice Launch tax percentage in basis points
    uint256 public launchTax;

    /// @notice Address where all taxes are collected
    address public taxVault;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a new trading pair is created
     * @param agentToken_ Address of the agent token contract
     * @param assetToken_ Address of the asset token contract
     * @param pair_ Address of the newly created pair contract
     * @param index_ Sequential index of the pair in pairList
     */
    event PairCreated(
        address indexed agentToken_,
        address indexed assetToken_,
        address pair_,
        uint256 index_
    );

    /**
     * @notice Emitted when any tax parameters are updated
     * @param buyTax_ New buy tax value
     * @param sellTax_ New sell tax value
     * @param launchTax_ New launch tax value
     * @param taxVault_ New tax vault address
     */
    event TaxUpdated(
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 launchTax_,
        address taxVault_
    );

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the factory contract with default settings
     * @param taxVault_ Initial tax vault address
     * @param buyTax_ Initial buy tax value
     * @param sellTax_ Initial sell tax value
     * @param launchTax_ Initial launch tax value
     */
    function initialize(
        address taxVault_,
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 launchTax_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        require(taxVault_ != address(0), "Invalid tax vault");
        require(buyTax_ <= 10000, "Buy tax exceeds 100%");
        require(sellTax_ <= 10000, "Sell tax exceeds 100%");
        require(launchTax_ <= 10000, "Launch tax exceeds 100%");
        
        taxVault = taxVault_;
        buyTax = buyTax_;
        sellTax = sellTax_;
        launchTax = launchTax_;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new trading pair between agent and asset tokens
     * @dev Only callable by addresses with CREATOR_ROLE
     * @param agentToken_ Address of the agent token contract
     * @param assetToken_ Address of the asset token contract
     * @return Address of the newly created pair contract
     */
    function createPair(
        address agentToken_,
        address assetToken_
    ) external onlyRole(CREATOR_ROLE) nonReentrant returns (address) {
        return _createPair(agentToken_, assetToken_);
    }

    /**
     * @notice Retrieves the address of an existing trading pair
     * @param agentToken_ Address of the agent token contract
     * @param assetToken_ Address of the asset token contract
     * @return Address of the existing pair contract
     */
    function getPair(
        address agentToken_,
        address assetToken_
    ) external view returns (address) {
        return pairs[agentToken_][assetToken_];
    }

    /**
     * @notice Returns the total number of trading pairs created
     * @return Length of the pairList array
     */
    function allPairsLength() external view returns (uint256) {
        return pairList.length;
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the router contract address
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param routerAddress_ New router contract address
     */
    function setRouter(address routerAddress_) external onlyRole(ADMIN_ROLE) {
        require(routerAddress_ != address(0), "Invalid router");
        router = routerAddress_;
    }

    /**
     * @notice Updates all platform tax parameters
     * @dev Only callable by addresses with ADMIN_ROLE
     * @param buyTax_ New buy tax value in basis points
     * @param sellTax_ New sell tax value in basis points
     * @param launchTax_ New launch tax value in basis points
     * @param taxVault_ New tax vault address
     */
    function setTaxParameters(
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 launchTax_,
        address taxVault_
    ) external onlyRole(ADMIN_ROLE) {
        require(taxVault_ != address(0), "Invalid tax vault");
        require(buyTax_ <= 10000, "Buy tax exceeds 100%");
        require(sellTax_ <= 10000, "Sell tax exceeds 100%");
        require(launchTax_ <= 10000, "Launch tax exceeds 100%");

        buyTax = buyTax_;
        sellTax = sellTax_;
        launchTax = launchTax_;
        taxVault = taxVault_;

        emit TaxUpdated(buyTax_, sellTax_, launchTax_, taxVault_);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to handle pair creation logic
     * @dev Creates new Pair contract and updates state mappings
     * @param agentToken_ Address of the agent token contract
     * @param assetToken_ Address of the asset token contract
     * @return Address of the newly created pair contract
     */
    function _createPair(
        address agentToken_,
        address assetToken_
    ) internal returns (address) {
        require(agentToken_ != address(0), "Invalid agent token");
        require(assetToken_ != address(0), "Invalid asset token");
        require(router != address(0), "Router not set");
        require(pairs[agentToken_][assetToken_] == address(0), "Pair exists");

        BondingPair pair = new BondingPair(router, agentToken_, assetToken_);
        address pairAddress = address(pair);

        pairs[agentToken_][assetToken_] = pairAddress;
        pairs[assetToken_][agentToken_] = pairAddress;
        pairList.push(pairAddress);

        uint256 pairIndex = pairList.length;
        emit PairCreated(agentToken_, assetToken_, pairAddress, pairIndex);

        return pairAddress;
    }
}