// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../core/AgentBondingManager.sol";
import "../core/AgentToken.sol";
import "../libraries/ErrorLibrary.sol";
import "../libraries/Constants.sol";

/**
 * @title AgentTokenFactory
 * @notice Deploys a new AgentBondingManager and AgentToken, each behind ERC1967Proxy, 
 *         so that both are upgradeable.
 */
contract AgentTokenFactory is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    // ------------------------------------------------------------------------
    // STRUCTS
    // ------------------------------------------------------------------------

    /**
     * @notice Configuration needed to deploy a new system
     * @dev Adjust as needed for your use case
     */
    struct DeploymentConfig {
        // AgentToken init args
        string name;
        string symbol;
        address platform;  // platform admin for the token

        // BondingManager init args
        address baseAsset;       // e.g. USDC
        address registry;        // tax vault or registry
        address managerPlatform; // address with PLATFORM_ROLE in the manager

        // Default config for the new BondingManager
        // ( gradThreshold, dexAdapters, dexWeights, etc. )
        AgentBondingManager.CurveConfig curveConfig;
    }

    /**
     * @notice Return object containing addresses of deployed contracts
     */
    struct DeployedSystem {
        address managerProxy;  // The proxy for AgentBondingManager
        address tokenProxy;    // The proxy for AgentToken
    }

    // ------------------------------------------------------------------------
    // EVENTS
    // ------------------------------------------------------------------------

    event SystemDeployed(
        DeployedSystem deployment,
        DeploymentConfig config,
        address indexed deployer,
        uint256 timestamp
    );

    // ------------------------------------------------------------------------
    // INITIALIZER
    // ------------------------------------------------------------------------

    /**
     * @notice Initializes the factory
     * @dev This replaces the constructor for upgradeable contracts
     * @param admin The address that will receive DEFAULT_ADMIN_ROLE, UPGRADER_ROLE, PAUSER_ROLE
     */
    function initialize(address admin) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Set up roles
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(Constants.UPGRADER_ROLE, admin);
        _setupRole(Constants.PAUSER_ROLE, admin);
    }

    // ------------------------------------------------------------------------
    // DEPLOY SYSTEM (Manager Proxy + Token Proxy)
    // ------------------------------------------------------------------------

    /**
     * @notice Deploys and initializes a new AgentBondingManager and AgentToken, both behind ERC1967Proxy.
     * @dev The Manager and Token each get their own implementation contract.
     *      Alternatively, you could store a single "managerImpl" and "tokenImpl" in this factory
     *      if you want to re-use the same logic each time, instead of redeploying a fresh logic contract.
     *
     * @param config The deployment configuration
     * @return deployment Addresses of the proxies (managerProxy, tokenProxy)
     */
    function deploySystem(
        DeploymentConfig calldata config
    )
        external
        nonReentrant
        whenNotPaused
        returns (DeployedSystem memory deployment)
    {
        // Optional: validate config
        _validateConfig(config);

        // --------------------------------------------------------------------
        // 1. Deploy the AgentBondingManager IMPLEMENTATION
        // --------------------------------------------------------------------
        AgentBondingManager managerImpl = new AgentBondingManager();

        // Prepare the data for AgentBondingManager's initializer:
        //   function initialize(
        //       address _baseAsset,
        //       address _registry,
        //       address _platform,
        //       CurveConfig calldata _config
        //   ) external initializer
        bytes memory managerInitData = abi.encodeWithSelector(
            AgentBondingManager.initialize.selector,
            config.baseAsset,
            config.registry,
            config.managerPlatform,
            config.curveConfig
        );

        // Create the proxy, pointing to managerImpl, then call initialize(...)
        ERC1967Proxy managerProxy = new ERC1967Proxy(
            address(managerImpl),
            managerInitData
        );

        // --------------------------------------------------------------------
        // 2. Deploy the AgentToken IMPLEMENTATION
        // --------------------------------------------------------------------
        AgentToken tokenImpl = new AgentToken();

        // Prepare the initializer data for AgentToken:
        //   function initialize(
        //       string memory name_,
        //       string memory symbol_,
        //       address implementation,  // bondingContract
        //       address registry,        // taxVault
        //       address platform         // platform admin
        //   ) external initializer
        bytes memory tokenInitData = abi.encodeWithSelector(
            AgentToken.initialize.selector,
            config.name,
            config.symbol,
            address(managerProxy),  // let the manager be the bondingContract
            config.registry,        // taxVault
            config.platform         // platform admin (for the token)
        );

        // Create the proxy, pointing to tokenImpl, then call initialize(...)
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            tokenInitData
        );

        // --------------------------------------------------------------------
        // 3. Return the newly deployed proxies
        // --------------------------------------------------------------------
        DeployedSystem memory result = DeployedSystem({
            managerProxy: address(managerProxy),
            tokenProxy: address(tokenProxy)
        });

        // Emit an event
        emit SystemDeployed(result, config, msg.sender, block.timestamp);

        return result;
    }

    // ------------------------------------------------------------------------
    // OPTIONAL VALIDATION
    // ------------------------------------------------------------------------

    function _validateConfig(DeploymentConfig calldata config) internal pure {
        // Example checks
        if (bytes(config.name).length == 0) {
            revert ErrorLibrary.InvalidParameter("name", "Cannot be empty");
        }
        if (bytes(config.symbol).length == 0) {
            revert ErrorLibrary.InvalidParameter("symbol", "Cannot be empty");
        }
        if (config.baseAsset == address(0)) {
            revert ErrorLibrary.InvalidParameter("baseAsset", "Zero address");
        }
        if (config.registry == address(0)) {
            revert ErrorLibrary.InvalidParameter("registry", "Zero address");
        }
        if (config.platform == address(0)) {
            revert ErrorLibrary.InvalidParameter("platform", "Zero address");
        }
        if (config.managerPlatform == address(0)) {
            revert ErrorLibrary.InvalidParameter("managerPlatform", "Zero address");
        }

        // Validate curve weights, threshold, etc. if needed
        if (
            config.curveConfig.dexAdapters.length != config.curveConfig.dexWeights.length
        ) {
            revert ErrorLibrary.InvalidParameter(
                "curveConfig",
                "DEX adapters/weights length mismatch"
            );
        }
    }

    // ------------------------------------------------------------------------
    // ADMIN (Pause/Unpause, etc.)
    // ------------------------------------------------------------------------

    /**
     * @notice Pauses the factory so no new deployments can occur
     */
    function pauseFactory() external onlyRole(Constants.PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the factory
     */
    function unpauseFactory() external onlyRole(Constants.PAUSER_ROLE) {
        _unpause();
    }
}
