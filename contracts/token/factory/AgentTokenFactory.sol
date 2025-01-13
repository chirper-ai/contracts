// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../core/AgentBondingManager.sol";
import "../core/AgentToken.sol";

/**
 * @title AgentTokenFactory
 * @notice Deploys a new AgentBondingManager and AgentToken, each behind ERC1967Proxy
 */
contract AgentTokenFactory is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // =============================================================
    //                          CONSTANTS
    // =============================================================

    /// @notice Role identifier for contract upgrader
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    
    /// @notice Role identifier for pause functionality
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // =============================================================
    //                          STRUCTS
    // =============================================================

    /**
     * @notice Configuration needed to deploy a new system
     */
    struct DeploymentConfig {
        // AgentToken init args
        string name;
        string symbol;
        address platform;

        // BondingManager init args
        address baseAsset;
        address taxVault;
        address managerPlatform;
        address uniswapFactory;
        address uniswapRouter;
        uint256 graduationThreshold;
        uint256 assetRate;
        uint256 initialBuyAmount;
    }

    /**
     * @notice Return object containing addresses of deployed contracts
     */
    struct DeployedSystem {
        address managerProxy;
        address tokenProxy;
    }

    // =============================================================
    //                           EVENTS
    // =============================================================

    /**
     * @notice Emitted when a new system is deployed
     */
    event SystemDeployed(
        DeployedSystem deployment,
        DeploymentConfig config,
        address indexed deployer,
        uint256 timestamp
    );

    // =============================================================
    //                         INITIALIZER
    // =============================================================

    /**
     * @notice Initializes the factory
     * @param admin Address that will receive admin roles
     */
    function initialize(address admin) external initializer {
        require(admin != address(0), "Invalid admin");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    // =============================================================
    //                    DEPLOYMENT FUNCTION
    // =============================================================

    /**
     * @notice Deploys and initializes a new AgentBondingManager and AgentToken
     * @param config The deployment configuration
     * @return deployment Addresses of the proxies
     */
    function deploySystem(
        DeploymentConfig calldata config
    )
        external
        nonReentrant
        whenNotPaused
        returns (DeployedSystem memory deployment)
    {
        // Validate config
        _validateConfig(config);

        // First transfer the initial buy amount to this contract
        IERC20(config.baseAsset).safeTransferFrom(msg.sender, address(this), config.initialBuyAmount);

        // Deploy manager implementation
        AgentBondingManager managerImpl = new AgentBondingManager();

        // Prepare manager initializer
        bytes memory managerInitData = abi.encodeWithSelector(
            AgentBondingManager.initialize.selector,
            config.baseAsset,
            config.taxVault,
            config.managerPlatform,
            config.uniswapFactory,
            config.uniswapRouter,
            config.graduationThreshold,
            config.assetRate,
            config.initialBuyAmount
        );

        // Deploy manager proxy
        ERC1967Proxy managerProxy = new ERC1967Proxy(
            address(managerImpl),
            managerInitData
        );

        // Deploy token implementation
        AgentToken tokenImpl = new AgentToken();

        // Prepare token initializer
        bytes memory tokenInitData = abi.encodeWithSelector(
            AgentToken.initialize.selector,
            config.name,
            config.symbol,
            address(managerProxy),
            config.taxVault,
            config.platform
        );

        // Deploy token proxy
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            tokenInitData
        );

        // Approve manager to spend base asset
        IERC20(config.baseAsset).approve(address(managerProxy), config.initialBuyAmount);

        // Register token with manager
        AgentBondingManager(address(managerProxy)).launchToken(address(tokenProxy));

        // Prepare return value
        DeployedSystem memory result = DeployedSystem({
            managerProxy: address(managerProxy),
            tokenProxy: address(tokenProxy)
        });

        emit SystemDeployed(result, config, msg.sender, block.timestamp);

        return result;
    }

    // =============================================================
    //                    VALIDATION FUNCTION
    // =============================================================

    /**
     * @notice Validates deployment configuration
     * @param config Configuration to validate
     */
    function _validateConfig(DeploymentConfig calldata config) internal pure {
        require(bytes(config.name).length > 0, "Invalid name");
        require(bytes(config.symbol).length > 0, "Invalid symbol");
        require(config.platform != address(0), "Invalid platform");
        require(config.baseAsset != address(0), "Invalid base asset");
        require(config.taxVault != address(0), "Invalid tax vault");
        require(config.managerPlatform != address(0), "Invalid manager platform");
        require(config.uniswapFactory != address(0), "Invalid Uniswap factory");
        require(config.uniswapRouter != address(0), "Invalid Uniswap router");
        require(config.graduationThreshold > 0, "Invalid graduation threshold");
        require(config.assetRate > 0, "Invalid asset rate");
        require(config.initialBuyAmount > 0, "Invalid initial buy amount");
    }

    // =============================================================
    //                    ADMIN FUNCTIONS
    // =============================================================

    /**
     * @notice Pauses the factory
     */
    function pauseFactory() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the factory
     */
    function unpauseFactory() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}