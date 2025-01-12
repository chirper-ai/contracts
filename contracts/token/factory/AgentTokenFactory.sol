// file: contracts/token/factory/AgentTokenFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../core/BondingManager.sol";
import "../core/GraduatedToken.sol";

/**
 * @title AgentTokenFactory
 * @author YourName
 * @notice Factory for deploying new bonding curve instances
 * @dev Creates and tracks new bonding curve managers and their tokens
 */
contract AgentTokenFactory is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /// @notice Template implementation for BondingManager
    address public bondingImplementation;

    /// @notice Base asset used for all curves (e.g. USDC)
    address public baseAsset;

    /// @notice Mapping of deployed managers
    mapping(address => bool) public isManager;

    /// @notice List of all deployed managers
    address[] public managers;

    /// @dev Emitted when a new bonding curve is created
    event BondingManagerCreated(
        address indexed manager,
        string name,
        string symbol,
        address token
    );

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the factory
     * @param bondingImpl_ Address of BondingManager implementation
     * @param baseAsset_ Base asset address (e.g. USDC)
     */
    function initialize(
        address bondingImpl_,
        address baseAsset_
    ) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();

        require(bondingImpl_ != address(0), "Invalid implementation");
        require(baseAsset_ != address(0), "Invalid base asset");

        bondingImplementation = bondingImpl_;
        baseAsset = baseAsset_;
    }

    /**
     * @notice Creates a new bonding curve instance
     * @param name Token name
     * @param symbol Token symbol
     * @param config Initial curve configuration
     * @return manager Address of the new bonding manager
     * @return token Address of the new token
     */
    function createBondingCurve(
        string memory name,
        string memory symbol,
        BondingManager.CurveConfig calldata config
    ) external returns (address manager, address token) {
        // Deploy proxy for BondingManager
        bytes memory initData = abi.encodeWithSelector(
            BondingManager.initialize.selector,
            baseAsset,
            config
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            bondingImplementation,
            initData
        );
        manager = address(proxy);

        // Initialize manager
        BondingManager bondingManager = BondingManager(manager);
        token = bondingManager.launchToken(name, symbol);

        // Record manager
        isManager[manager] = true;
        managers.push(manager);

        emit BondingManagerCreated(
            manager,
            name,
            symbol,
            token
        );
    }

    /**
     * @notice Gets all deployed managers
     * @return List of manager addresses
     */
    function getManagers() external view returns (address[] memory) {
        return managers;
    }

    /**
     * @notice Updates the bonding manager implementation
     * @param newImplementation New implementation address
     */
    function updateBondingImplementation(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), "Invalid implementation");
        bondingImplementation = newImplementation;
    }

    /**
     * @notice Updates the base asset address
     * @param newBaseAsset New base asset address
     */
    function updateBaseAsset(address newBaseAsset) external onlyOwner {
        require(newBaseAsset != address(0), "Invalid asset");
        baseAsset = newBaseAsset;
    }

    /**
     * @dev Required by the UUPS module
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}