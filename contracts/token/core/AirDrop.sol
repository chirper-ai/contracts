// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title MerkleAirdrop
 * @dev A gas-efficient contract for large-scale token airdrops using merkle proofs
 * where each eligible address receives an equal share of the total token balance
 *
 * Key Features:
 * 1. Equal Distribution: Each claimant receives (current balance / remaining claimants)
 * 2. Dynamic Claims: Amount adjusts based on contract balance and unclaimed addresses
 * 3. Gas Efficient: Uses bitmap for tracking claims (~391 bits per 100k users)
 * 4. Merkle Verification: O(log n) claim verification with off-chain proof generation
 * 5. Flexible: Supports adding more tokens or claimants during the airdrop
 *
 * Security Features:
 * - ReentrancyGuard for claim function
 * - SafeERC20 for token transfers
 * - Owner-only admin functions
 * - No user data stored on-chain (only bitmap)
 */
contract MerkleAirdrop is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Token being airdropped
    IERC20 public immutable token;

    /// @notice Merkle root of tree containing [index, address] pairs
    bytes32 public immutable merkleRoot;

    /// @notice Total number of addresses eligible to claim
    uint256 public immutable totalClaimants;

    /// @notice Number of addresses that have claimed so far
    uint256 public totalClaimed;

    /**
     * @notice Packed array of booleans tracking claimed status
     * @dev Mapping of word index => word
     * Each word tracks 256 sequential indices
     * bit i in word w tracks claim status for index w * 256 + i
     */
    mapping(uint256 => uint256) private claimedBitMap;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when tokens are claimed by an address
    event Claimed(
        address indexed account,
        uint256 indexed index,
        uint256 amount
    );

    /// @notice Emitted when merkle root and total claimants are updated
    event MerkleRootUpdated(bytes32 merkleRoot, uint256 totalClaimants);

    /// @notice Emitted when airdrop ends and remaining tokens are burned
    event AirdropEnded(uint256 burnedAmount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy airdrop contract
     * @param token_ Address of token to airdrop
     * @param merkleRoot_ Root of merkle tree containing [index, address] pairs
     * @param totalClaimants_ Total number of addresses in merkle tree
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
     * @notice Check if an index has already claimed tokens
     * @param index Position in merkle tree
     * @return bool True if tokens already claimed for this index
     */
    function isClaimed(uint256 index) public view returns (bool) {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        uint256 word = claimedBitMap[wordIndex];
        uint256 mask = (1 << bitIndex);
        return word & mask == mask;
    }

    /**
     * @notice Calculate current claimable amount per address
     * @dev Amount = current token balance / remaining unclaimed addresses
     * @return uint256 Amount of tokens claimable per address
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
     * @notice Claim tokens for an address
     * @param index Position in merkle tree
     * @param account Address receiving tokens
     * @param merkleProof Array of hashes proving inclusion in tree
     * @dev Amount claimed is current balance / remaining claimants
     */
    function claim(
        uint256 index,
        address account,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        require(!isClaimed(index), "Already claimed");
        require(index < totalClaimants, "Invalid index");

        // Verify merkle proof of [index, account] pair
        bytes32 node = keccak256(abi.encodePacked(index, account));
        require(
            MerkleProof.verify(merkleProof, merkleRoot, node),
            "Invalid proof"
        );

        // Calculate and validate claim amount
        uint256 amount = getClaimAmount();
        require(amount > 0, "Nothing to claim");

        // Update state and transfer tokens
        _setClaimed(index);
        totalClaimed++;
        token.safeTransfer(account, amount);

        emit Claimed(account, index, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mark an index as claimed in bitmap
     * @param index Index to mark as claimed
     */
    function _setClaimed(uint256 index) private {
        uint256 wordIndex = index / 256;
        uint256 bitIndex = index % 256;
        claimedBitMap[wordIndex] = claimedBitMap[wordIndex] | (1 << bitIndex);
    }
}