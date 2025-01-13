// file: contracts/skill/factory/AgentSkillFactory.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../core/AgentSkillCore.sol";
import "../account/AgentSkillAccount.sol";
import "../registry/ERC6551Registry.sol";
import "../libraries/Constants.sol";
import "../libraries/ErrorLibrary.sol";

/**
 * @title AgentSkillFactory
 * @author ChirperAI
 * @notice Factory contract for deploying the complete Agent Skill system
 * @dev Handles deployment and initialization of all required contracts
 */
contract AgentSkillFactory {
    /**
     * @notice Configuration for system deployment
     * @param name NFT collection name
     * @param symbol NFT collection symbol
     * @param platform Platform signer address
     * @param admin Initial admin address
     * @param initData Additional initialization data (optional)
     */
    struct DeploymentConfig {
        string name;
        string symbol;
        address platform;
        address admin;
        bytes initData;
    }

    /**
     * @notice Deployed system addresses
     * @param agentSkill Address of core contract
     * @param registry Address of ERC6551 registry
     * @param accountImplementation Address of account implementation
     */
    struct DeployedSystem {
        address agentSkill;
        address registry;
        address accountImplementation;
    }

    /**
     * @notice Emitted when a new system is deployed
     * @param deployment The deployed system addresses
     * @param config The configuration used
     * @param deployer The address that initiated deployment
     * @param timestamp When deployment occurred
     */
    event SystemDeployed(
        DeployedSystem deployment,
        DeploymentConfig config,
        address indexed deployer,
        uint256 timestamp
    );

    /**
     * @notice Emitted if deployment fails
     * @param reason The reason for failure
     * @param deployer The address that attempted deployment
     */
    event DeploymentFailed(
        string reason,
        address indexed deployer
    );

    /**
     * @notice Deploys and initializes the complete Agent Skill system
     * @param config The deployment configuration
     * @return deployment The deployed system addresses
     */
    function deploySystem(
        DeploymentConfig calldata config
    ) external returns (DeployedSystem memory deployment) {
        // Validate configuration
        _validateConfig(config);

        try this.deploySystemInternal(config) returns (DeployedSystem memory _deployment) {
            emit SystemDeployed(
                _deployment,
                config,
                msg.sender,
                block.timestamp
            );
            return _deployment;
        } catch Error(string memory reason) {
            emit DeploymentFailed(reason, msg.sender);
            revert ErrorLibrary.OperationFailed("deployment", reason);
        } catch {
            emit DeploymentFailed("Unknown error", msg.sender);
            revert ErrorLibrary.OperationFailed("deployment", "Unknown error");
        }
    }

    /**
     * @notice Internal function to deploy system components
     * @dev Separated to allow proper error handling in main function
     * @param config The deployment configuration
     * @return deployment The deployed system addresses
     */
    function deploySystemInternal(
        DeploymentConfig calldata config
    ) external returns (DeployedSystem memory deployment) {
        require(msg.sender == address(this), "Only internal");

        // Deploy registry
        ERC6551Registry registry = new ERC6551Registry();

        // Deploy account implementation with dummy values
        AgentSkillAccount accountImpl = new AgentSkillAccount(
            address(0),
            0
        );

        // Deploy core implementation
        AgentSkillCore implementation = new AgentSkillCore();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            AgentSkillCore.initialize.selector,
            config.name,
            config.symbol,
            address(registry),
            address(accountImpl),
            config.platform
        );

        // Deploy and initialize proxy
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            initData
        );

        // Transfer admin roles if specified
        if (config.admin != address(0)) {
            // Use payable cast for type conversion
            AgentSkillCore core = AgentSkillCore(payable(address(proxy)));
            core.grantRole(Constants.UPGRADER_ROLE, config.admin);
            core.grantRole(Constants.TAX_MANAGER_ROLE, config.admin);
            core.grantRole(Constants.PAUSER_ROLE, config.admin);
            
            // Renounce deployer roles
            core.renounceRole(Constants.UPGRADER_ROLE, address(this));
            core.renounceRole(Constants.TAX_MANAGER_ROLE, address(this));
            core.renounceRole(Constants.PAUSER_ROLE, address(this));
        }

        // Return deployed addresses
        return DeployedSystem({
            agentSkill: address(proxy),
            registry: address(registry),
            accountImplementation: address(accountImpl)
        });
    }

    /**
     * @notice Validates deployment configuration
     * @param config Configuration to validate
     */
    function _validateConfig(DeploymentConfig calldata config) internal pure {
        // Check name and symbol
        if (bytes(config.name).length == 0) {
            revert ErrorLibrary.InvalidParameter("name", "Cannot be empty");
        }
        if (bytes(config.symbol).length == 0) {
            revert ErrorLibrary.InvalidParameter("symbol", "Cannot be empty");
        }

        // Check platform signer
        ErrorLibrary.validateAddress(config.platform, "platform");

        // Optional admin address can be zero
        // Optional init data validation if needed
    }

    /**
     * @notice Estimates gas needed for deployment
     * @param config The deployment configuration
     * @return gasEstimate The estimated gas required
     */
    function estimateDeploymentGas(
        DeploymentConfig calldata config
    ) external view returns (uint256 gasEstimate) {
        _validateConfig(config);
        
        // Base cost for contract deployments
        gasEstimate = 3000000; // Base estimate

        // Add costs for initialization
        gasEstimate += bytes(config.name).length * 100;
        gasEstimate += bytes(config.symbol).length * 100;
        gasEstimate += config.initData.length * 100;

        // Add role management costs
        if (config.admin != address(0)) {
            gasEstimate += 100000;
        }

        return gasEstimate;
    }
}