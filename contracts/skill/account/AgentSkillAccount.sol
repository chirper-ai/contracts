// file: contracts/skill/account/AgentSkillAccount.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IERC6551Account.sol";
import "../interfaces/IAgentSkill.sol";
import "../libraries/Constants.sol";
import "../libraries/ErrorLibrary.sol";
import "../libraries/SafeCall.sol";

/**
 * @title AgentSkillAccount
 * @author ChirperAI
 * @notice Token bound account implementation for Agent Skills with enhanced security
 * @dev Implements ERC6551Account with additional safety features and reentry protection
 */
contract AgentSkillAccount is 
    IERC6551Account, 
    IERC165, 
    IERC1271,
    ReentrancyGuard 
{
    // Immutable state variables
    address public immutable tokenContract;
    uint256 public immutable tokenId;
    uint256 public immutable chainId;

    // State tracking
    uint256 private _nonce;
    uint256 private _lastOperationTimestamp;
    bool private _locked;
    mapping(bytes32 => bool) private _usedSignatures;

    /**
     * @notice Creates a new token bound account
     * @param _tokenContract The NFT contract address
     * @param _tokenId The token ID
     */
    constructor(
        address _tokenContract,
        uint256 _tokenId
    ) {
        ErrorLibrary.validateAddress(_tokenContract, "tokenContract");
        
        tokenContract = _tokenContract;
        tokenId = _tokenId;
        chainId = block.chainid;
    }

    /**
     * @notice Modifier to check execution authorization
     */
    modifier onlyAuthorized() {
        if (!isValidSigner(msg.sender)) {
            revert ErrorLibrary.TokenUnauthorized(msg.sender, tokenId);
        }
        _;
    }

    /**
     * @notice Modifier to ensure cross-chain replay protection
     */
    modifier onlyChainId() {
        if (chainId != block.chainid) {
            revert ErrorLibrary.InvalidOperation(
                "wrong chain",
                "Operation not valid on this chain"
            );
        }
        _;
    }

    /**
     * @notice Executes a call from this account
     * @dev Includes reentry protection and comprehensive validation
     * @param params Execution parameters
     * @return success Whether the call succeeded
     * @return result The call result
     */
    function executeCall(
        ExecutionParams calldata params
    ) external payable virtual override onlyAuthorized onlyChainId nonReentrant returns (
        bool success,
        bytes memory result
    ) {
        // Validate parameters
        ErrorLibrary.validateAddress(params.to, "target");
        ErrorLibrary.validateDeadline(params.deadline);

        // Verify nonce
        if (_nonce != params.nonce) {
            revert ErrorLibrary.InvalidNonce(params.nonce, _nonce);
        }
        _nonce++;

        // Handle operation type
        if (params.operation == 0) {
            // Regular call
            (success, result) = params.to.call{value: params.value}(params.data);
        } else if (params.operation == 1) {
            // Delegatecall
            (success, result) = params.to.delegatecall(params.data);
        } else {
            revert ErrorLibrary.InvalidOperation(
                "invalid operation",
                "Unsupported operation type"
            );
        }

        if (!success) {
            revert ErrorLibrary.OperationFailed(
                "execute call",
                result.length > 0 ? string(result) : "Call failed"
            );
        }

        // Update state
        _lastOperationTimestamp = block.timestamp;

        emit CallExecuted(
            msg.sender,
            params.to,
            params.value,
            params.data,
            params.operation,
            _nonce - 1
        );

        return (success, result);
    }

    /**
     * @notice Gets the token that owns this account
     * @return info The complete token information
     */
    function token() external view override returns (TokenInfo memory info) {
        return TokenInfo({
            chainId: chainId,
            tokenContract: tokenContract,
            tokenId: tokenId
        });
    }

    /**
     * @notice Returns the current state of the account
     * @return nonce The current nonce
     * @return timestamp The last operation timestamp
     * @return operation The last operation type
     */
    function state() external view override returns (
        uint256 nonce,
        uint256 timestamp,
        uint8 operation
    ) {
        return (_nonce, _lastOperationTimestamp, 0);
    }

    /**
     * @notice Checks if an address is authorized to make calls
     * @param caller The address to check
     * @param params Optional authorization parameters
     * @return authorized Whether the address is authorized
     * @return reason If not authorized, the reason why
     */
    function isAuthorized(
        address caller,
        bytes calldata params
    ) external view override returns (bool authorized, string memory reason) {
        if (chainId != block.chainid) {
            return (false, "Wrong chain");
        }

        try IERC721(tokenContract).ownerOf(tokenId) returns (address owner) {
            if (caller == owner) {
                return (true, "Token owner");
            }
        } catch {
            return (false, "Token does not exist");
        }

        try IAgentSkill(tokenContract).getAgentAddress(tokenId) returns (address agent) {
            if (caller == agent) {
                return (true, "Permanent agent");
            }
        } catch {
            return (false, "Failed to get agent address");
        }

        return (false, "Not authorized");
    }

    /**
     * @notice Implementation of ERC1271 signature validation
     * @param hash Hash of the data to be signed
     * @param signature Signature byte array associated with hash
     * @return magicValue Magic value if valid, 0 if invalid
     */
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) external view override returns (bytes4 magicValue) {
        try IERC721(tokenContract).ownerOf(tokenId) returns (address owner) {
            if (SignatureChecker.isValidSignatureNow(owner, hash, signature)) {
                return IERC1271.isValidSignature.selector;
            }
        } catch {
            return bytes4(0);
        }
        return bytes4(0);
    }

    /**
     * @notice Checks if a signer is valid for this account
     * @param signer Address to check
     * @return valid Whether the signer is valid
     */
    function isValidSigner(
        address signer
    ) public view returns (bool valid) {
        if (chainId != block.chainid) return false;

        try IERC721(tokenContract).ownerOf(tokenId) returns (address owner) {
            if (signer == owner) return true;
        } catch {
            return false;
        }

        try IAgentSkill(tokenContract).getAgentAddress(tokenId) returns (address agent) {
            if (signer == agent) return true;
        } catch {
            return false;
        }

        return false;
    }

    /**
     * @notice Gets the owner token's NFT owner
     * @return owner The current owner of the NFT
     */
    function owner() external view returns (address) {
        return IERC721(tokenContract).ownerOf(tokenId);
    }

    /**
     * @notice Checks if the account is locked
     * @return locked Whether the account is locked
     * @return unlockTime When the account will be unlocked
     */
    function isLocked() external view override returns (bool locked, uint256 unlockTime) {
        return (_locked, 0); // Simple locking implementation
    }

    /**
     * @notice Checks if the account can receive native token
     * @return canReceive Always returns true
     */
    function isPayable() external pure override returns (bool canReceive) {
        return true;
    }

    /**
     * @notice Checks interface support
     * @param interfaceId Interface identifier to check
     * @return supported Whether the interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(IERC165, IERC6551Account) returns (bool supported) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC6551Account).interfaceId ||
            interfaceId == type(IERC1271).interfaceId;
    }

    /**
     * @dev Receive function to accept ETH
     */
    receive() external payable {}
}