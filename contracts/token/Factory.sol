// SPDX-License-Identifier: MIT
// Created by chirper.build
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./Pair.sol";

/**
 * @title Factory
 * @dev Creates and manages trading pairs for the chirper.build platform
 */
contract Factory is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    /// @notice Role for administrative operations
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Role for pair creation operations
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");

    /// @notice Maps token addresses to their associated pairs
    mapping(address => mapping(address => address)) private pairs;

    /// @notice List of all created pairs
    address[] public pairList;

    /// @notice Router contract address
    address public router;

    /// @notice Address where tax fees are sent
    address public taxVault;
    
    /// @notice Tax percentage for buy operations (basis points)
    uint256 public buyTax;
    
    /// @notice Tax percentage for sell operations (basis points)
    uint256 public sellTax;

    /**
     * @notice Emitted when a new pair is created
     * @param agentToken Address of the agent token
     * @param assetToken Address of the asset token
     * @param pair Address of the created pair
     * @param index Index of the pair in the pairs list
     */
    event PairCreated(
        address indexed agentToken,
        address indexed assetToken,
        address pair,
        uint256 index
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory contract
     * @param taxVaultAddress Address to receive tax fees
     * @param buyTaxRate Buy tax rate in basis points
     * @param sellTaxRate Sell tax rate in basis points
     */
    function initialize(
        address taxVaultAddress,
        uint256 buyTaxRate,
        uint256 sellTaxRate
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        require(taxVaultAddress != address(0), "Invalid tax vault");
        
        taxVault = taxVaultAddress;
        buyTax = buyTaxRate;
        sellTax = sellTaxRate;
    }

    /**
     * @notice Internal function to create a new pair
     * @param agentToken Address of the agent token
     * @param assetToken Address of the asset token
     * @return Address of the created pair
     */
    function _createPair(
        address agentToken,
        address assetToken
    ) internal returns (address) {
        require(agentToken != address(0), "Invalid agent token");
        require(assetToken != address(0), "Invalid asset token");
        require(router != address(0), "Router not set");
        require(pairs[agentToken][assetToken] == address(0), "Pair exists");

        Pair pair = new Pair(router, agentToken, assetToken);
        address pairAddress = address(pair);

        pairs[agentToken][assetToken] = pairAddress;
        pairs[assetToken][agentToken] = pairAddress;
        pairList.push(pairAddress);

        uint256 pairIndex = pairList.length;
        emit PairCreated(agentToken, assetToken, pairAddress, pairIndex);

        return pairAddress;
    }

    /**
     * @notice Creates a new trading pair
     * @param agentToken Address of the agent token
     * @param assetToken Address of the asset token
     * @return Address of the created pair
     */
    function createPair(
        address agentToken,
        address assetToken
    ) external onlyRole(CREATOR_ROLE) nonReentrant returns (address) {
        return _createPair(agentToken, assetToken);
    }

    /**
     * @notice Gets the address of an existing pair
     * @param agentToken Address of the agent token
     * @param assetToken Address of the asset token
     * @return Address of the pair
     */
    function getPair(
        address agentToken,
        address assetToken
    ) external view returns (address) {
        return pairs[agentToken][assetToken];
    }

    /**
     * @notice Gets the total number of pairs
     * @return Number of pairs
     */
    function allPairsLength() external view returns (uint256) {
        return pairList.length;
    }

    /**
     * @notice Updates tax parameters
     * @param newVault New tax vault address
     * @param buyTaxRate New buy tax rate in basis points
     * @param sellTaxRate New sell tax rate in basis points
     */
    function setTaxParams(
        address newVault,
        uint256 buyTaxRate,
        uint256 sellTaxRate
    ) external onlyRole(ADMIN_ROLE) {
        require(newVault != address(0), "Invalid tax vault");
        
        taxVault = newVault;
        buyTax = buyTaxRate;
        sellTax = sellTaxRate;
    }

    /**
     * @notice Sets the router address
     * @param routerAddress New router address
     */
    function setRouter(address routerAddress) external onlyRole(ADMIN_ROLE) {
        require(routerAddress != address(0), "Invalid router");
        router = routerAddress;
    }
}