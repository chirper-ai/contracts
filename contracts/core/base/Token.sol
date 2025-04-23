// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// imports
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// locals
import { ISemver } from "../../interfaces/ISemver.sol";
import { Predeploys } from "../../libraries/Predeploys.sol";
import { Unauthorized } from "../../libraries/CommonErrors.sol";
import { IERC7802, IERC165 } from "../../interfaces/IERC7802.sol";

/**
 * @title Token
 * @dev ERC20 token implementation for AI agents with graduation mechanics.
 * 
 * Core features:
 * 1. Trading Phases
 *    - Pre-graduation: Trades exclusively through bonding curve via Router contract
 *      * Router contract handles tax collection and distribution
 *    - Post-graduation: Trades through whitelisted DEX pools
 *      * No direct token tax; fees collected by Manager contract from DEX pools
 *    - Graduation is permanent and managed by manager contract
 * 
 * 2. Security Features
 *    - Reentrancy protection on state-changing operations
 *    - Input validation on all parameters
 *    - Immutable core parameters
 *    - Zero address checks
 * 
 * Trading Flow:
 * - Pre-graduation: All trades must go through Router contract which handles:
 *   * Bonding curve mechanics
 *   * Tax collection and distribution
 *   * Creator and treasury fee splitting
 * 
 * - Post-graduation: 
 *   * Trading shifts to whitelisted DEX pools
 *   * No direct token tax
 *   * Manager contract collects fees from DEX trading activity
 */
contract Token is ERC20, ERC20Permit, IERC7802, ISemver, Ownable, ReentrancyGuard {

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Reference URL for token metadata and documentation
    string public url;

    /// @notice Description of token's intended use case
    string public intention;

    /// @notice Address receiving 50% of collected taxes
    address public creator;

    /// @notice Contract controlling graduation process
    address public immutable manager;

    /// @notice Indicates if token has moved to DEX trading phase
    bool public hasGraduated;

    /// @notice Whitelisted DEX pool addresses post-graduation
    mapping(address => bool) public isPool;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Indicates transition to DEX trading phase
     * @param pools Authorized DEX pool addresses
     */
    event Graduated(address[] pools);

    /**
     * @notice Tracks changes to pool whitelist
     * @param pool DEX pool address
     * @param isPool Authorization status
     */
    event PoolUpdated(address indexed pool, bool isPool);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys and configures token contract
     * @param name_ ERC20 token name
     * @param symbol_ ERC20 token symbol
     * @param initialSupply_ Starting token supply (in standard units)
     * @param url_ Metadata URL
     * @param intention_ Token purpose description
     * @param manager_ Graduation manager address
     * @param creator_ Tax recipient address
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        string memory url_,
        string memory intention_,
        address manager_,
        address creator_
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(msg.sender) {
        require(manager_ != address(0), "Invalid manager");
        require(initialSupply_ > 0, "Invalid supply");

        url = url_;
        intention = intention_;
        manager = manager_;
        creator = creator_;

        _mint(msg.sender, initialSupply_);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transitions token to DEX trading phase
     * @param pools Authorized DEX pool addresses
     * @dev Only callable once by manager contract
     */
    function graduate(address[] calldata pools) external nonReentrant {
        require(msg.sender == manager, "Only manager");
        require(!hasGraduated, "Already graduated");
        require(pools.length > 0, "No pools provided");

        hasGraduated = true;

        for (uint256 i = 0; i < pools.length; i++) {
            require(pools[i] != address(0), "Invalid pool");
            isPool[pools[i]] = true;
            emit PoolUpdated(pools[i], true);
        }

        emit Graduated(pools);
    }

    /**
     * @notice sets the creator address
     * @param newCreator new creator address
     * @dev Only callable by owner
     */
    function setCreator(address newCreator) external onlyOwner {
        require(newCreator != address(0), "Invalid creator");
        creator = newCreator;
    }

    /*//////////////////////////////////////////////////////////////
                           SUPERCHAIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Semantic version.
    /// @custom:semver 1.0.0-beta.8
    function version() external view virtual returns (string memory) {
        return "1.0.0-beta.8";
    }

    /// @notice Allows the SuperchainTokenBridge to mint tokens.
    /// @param _to     Address to mint tokens to.
    /// @param _amount Amount of tokens to mint.
    function crosschainMint(address _to, uint256 _amount) external {
        if (msg.sender != Predeploys.SUPERCHAIN_TOKEN_BRIDGE) revert Unauthorized();

        _mint(_to, _amount);

        emit CrosschainMint(_to, _amount, msg.sender);
    }

    /// @notice Allows the SuperchainTokenBridge to burn tokens.
    /// @param _from   Address to burn tokens from.
    /// @param _amount Amount of tokens to burn.
    function crosschainBurn(address _from, uint256 _amount) external {
        if (msg.sender != Predeploys.SUPERCHAIN_TOKEN_BRIDGE) revert Unauthorized();

        _burn(_from, _amount);

        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) public view virtual returns (bool) {
        return _interfaceId == type(IERC7802).interfaceId || _interfaceId == type(IERC20).interfaceId
            || _interfaceId == type(IERC165).interfaceId;
    }
}