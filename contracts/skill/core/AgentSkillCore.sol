// file: contracts/skill/core/AgentSkillCore.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IAgentSkill.sol";
import "../interfaces/IERC6551Account.sol";
import "./AgentSkillStorage.sol";
import "../libraries/Constants.sol";
import "../libraries/ErrorLibrary.sol";
import "../libraries/SafeCall.sol";

/**
 * @title AgentSkillCore
 * @author ChirperAI
 * @notice Main implementation of the Agent Skill NFT system with bound accounts
 * @dev Implements NFT functionality, ERC6551 account binding, and fee management
 */
contract AgentSkillCore is 
    Initializable,
    ERC721Upgradeable,
    ERC2981Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    AgentSkillStorage,
    IAgentSkill 
{
    using SafeERC20 for IERC20;
    using ECDSAUpgradeable for bytes32;
    using SafeCall for address;

    /**
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract
     * @param name NFT collection name
     * @param symbol NFT collection symbol
     * @param registry ERC6551 registry address
     * @param implementation Account implementation address
     * @param platform Platform signer address
     */
    function initialize(
        string memory name,
        string memory symbol,
        address registry,
        address implementation,
        address platform
    ) external initializer {
        // Validate addresses
        ErrorLibrary.validateAddress(registry, "registry");
        ErrorLibrary.validateAddress(implementation, "implementation");
        ErrorLibrary.validateAddress(platform, "platform");

        // Initialize inherited contracts
        __ERC721_init(name, symbol);
        __ERC2981_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        // Set core protocol addresses
        accountRegistry = IERC6551Registry(registry);
        accountImplementation = implementation;
        platformSigner = platform;

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(Constants.UPGRADER_ROLE, msg.sender);
        _grantRole(Constants.FEE_MANAGER_ROLE, msg.sender);
        _grantRole(Constants.PAUSER_ROLE, msg.sender);
        _grantRole(Constants.PLATFORM_ROLE, platform);

        // Enable default features
        burnEnabled = true;
        emergencyMode = false;

        // Set initial timestamp
        lastUpgradeTimestamp = block.timestamp;
    }

    /**
     * @inheritdoc IAgentSkill
     */
    function mint(
        MintConfig calldata config
    ) external payable override whenNotPaused nonReentrant returns (
        uint256 tokenId, 
        address accountAddress
    ) {
        // Validate config
        ErrorLibrary.validateAddress(config.to, "recipient");
        ErrorLibrary.validateAddress(config.agent, "agent");
        if (config.inferencePrice < Constants.MIN_INFERENCE_PRICE || 
            config.inferencePrice > Constants.MAX_INFERENCE_PRICE) {
            revert ErrorLibrary.InvalidAmount(
                config.inferencePrice, 
                "inferencePrice", 
                Constants.ERR_INVALID_PRICE
            );
        }

        // Check deadline
        if (block.timestamp > config.deadline) {
            revert ErrorLibrary.DeadlinePassed(config.deadline, block.timestamp);
        }

        // Verify platform signature if caller is not platform
        if (!hasRole(Constants.PLATFORM_ROLE, msg.sender)) {
            _verifyPlatformSignature(
                keccak256(abi.encode(
                    "MINT",
                    config.to,
                    config.agent,
                    config.mintPrice,
                    config.inferencePrice,
                    config.deadline
                )),
                config.platformSignature
            );

            // Verify payment
            if (msg.value < config.mintPrice) {
                revert ErrorLibrary.InsufficientPayment(config.mintPrice, msg.value);
            }

            // Split mint payment
            uint256 creatorShare = msg.value / 2;
            uint256 platformShare = msg.value - creatorShare;
            
            // Transfer shares
            SafeCall.safeTransferETH(msg.sender, creatorShare);
            SafeCall.safeTransferETH(platformSigner, platformShare);
        }

        // Increment counter and mint
        _tokenIdCounter.increment();
        tokenId = _tokenIdCounter.current();
        
        // Mint token and set royalties
        _safeMint(config.to, tokenId);
        _setTokenRoyalty(tokenId, platformSigner, Constants.TRADE_ROYALTY_BPS);
        
        // Store token information
        tokenExists[tokenId] = true;
        tokenCreationTime[tokenId] = block.timestamp;
        tokenCreators[tokenId] = msg.sender;
        permanentAgent[tokenId] = config.agent;
        mintPrice[tokenId] = config.mintPrice;
        inferencePrice[tokenId] = config.inferencePrice;
        
        // Create bound account
        accountAddress = _createAccount(tokenId);
        
        emit SkillMinted(
            tokenId,
            msg.sender,
            config.to,
            config.agent,
            config.mintPrice,
            config.inferencePrice,
            block.timestamp
        );
        
        return (tokenId, accountAddress);
    }

    /**
     * @inheritdoc IAgentSkill
     */
    function burn(
        uint256 tokenId,
        address recipient,
        uint256 nonce,
        uint256 deadline,
        bytes calldata platformSig
    ) external override whenNotPaused nonReentrant tokenMustExist(tokenId) {
        // Validate caller and state
        if (msg.sender != ownerOf(tokenId)) {
            revert ErrorLibrary.NotAuthorized(msg.sender, tokenId, 0);
        }
        if (!burnEnabled) {
            revert ErrorLibrary.TokenBurningDisabled(tokenId);
        }
        ErrorLibrary.validateAddress(recipient, "recipient");
        ErrorLibrary.validateDeadline(deadline);

        // Verify nonce
        if (nonces[msg.sender] != nonce) {
            revert ErrorLibrary.InvalidNonce(nonce, nonces[msg.sender]);
        }
        nonces[msg.sender]++;

        // Verify platform signature
        bytes32 messageHash = keccak256(abi.encode(
            "BURN",
            tokenId,
            recipient,
            nonce,
            deadline
        ));
        _verifyPlatformSignature(messageHash, platformSig);

        // Handle bound account assets
        address account = boundAccounts[tokenId];
        if (account != address(0)) {
            // Transfer native token balance
            uint256 nativeBalance = account.balance;
            if (nativeBalance > 0) {
                IERC6551Account(account).executeCall(
                    recipient,
                    nativeBalance,
                    new bytes(0)
                );
            }

            // Distribute any pending inference fees
            uint256 pendingFees = pendingInferenceFees[tokenId];
            if (pendingFees > 0) {
                _distributeInferenceFees(tokenId, pendingFees);
            }
        }

        // Clear token storage
        delete boundAccounts[tokenId];
        delete permanentAgent[tokenId];
        delete mintPrice[tokenId];
        delete inferencePrice[tokenId];
        delete pendingInferenceFees[tokenId];
        delete tokenExists[tokenId];
        delete tokenCreationTime[tokenId];
        delete inferenceCount[tokenId];
        delete lastInferenceTime[tokenId];
        delete tokenLocked[tokenId];

        _burn(tokenId);
        
        emit SkillBurned(tokenId, msg.sender, "User initiated burn");
    }

    /**
     * @inheritdoc IAgentSkill
     */
    function executeContract(
        uint256 tokenId,
        address target,
        address token,
        uint256 amount,
        bytes calldata data
    ) external override whenNotPaused nonReentrant tokenMustExist(tokenId) returns (
        bool success,
        bytes memory result
    ) {
        // Validate caller authorization
        if (msg.sender != permanentAgent[tokenId] && msg.sender != ownerOf(tokenId)) {
            revert ErrorLibrary.NotAuthorized(msg.sender, tokenId, 0);
        }
        ErrorLibrary.validateAddress(target, "target");

        // Get bound account
        address account = boundAccounts[tokenId];
        if (account == address(0)) {
            revert ErrorLibrary.AccountNotInitialized(tokenId, account);
        }

        // Calculate execution fee
        uint256 fee = (amount * Constants.EXECUTION_FEE_BPS) / Constants.BASIS_POINTS;
        uint256 remainingAmount = amount - fee;

        // Handle token transfers and fees
        if (token != Constants.ETH_ADDRESS) {
            // ERC20 token
            tokenFees[token] += fee;
            
            // Transfer tokens to account
            IERC20(token).safeTransferFrom(msg.sender, account, amount);
        }

        // Execute call through bound account
        try IERC6551Account(account).executeCall(
            target,
            remainingAmount,
            data
        ) returns (bool _success, bytes memory _result) {
            success = _success;
            result = _result;
        } catch Error(string memory reason) {
            revert ErrorLibrary.OperationFailed("execute", reason);
        } catch {
            revert ErrorLibrary.OperationFailed("execute", "unknown error");
        }

        emit ContractExecuted(
            tokenId,
            account,
            target,
            token,
            amount,
            fee,
            success
        );

        return (success, result);
    }

    /**
     * @inheritdoc IAgentSkill
     */
    function requestInference(
        InferenceRequest[] calldata requests
    ) external payable override whenNotPaused nonReentrant returns (
        uint256[] memory requestIds
    ) {
        // Validate batch size
        uint256 batchSize = requests.length;
        if (batchSize == 0 || batchSize > Constants.MAX_BATCH_SIZE) {
            revert ErrorLibrary.InvalidParameter("batchSize", "Invalid batch size");
        }

        // Calculate total required payment
        uint256 totalRequired = 0;
        for (uint256 i = 0; i < batchSize; i++) {
            InferenceRequest calldata request = requests[i];
            
            // Validate token
            if (!tokenExists[request.tokenId]) {
                revert ErrorLibrary.TokenNonexistent(request.tokenId);
            }

            // Validate price
            uint256 price = inferencePrice[request.tokenId];
            if (price > request.maxFee) {
                revert ErrorLibrary.InsufficientPayment(price, request.maxFee);
            }

            totalRequired += price;
        }

        // Verify total payment
        if (msg.value < totalRequired) {
            revert ErrorLibrary.InsufficientPayment(totalRequired, msg.value);
        }

        // Process each request
        requestIds = new uint256[](batchSize);
        for (uint256 i = 0; i < batchSize; i++) {
            InferenceRequest calldata request = requests[i];
            
            // Generate request ID
            bytes32 requestId = keccak256(abi.encode(
                request.tokenId,
                msg.sender,
                block.timestamp,
                inferenceCount[request.tokenId]
            ));

            // Store request info
            inferenceRequestExists[requestId] = true;
            inferenceRequestExpiry[requestId] = block.timestamp + Constants.MAX_INFERENCE_DURATION;
            
            // Update token stats
            inferenceCount[request.tokenId]++;
            lastInferenceTime[request.tokenId] = block.timestamp;
            
            // Add to pending fees
            pendingInferenceFees[request.tokenId] += inferencePrice[request.tokenId];

            emit InferenceRequested(
                request.tokenId,
                msg.sender,
                request.data,
                inferencePrice[request.tokenId],
                block.timestamp
            );

            requestIds[i] = uint256(requestId);
        }

        // Refund excess payment if any
        uint256 excess = msg.value - totalRequired;
        if (excess > 0) {
            SafeCall.safeTransferETH(msg.sender, excess);
        }

        return requestIds;
    }

    /**
     * @inheritdoc IAgentSkill
     */
    function completeInference(
        uint256 requestId,
        bytes calldata result,
        bytes calldata processingMetrics
    ) external override onlyRole(Constants.PLATFORM_ROLE) whenNotPaused {
        // Convert to bytes32 for storage lookup
        bytes32 requestIdBytes = bytes32(requestId);
        
        // Validate request exists and hasn't expired
        if (!inferenceRequestExists[requestIdBytes]) {
            revert ErrorLibrary.InvalidInferenceRequest(requestId);
        }
        if (block.timestamp > inferenceRequestExpiry[requestIdBytes]) {
            revert ErrorLibrary.InferenceTimeout(requestId, inferenceRequestExpiry[requestIdBytes]);
        }

        // Extract token ID from request (first 32 bytes of result contain tokenId)
        uint256 tokenId = uint256(bytes32(result[:32]));
        if (!tokenExists[tokenId]) {
            revert ErrorLibrary.TokenNonexistent(tokenId);
        }

        // Distribute pending fees
        uint256 pendingFees = pendingInferenceFees[tokenId];
        if (pendingFees > 0) {
            _distributeInferenceFees(tokenId, pendingFees);
            delete pendingInferenceFees[tokenId];
        }

        // Clean up request data
        delete inferenceRequestExists[requestIdBytes];
        delete inferenceRequestExpiry[requestIdBytes];

        // Calculate processing time
        uint256 processingTime = block.timestamp - lastInferenceTime[tokenId];

        emit InferenceCompleted(
            tokenId,
            lastInferenceTime[tokenId],
            result,
            processingTime
        );
    }

    /**
     * @inheritdoc IAgentSkill
     */
    function emergencyWithdraw(
        WithdrawalConfig calldata config
    ) external override whenNotPaused nonReentrant returns (uint256[] memory amounts) {
        // Validate basic parameters
        ErrorLibrary.validateAddress(config.recipient, "recipient");
        ErrorLibrary.validateDeadline(config.deadline);

        // Verify token exists and get account
        if (!tokenExists[config.tokenId]) {
            revert ErrorLibrary.TokenNonexistent(config.tokenId);
        }
        address account = boundAccounts[config.tokenId];
        if (account == address(0)) {
            revert ErrorLibrary.AccountNotInitialized(config.tokenId, account);
        }

        // Verify nonce
        if (nonces[msg.sender] != config.nonce) {
            revert ErrorLibrary.InvalidNonce(config.nonce, nonces[msg.sender]);
        }
        nonces[msg.sender]++;

        // Create withdrawal message hash
        bytes32 messageHash = keccak256(abi.encode(
            Constants.EMERGENCY_WITHDRAW_TYPEHASH,
            config.tokenId,
            config.recipient,
            config.tokens,
            config.nonce,
            config.deadline
        ));

        // Verify owner signature
        address owner = ownerOf(config.tokenId);
        if (!_verifySignature(messageHash, config.ownerSignature, owner)) {
            revert ErrorLibrary.InvalidSignature(owner, messageHash, config.ownerSignature);
        }

        // Verify platform signature
        if (!_verifySignature(messageHash, config.platformSignature, platformSigner)) {
            revert ErrorLibrary.InvalidSignature(platformSigner, messageHash, config.platformSignature);
        }

        // Process withdrawals
        uint256[] memory _amounts = new uint256[](config.tokens.length);
        for (uint256 i = 0; i < config.tokens.length; i++) {
            address token = config.tokens[i];
            if (token == Constants.ETH_ADDRESS) {
                // Native token withdrawal
                uint256 balance = account.balance;
                if (balance > 0) {
                    (bool success, bytes memory result) = IERC6551Account(account).executeCall(
                        config.recipient,
                        balance,
                        new bytes(0)
                    );
                    if (!success) {
                        revert ErrorLibrary.OperationFailed(
                            "withdraw ETH",
                            result.length > 0 ? string(result) : "Transfer failed"
                        );
                    }
                    _amounts[i] = balance;
                }
            } else {
                // ERC20 token withdrawal
                uint256 balance = IERC20(token).balanceOf(account);
                if (balance > 0) {
                    bytes memory transferData = abi.encodeWithSelector(
                        IERC20.transfer.selector,
                        config.recipient,
                        balance
                    );
                    (bool success, bytes memory result) = IERC6551Account(account).executeCall(
                        token,
                        0,
                        transferData
                    );
                    if (!success) {
                        revert ErrorLibrary.OperationFailed(
                            "withdraw ERC20",
                            result.length > 0 ? string(result) : "Transfer failed"
                        );
                    }
                    _amounts[i] = balance;
                }
            }
        }

        emit EmergencyWithdrawal(
            config.tokenId,
            account,
            config.recipient,
            config.tokens,
            _amounts,
            "Emergency withdrawal requested"
        );

        return _amounts;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a bound account for a token
     * @param tokenId The token ID to create an account for
     * @return account The address of the created account
     */
    function _createAccount(
        uint256 tokenId
    ) internal returns (address account) {
        try accountRegistry.createAccount(
            accountImplementation,
            block.chainid,
            address(this),
            tokenId,
            0, // salt
            "" // no init data
        ) returns (address _account) {
            if (_account == address(0)) {
                revert ErrorLibrary.AccountCreationFailed(
                    accountImplementation,
                    "Zero address returned"
                );
            }

            // Store account address
            boundAccounts[tokenId] = _account;

            emit AccountCreated(
                tokenId,
                _account,
                accountImplementation,
                0
            );

            return _account;
        } catch Error(string memory reason) {
            revert ErrorLibrary.AccountCreationFailed(
                accountImplementation,
                reason
            );
        } catch {
            revert ErrorLibrary.AccountCreationFailed(
                accountImplementation,
                "Unknown error"
            );
        }
    }

    /**
     * @notice Distributes inference fees between creator and platform
     * @param tokenId Token ID to distribute fees for
     * @param amount Total amount to distribute
     */
    function _distributeInferenceFees(
        uint256 tokenId,
        uint256 amount
    ) internal {
        address creator = tokenCreators[tokenId];
        if (creator == address(0)) {
            revert ErrorLibrary.InvalidAddress(creator, "creator");
        }

        // Calculate shares
        uint256 creatorShare = (amount * Constants.CREATOR_INFERENCE_SHARE) / 100;
        uint256 platformShare = amount - creatorShare;

        // Transfer shares
        bool success1 = SafeCall.safeTransferETH(creator, creatorShare);
        bool success2 = SafeCall.safeTransferETH(platformSigner, platformShare);

        if (!success1 || !success2) {
            revert ErrorLibrary.FeeTransferFailed(
                !success1 ? creator : platformSigner,
                !success1 ? creatorShare : platformShare
            );
        }

        emit InferenceFeesDistributed(
            tokenId,
            creator,
            platformSigner,
            creatorShare,
            platformShare,
            block.timestamp
        );
    }

    /**
     * @notice Verifies a platform signature
     * @param hash Message hash to verify
     * @param signature Signature to verify
     */
    function _verifyPlatformSignature(
        bytes32 hash,
        bytes calldata signature
    ) internal view {
        if (!_verifySignature(hash, signature, platformSigner)) {
            revert ErrorLibrary.InvalidSignature(
                platformSigner,
                hash,
                signature
            );
        }
    }

    /**
     * @notice Verifies a signature against an expected signer
     * @param hash Message hash to verify
     * @param signature Signature to verify
     * @param expectedSigner Address that should have signed
     * @return valid Whether signature is valid
     */
    function _verifySignature(
        bytes32 hash,
        bytes calldata signature,
        address expectedSigner
    ) internal pure returns (bool valid) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        address recoveredSigner = ethSignedHash.recover(signature);
        return recoveredSigner == expectedSigner;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IAgentSkill
     */
    function getAgentAddress(
        uint256 tokenId
    ) external view override tokenMustExist(tokenId) returns (address) {
        return permanentAgent[tokenId];
    }

    /**
     * @inheritdoc IAgentSkill
     */
    function getBoundAccount(
        uint256 tokenId
    ) external view override tokenMustExist(tokenId) returns (address) {
        return boundAccounts[tokenId];
    }

    /**
     * @inheritdoc IAgentSkill
     */
    function getTokenConfig(
        uint256 tokenId
    ) external view override tokenMustExist(tokenId) returns (
        address creator,
        address agent,
        uint256 _mintPrice,
        uint256 _inferencePrice,
        uint256 totalInferences,
        uint256 lastInference
    ) {
        return (
            tokenCreators[tokenId],
            permanentAgent[tokenId],
            mintPrice[tokenId],
            inferencePrice[tokenId],
            inferenceCount[tokenId],
            lastInferenceTime[tokenId]
        );
    }

    /**
     * @inheritdoc IAgentSkill
     */
    function isTokenActive(
        uint256 tokenId
    ) external view override returns (bool isActive, string memory reason) {
        if (!tokenExists[tokenId]) {
            return (false, "Token does not exist");
        }
        if (tokenLocked[tokenId]) {
            return (false, "Token is locked");
        }
        if (boundAccounts[tokenId] == address(0)) {
            return (false, "No bound account");
        }
        return (true, "Token is active");
    }

    /*//////////////////////////////////////////////////////////////
                        INHERITANCE OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Authorizes an upgrade
     * @param newImplementation Address of new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Constants.UPGRADER_ROLE) {
        if (block.timestamp < lastUpgradeTimestamp + Constants.MIN_OPERATION_DELAY) {
            revert ErrorLibrary.InvalidOperation("Upgrade delay not met");
        }
        lastUpgradeTimestamp = block.timestamp;
    }

    /**
     * @notice Checks interface support
     * @param interfaceId Interface identifier to check
     * @return bool Whether interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(
        ERC721Upgradeable,
        ERC2981Upgradeable,
        AccessControlUpgradeable
    ) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Receive function to accept ETH
     */
    receive() external payable {}
}