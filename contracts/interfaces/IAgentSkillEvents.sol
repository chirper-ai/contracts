// file: contracts/interfaces/IAgentSkillEvents.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAgentSkillEvents
 * @author ChirperAI
 * @notice Defines all events emitted throughout the AgentSkill protocol
 * @dev Centralizes event definitions to ensure consistency across the protocol
 */
interface IAgentSkillEvents {
    /**
     * @notice Emitted when a new skill NFT is minted
     * @param tokenId The ID of the newly minted token
     * @param creator The address that created the skill
     * @param owner The initial owner of the NFT
     * @param agent The permanent agent address assigned to this skill
     * @param mintPrice The price others must pay to mint copies of this skill
     * @param inferencePrice The price for making inference calls
     * @param timestamp The block timestamp when minting occurred
     */
    event SkillMinted(
        uint256 indexed tokenId,
        address indexed creator,
        address indexed owner,
        address agent,
        uint256 mintPrice,
        uint256 inferencePrice,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a token bound account is created for an NFT
     * @param tokenId The ID of the associated token
     * @param account The address of the created bound account
     * @param implementation The implementation contract used
     * @param salt The salt used in account creation
     */
    event AccountCreated(
        uint256 indexed tokenId,
        address indexed account,
        address implementation,
        uint256 salt
    );

    /**
     * @notice Emitted when a contract is executed through a bound account
     * @param tokenId The ID of the token whose account executed the call
     * @param account The bound account address that executed the call
     * @param target The target contract address
     * @param token The token being used (address(0) for native)
     * @param amount The amount being used
     * @param fee The fee charged for execution
     * @param success Whether the execution was successful
     */
    event ContractExecuted(
        uint256 indexed tokenId,
        address indexed account,
        address indexed target,
        address token,
        uint256 amount,
        uint256 fee,
        bool success
    );

    /**
     * @notice Emitted when an inference request is made
     * @param tokenId The ID of the token being used
     * @param caller The address requesting the inference
     * @param data The inference input data
     * @param fee The fee paid for inference
     * @param timestamp The block timestamp of the request
     */
    event InferenceRequested(
        uint256 indexed tokenId,
        address indexed caller,
        bytes data,
        uint256 fee,
        uint256 timestamp
    );

    /**
     * @notice Emitted when an inference is completed
     * @param tokenId The ID of the token used
     * @param requestTimestamp The timestamp of the original request
     * @param result The inference result data
     * @param processingTime Time taken for inference (in seconds)
     */
    event InferenceCompleted(
        uint256 indexed tokenId,
        uint256 requestTimestamp,
        bytes result,
        uint256 processingTime
    );

    /**
     * @notice Emitted when inference fees are distributed
     * @param tokenId The ID of the token
     * @param creator The creator receiving their share
     * @param platform The platform receiving their share
     * @param creatorAmount Amount sent to creator
     * @param platformAmount Amount sent to platform
     * @param timestamp Distribution timestamp
     */
    event InferenceFeesDistributed(
        uint256 indexed tokenId,
        address indexed creator,
        address indexed platform,
        uint256 creatorAmount,
        uint256 platformAmount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when trade royalties are distributed
     * @param tokenId The ID of the token traded
     * @param seller The address selling the token
     * @param buyer The address buying the token
     * @param creator The creator receiving royalties
     * @param platform The platform receiving royalties
     * @param creatorAmount Amount sent to creator
     * @param platformAmount Amount sent to platform
     */
    event RoyaltiesDistributed(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        address creator,
        address platform,
        uint256 creatorAmount,
        uint256 platformAmount
    );

    /**
     * @notice Emitted when a token is burned
     * @param tokenId The ID of the burned token
     * @param owner The last owner of the token
     * @param reason The reason for burning (if provided)
     */
    event SkillBurned(
        uint256 indexed tokenId,
        address indexed owner,
        string reason
    );

    /**
     * @notice Emitted during an emergency withdrawal
     * @param tokenId The ID of the token
     * @param account The bound account address
     * @param recipient The recipient of the withdrawn assets
     * @param tokens Array of token addresses withdrawn
     * @param amounts Array of amounts withdrawn
     * @param reason The reason for emergency withdrawal
     */
    event EmergencyWithdrawal(
        uint256 indexed tokenId,
        address indexed account,
        address indexed recipient,
        address[] tokens,
        uint256[] amounts,
        string reason
    );

    /**
     * @notice Emitted when the protocol is paused or unpaused
     * @param pauser The address that triggered the pause state change
     * @param isPaused The new pause state
     * @param reason The reason for the state change
     */
    event PauseStateChanged(
        address indexed pauser,
        bool isPaused,
        string reason
    );

    /**
     * @notice Emitted when the platform signer is updated
     * @param oldSigner The previous platform signer
     * @param newSigner The new platform signer
     * @param timestamp When the change occurred
     */
    event PlatformSignerUpdated(
        address indexed oldSigner,
        address indexed newSigner,
        uint256 timestamp
    );
}