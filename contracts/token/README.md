# Chirper.build Bonding Curve Token System

## Overview

This repository provides a **Bonding Curve Token system** as part of the [Chirper.build](https://chirper.build) ecosystem, enabling creation of **upgradeable** tokens and managers with automated market making and **multi-DEX graduation**. Once certain thresholds are reached, liquidity is deployed to decentralized exchanges and the associated LP tokens are burned to lock liquidity.

## Key Features

- **Bonding Curve Logic**: Dynamic token pricing governed by supply and demand
- **Multi-DEX Graduation**: Automated liquidity provisioning on Uniswap V2, Velodrome, etc.
- **Configurable Parameters**: User-defined graduation thresholds, DEX weights, and tax rates
- **Proxy Architecture**: Upgradeable design using **ERC1967** proxies and OpenZeppelin patterns
- **Factory System**: Single function call to deploy both **AgentBondingManager** and **AgentToken** proxies
- **Emergency Controls**: `pause()`/`unpause()` for critical operations and protected rescue mechanisms

## About Chirper.build

[Chirper.build](https://chirper.build) is part of the larger [Chirper.ai](https://chirper.ai) ecosystem, focusing on **DeFi innovations**. This Bonding Curve system contributes:
- Fair distribution of tokens via bonding curves
- Automatic transition to DEX-based liquidity
- Simplified multi-venue liquidity management
- Customizable tax and fee handling

## Architecture

### Core Contracts

1. **AgentToken.sol**
   - **ERC20** implementation
   - **Upgradeable** via ERC1967
   - Pre-graduation **bonding-curve** integration (via `bondingContract`)
   - Post-graduation **DEX** trading with buy/sell tax logic
   - Admin-controlled roles for tax, pausing, etc.

2. **AgentBondingManager.sol**
   - **Upgradeable** manager for one or more tokens
   - Implements **bonding curve mathematics**, handling `buy()` and `sell()` with dynamic pricing
   - **Graduation logic**: sets up liquidity on multiple DEXes and burns LP tokens
   - Configurable tax rates and thresholds
   - Protects reserves via pausing and rescue safeguards

3. **AgentTokenFactory.sol**
   - **Upgradeable Factory** that deploys:
     - A new **AgentBondingManager** (behind its own **ERC1967Proxy**)
     - A new **AgentToken** (behind another **ERC1967Proxy**)
   - Calls each contract’s initializer to set up roles, thresholds, and references
   - Returns the addresses of the newly created proxies (`managerProxy`, `tokenProxy`)

### Adapters

1. **UniswapAdapter.sol**
   - Integrates **Uniswap V2** for liquidity operations
   - Handles add/remove liquidity with the manager
   - Obtains DEX pair addresses for post-graduation

2. **VelodromeAdapter.sol**
   - Integrates **Velodrome** for stable or volatile pools
   - Manages specialized liquidity parameters
   - Provides pair addresses and slippage checks

### Interfaces

1. **IDEXAdapter.sol**
   - Standardizes DEX interactions (add liquidity, get pair)
   - Minimizes code duplication across multiple DEX integrations

## Integration Examples

### Deploying a New Manager & Token (via AgentTokenFactory)

```solidity
// 1. Configure deployment parameters
AgentTokenFactory.DeploymentConfig memory config = AgentTokenFactory.DeploymentConfig({
    // Token details
    name: "MyAgentToken",
    symbol: "MAT",
    platform: 0xPlatformAddress,

    // Manager details
    baseAsset: 0xUSDCAddress,
    registry: 0xTaxVaultOrRegistry,
    managerPlatform: 0xPlatformManagerAddress, // PLATFORM_ROLE for manager

    // Bonding curve config (graduation threshold, DEX adapters, weights)
    curveConfig: AgentBondingManager.CurveConfig({
        gradThreshold: 100_000e18,   // Example: graduate at 100k USDC in reserve
        dexAdapters: [uniswapAdapter, velodromeAdapter],
        dexWeights: [50, 50]        // 50% of liquidity to each DEX
    })
});

// 2. Deploy the system via the upgradeable factory
AgentTokenFactory.DeployedSystem memory result = factory.deploySystem(config);

// 3. The returned proxies for manager & token
address managerProxy = result.managerProxy;
address tokenProxy = result.tokenProxy;

// Both managerProxy and tokenProxy are now independently upgradeable.
```

### Creating a Bonding-Curve Token Directly in the Manager (If Needed)

Alternatively, if you use **one** AgentBondingManager instance that spawns tokens without separate proxies for each new token, call:

```solidity
// (Inside AgentBondingManager)
// Example usage:
address newToken = agentBondingManager.launchToken(
    "MyAgentToken",
    "MAT",
    0xPlatformAddress
);
```

> **Note**: This approach is simpler but yields a **non-upgradeable** token unless you also wrap it in a proxy. The factory approach is recommended if every token must be upgradeable.

### Trading on Bonding Curve

Once a token is deployed, trades can happen via the `AgentBondingManager`:
```solidity
// Example: Buy 1000 units of baseAsset worth of tokens
uint256 assetAmount = 1000e18;  
uint256 receivedTokens = AgentBondingManager(managerProxy).buy(tokenProxy, assetAmount);

// Example: Sell 500 tokens back to the curve
uint256 sellAmount = 500e18;    
uint256 returnedAssets = AgentBondingManager(managerProxy).sell(tokenProxy, sellAmount);
```

When `assetReserve` exceeds `gradThreshold`, the manager calls `_graduate(tokenProxy)`, which:
- Splits liquidity among configured DEXes
- Burns the resulting LP tokens
- Flags the token as “graduated”

## Fee Structure

1. **Buy/Sell Taxes**
   - Defined in `AgentBondingManager` and `AgentToken`
   - Splits between **platform** and **creator** addresses
   - Rates managed by **TAX_MANAGER_ROLE**

2. **Graduation Liquidity**
   - On graduation, liquidity is added to each adapter’s DEX and the LP is burned
   - Weights determined by `dexWeights[]`

## Deployment

### 1. Deploy AgentTokenFactory

If you want **every** manager-token pair to be upgradeable, first deploy the **AgentTokenFactory** itself (which can also be behind a proxy if you wish). For Hardhat:

```bash
npx hardhat run scripts/deployAgentTokenFactory.js --network mainnet
```

Inside your script, you might do:
```js
const AgentTokenFactory = await ethers.getContractFactory("AgentTokenFactory");
const factoryProxy = await upgrades.deployProxy(AgentTokenFactory, [adminAddress], { kind: "uups" });
await factoryProxy.deployed();
console.log("AgentTokenFactory deployed at:", factoryProxy.address);
```

### 2. Deploy Each New Manager & Token Pair

Use the newly deployed factory to create a **fresh** upgradeable system:

```solidity
// Example code snippet after you have a reference to factoryProxy
AgentTokenFactory(factoryProxy).deploySystem(config);
```

The factory returns `managerProxy` and `tokenProxy` addresses, each pointing to its own upgradeable proxy instance.

### 3. Configure DEX Adapters

Deploy and configure your **UniswapAdapter** and **VelodromeAdapter** so the manager can interact with them. You’ll reference those adapter addresses in your `curveConfig.dexAdapters`.

### 4. (Optional) Upgrade Implementation

If you need to upgrade your `AgentBondingManager` or `AgentToken` logic, use your ProxyAdmin (or direct `ERC1967Proxy` calls):

```bash
npx hardhat run scripts/upgradeManager.js --network mainnet
```

## Security Model

1. **Access Control**
   - `DEFAULT_ADMIN_ROLE` can assign/revoke roles
   - `PAUSER_ROLE` can pause trading
   - `TAX_MANAGER_ROLE` can update tax/fee configurations

2. **Bonding Curve Integrity**
   - Strict checks on reserves to prevent underflow
   - Graduation triggers automatic liquidity locking

3. **Emergency Systems**
   - Full pausing of buy/sell operations
   - `rescueTokens()` for non-critical tokens (never base asset or active curve tokens)
   - Configurable tax vault and graduation settings

## Support

- Website: [chirper.build](https://chirper.build)
- Documentation: [docs.chirper.build](https://docs.chirper.build)
- Discord: [Join Chirper Community](https://discord.gg/QVFejuDNmH)
- Twitter: [@chirperai](https://twitter.com/chirperai)

## Security

For any security concerns, please email **stephan@chirper.ai**. 

## Audits

- **Hashlock (Date: TBD)**

## Acknowledgments

- **OpenZeppelin Contracts** for AccessControl, Upgradeable proxies, etc.
- **Uniswap V2** and **Velodrome** for DEX mechanics
- **Ethereum Foundation** for supporting open-source development
- **Chirper Community** for testing and feedback

## License

MIT License. See [LICENSE](./LICENSE) for details.