
import "./IRouter.sol";

interface IManager {
    struct TokenMetrics {
        address tokenAddr;         // Token contract address
        string name;               // Full token name
        string ticker;             // Trading symbol
        uint256 totalSupply;       // Total token supply
        uint256 circSupply;        // Tokens in circulation (not in bonding pair)
        uint256 price;             // Current price in VANA (1e18 decimals)
        uint256 cap;               // Market cap (circulating * price)
        uint256 fdv;               // Fully diluted value (totalSupply * price)
        uint256 tvl;               // Total value locked in bonding pair
        uint256 lastUpdate;        // Last update timestamp
    }
    struct TokenData {
        address creator;
        address token;
        string intention;
        string url;
        TokenMetrics metrics;
        bool hasGraduated;
        address bondingPair;
        IRouter.DexRouter[] dexRouters;
        address[] dexPools;
    }
    
    function agentTokens(address token) external view returns (TokenData memory);
}