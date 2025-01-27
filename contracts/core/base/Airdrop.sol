// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title Airdrop
 * @dev Gas-optimized token airdrop using merkle proofs and bitmap claim tracking
 *
 * Core Features:
 * 1. Dynamic Distribution
 *    - Equal shares: amount = balance / unclaimed_addresses
 *    - Adapts to token additions/removals
 *    - Unclaimed amounts redistribute to remaining users
 *
 * 2. Claim Verification
 *    - Merkle tree stores [index, address] pairs
 *    - O(log n) verification with merkle proofs
 *    - Proofs generated off-chain to save gas
 *
 * 3. Storage Optimization
 *    - Bitmap tracks claimed status
 *    - Each uint256 word stores 256 claim flags
 *    - ~3.9kb storage per million users
 *    - Word index = claimant_index / 256
 *    - Bit position = claimant_index % 256 
 *
 * Example:
 * - 1000 total claimants, 100 tokens deposited
 * - Initial claim amount = 100/1000 = 0.1 tokens
 * - After 500 claims: amount = remaining_tokens/500
 * - Bit 5 in word 2 tracks claim for index 517
 *
 * Security:
 * - Reentrancy protection on claims
 * - SafeERC20 for transfers
 * - Immutable core parameters
 * - No user data stored on-chain
 * - Merkle proof verification
 */
contract Airdrop is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Token contract being distributed
    IERC20 public immutable token;

    /// @notice Root hash of merkle tree containing [index, address] pairs
    bytes32 public immutable merkleRoot;

    /// @notice Total number of addresses in merkle tree
    uint256 public immutable totalClaimants;

    /// @notice Running count of successful claims
    uint256 public totalClaimed;

    /**
     * @notice Packed array tracking claimed status
     * @dev Maps word_index => 256-bit word
     * Each bit in word represents claimed status:
     * - word_index = claimant_index / 256
     * - bit_position = claimant_index % 256
     * - claimed = (word & (1 << bit_position)) != 0
     */
    mapping(uint256 => uint256) private claimedBitMap;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Logs successful token claim
     * @param account Recipient address
     * @param index Position in merkle tree
     * @param amount Tokens transferred
     */
    event Claimed(
        address indexed account,
        uint256 indexed index,
        uint256 amount
    );

    /**
     * @notice Logs merkle root updates
     * @param merkleRoot New root hash
     * @param totalClaimants Updated total claimants
     */
    event MerkleRootUpdated(bytes32 merkleRoot, uint256 totalClaimants);

    /**
     * @notice Logs airdrop completion
     * @param burnedAmount Remaining tokens burned
     */
    event AirdropEnded(uint256 burnedAmount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes airdrop parameters
     * @param token_ ERC20 token address
     * @param merkleRoot_ Root hash of [index, address] pairs
     * @param totalClaimants_ Number of eligible addresses
     * @dev Validates input addresses and claimant count
     */
    constructor(
        address token_,
        bytes32 merkleRoot_,
        uint256 totalClaimants_
    ) Ownable(msg.sender) {
        require(token_ != address(0), "Invalid token");
        require(totalClaimants_ > 0, "No claimants");
        token = IERC20(token_);
        merkleRoot = merkleRoot_;
        totalClaimants = totalClaimants_;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if index has claimed
     * @param index Position in merkle tree
     * @return True if tokens claimed
     * @dev Uses bitmap: word & (1 << bit) != 0
     */
    function isClaimed(uint256 index) public view returns (bool) {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        uint256 word = claimedBitMap[wordIndex];
        uint256 mask = (1 << bitIndex);
        return word & mask == mask;
    }

    /**
     * @notice Calculates current claim amount
     * @return Tokens per remaining claimant
     * @dev amount = balance / unclaimed_addresses
     */
    function getClaimAmount() public view returns (uint256) {
        uint256 remainingClaimants = totalClaimants - totalClaimed;
        if (remainingClaimants == 0) return 0;
        return token.balanceOf(address(this)) / remainingClaimants;
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claims tokens for eligible address
     * @param index Claimant's merkle tree position
     * @param account Recipient address
     * @param merkleProof Proof of inclusion hashes
     * @dev Claim workflow:
     * 1. Verify not already claimed
     * 2. Validate merkle proof
     * 3. Calculate dynamic amount
     * 4. Update bitmap
     * 5. Transfer tokens
     */
    function claim(
        uint256 index,
        address account,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        require(!isClaimed(index), "Already claimed");
        require(index < totalClaimants, "Invalid index");

        bytes32 node = keccak256(abi.encodePacked(index, account));
        require(
            MerkleProof.verify(merkleProof, merkleRoot, node),
            "Invalid proof"
        );

        uint256 amount = getClaimAmount();
        require(amount > 0, "Nothing to claim");

        _setClaimed(index);
        totalClaimed++;
        token.safeTransfer(account, amount);

        emit Claimed(account, index, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets claimed bit in bitmap
     * @param index Bit to set
     * @dev Updates using: word |= (1 << bit)
     */
    function _setClaimed(uint256 index) private {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        claimedBitMap[wordIndex] = claimedBitMap[wordIndex] | (1 << bitIndex);
    }
}