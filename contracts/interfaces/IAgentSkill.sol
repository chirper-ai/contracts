// file: contracts/interfaces/IAgentSkill.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IAgentSkillErrors.sol";
import "./IAgentSkillEvents.sol";

/**
 * @title IAgentSkill
 * @author Your Name
 * @notice Core interface for the AgentSkill NFT system
 * @dev Defines the complete external API for the AgentSkill protocol
 */
interface IAgentSkill is IAgentSkillErrors, IAgentSkillEvents {
    /**
     * @notice Configuration struct for minting new skills
     * @param to Address to receive the NFT
     * @param agent Permanent agent address for the skill
     * @param mintPrice Price others must pay to mint this skill
     * @param inferencePrice Price for inference calls
     * @param data Additional initialization data (if any)
     * @param deadline Timestamp until which the mint config is valid
     * @param platformSignature Platform signature approving the mint
     */
    struct MintConfig {
        address to;
        address agent;
        uint256 mintPrice;
        uint256 inferencePrice;
        bytes data;
        uint256 deadline;
        bytes platformSignature;
    }

    /**
     * @notice Struct for batch inference requests
     * @param tokenId The token ID to use
     * @param data The inference input data
     * @param maxFee Maximum fee willing to pay
     * @param deadline Timestamp until which request is valid
     */
    struct InferenceRequest {
        uint256 tokenId;
        bytes data;
        uint256 maxFee;
        uint256 deadline;
    }

    /**
     * @notice Struct for emergency withdrawal configuration
     * @param tokenId The token ID to withdraw from
     * @param recipient Address to receive assets
     * @param tokens Array of token addresses to withdraw
     * @param nonce Unique nonce for the withdrawal
     * @param deadline Timestamp until which withdrawal is valid
     * @param ownerSignature Token owner's signature
     * @param platformSignature Platform's signature
     */
    struct WithdrawalConfig {
        uint256 tokenId;
        address recipient;
        address[] tokens;
        uint256 nonce;
        uint256 deadline;
        bytes ownerSignature;
        bytes platformSignature;
    }

    /**
     * @notice Creates a new skill NFT with associated bound account
     * @dev Requires payment if caller is not platform and validates platform signature
     * @param config The complete mint configuration
     * @return tokenId The ID of the minted token
     * @return accountAddress The address of the created bound account
     */
    function mint(
        MintConfig calldata config
    ) external payable returns (uint256 tokenId, address accountAddress);

    /**
     * @notice Burns a skill NFT and its bound account
     * @dev Requires both owner and platform approval
     * @param tokenId The ID of the token to burn
     * @param recipient Address to receive any remaining assets
     * @param nonce Unique nonce for the burn operation
     * @param deadline Timestamp until which burn is valid
     * @param platformSig Platform signature approving the burn
     */
    function burn(
        uint256 tokenId,
        address recipient,
        uint256 nonce,
        uint256 deadline,
        bytes calldata platformSig
    ) external;

    /**
     * @notice Executes a contract call through the bound account
     * @dev Only callable by token owner or permanent agent
     * @param tokenId The ID of the token
     * @param target Target contract address
     * @param token Token to use (address(0) for native)
     * @param amount Amount to use
     * @param data Call data
     * @return success Whether the call was successful
     * @return result The call result data
     */
    function executeContract(
        uint256 tokenId,
        address target,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool success, bytes memory result);

    /**
     * @notice Requests one or more inference operations
     * @dev Each request must include adequate payment
     * @param requests Array of inference requests
     * @return requestIds Array of unique IDs for each request
     */
    function requestInference(
        InferenceRequest[] calldata requests
    ) external payable returns (uint256[] memory requestIds);

    /**
     * @notice Completes an inference operation
     * @dev Only callable by the platform
     * @param requestId The ID of the inference request
     * @param result The inference result data
     * @param processingMetrics Optional processing metrics/metadata
     */
    function completeInference(
        uint256 requestId,
        bytes calldata result,
        bytes calldata processingMetrics
    ) external;

    /**
     * @notice Performs an emergency withdrawal of assets
     * @dev Requires both owner and platform signatures
     * @param config The complete withdrawal configuration
     * @return amounts Array of amounts withdrawn for each token
     */
    function emergencyWithdraw(
        WithdrawalConfig calldata config
    ) external returns (uint256[] memory amounts);

    /**
     * @notice Gets the permanent agent address for a token
     * @param tokenId The ID of the token
     * @return agent The permanent agent address
     */
    function getAgentAddress(uint256 tokenId) external view returns (address agent);

    /**
     * @notice Gets the bound account for a token
     * @param tokenId The ID of the token
     * @return account The bound account address
     */
    function getBoundAccount(uint256 tokenId) external view returns (address account);

    /**
     * @notice Gets the complete configuration for a token
     * @param tokenId The ID of the token
     * @return creator The token creator
     * @return agent The permanent agent
     * @return mintPrice Current mint price
     * @return inferencePrice Current inference price
     * @return totalInferences Total number of inferences performed
     * @return lastInferenceTime Timestamp of last inference
     */
    function getTokenConfig(uint256 tokenId) external view returns (
        address creator,
        address agent,
        uint256 mintPrice,
        uint256 inferencePrice,
        uint256 totalInferences,
        uint256 lastInferenceTime
    );

    /**
     * @notice Checks if a token is active and available for inference
     * @param tokenId The ID of the token to check
     * @return isActive Whether the token is active
     * @return reason If inactive, the reason why
     */
    function isTokenActive(
        uint256 tokenId
    ) external view returns (bool isActive, string memory reason);
}