# Chirper.build Bonding Curve Token System

## Overview

The Bonding Curve Token system is a component of [Chirper.build](https://chirper.build), enabling the creation of tokens with automated market making and multi-DEX graduation capabilities. This system allows smooth token launches with initial bonding curve dynamics that automatically transition to decentralized exchanges once specific thresholds are met.

## Key Features

- **Bonding Curve Logic**: Dynamic pricing based on supply and demand
- **Multi-DEX Graduation**: Automatic transition to Uniswap V2 and Velodrome
- **Configurable Parameters**: Customizable graduation thresholds and DEX weights
- **Proxy Architecture**: Upgradeable design using OpenZeppelin patterns
- **Factory System**: Streamlined deployment and configuration
- **Emergency Controls**: Protected pause and withdrawal mechanisms

## About Chirper.build

Chirper.build is part of the [Chirper.ai](https://chirper.ai) ecosystem, focusing on innovative DeFi implementations. The Bonding Curve system enables:
- Fair token distribution mechanisms
- Automated market making
- Smooth DEX transitions
- Multi-venue liquidity provision

## Architecture

### Core Contracts

1. **GraduatedToken.sol**
   - ERC20 implementation
   - Graduation state management
   - Bonding curve integration points

2. **BondingManager.sol**
   - Bonding curve mathematics
   - Trade execution
   - DEX graduation logic
   - Multi-venue liquidity management

3. **BondingFactory.sol**
   - Deployment coordination
   - Instance tracking
   - Configuration management

### Adapters

1. **UniswapAdapter.sol**
   - Uniswap V2 integration
   - Liquidity provision
   - Pair management

2. **VelodromeAdapter.sol**
   - Velodrome integration
   - Stable/volatile pool support
   - Advanced liquidity features

### Interfaces

1. **IDEXAdapter.sol**
   - Standard DEX integration interface
   - Liquidity operation definitions
   - Common DEX interactions

## Integration Examples

### Creating a New Token

```solidity
// Configure and create a new bonding curve token
BondingManager.CurveConfig memory config = BondingManager.CurveConfig({
    initialPrice: 1e18,         // 1 BASE_ASSET per token
    gradThreshold: 100000e18,   // Graduate at 100k BASE_ASSET
    dexAdapters: [uniswap, velodrome],
    dexWeights: [50, 50]        // Equal split between DEXes
});

(address manager, address token) = factory.createBondingCurve(
    "MyToken",
    "MTK",
    config
);
```

### Trading on Bonding Curve

```solidity
// Buy tokens from the bonding curve
uint256 assetAmount = 1000e18;  // 1000 BASE_ASSET
uint256 tokenAmount = bondingManager.buy(token, assetAmount);

// Sell tokens back to the curve
uint256 sellAmount = 500e18;    // 500 tokens
uint256 assetReturn = bondingManager.sell(token, sellAmount);
```

## Fee Structure

1. **Trading Fees**
   - Configurable per token instance
   - Supports fee splitting between platform and creators

2. **Graduation Fees**
   - DEX listing fees when applicable
   - LP token distribution settings

## Deployment

1. Deploy implementation contracts:
   ```bash
   npx hardhat deploy --network mainnet --tags implementations
   ```

2. Deploy factory:
   ```bash
   npx hardhat deploy --network mainnet --tags factory
   ```

3. Configure DEX adapters:
   ```bash
   npx hardhat deploy --network mainnet --tags adapters
   ```

## Security Model

1. **Access Control**
   - Owner-managed configuration
   - Protected graduation process
   - Pausable operations

2. **Price Protection**
   - Slippage checks on DEX transitions
   - Maximum trade size limits
   - Oracle integration points

3. **Emergency Systems**
   - Pause functionality
   - Protected withdrawals
   - Curve parameter adjustments

## Support

- Website: [chirper.build](https://chirper.build)
- Documentation: [docs.chirper.build](https://docs.chirper.build)
- Discord: [Join Chirper Community](https://discord.gg/QVFejuDNmH)
- Twitter: [@chirperai](https://twitter.com/chirperai)

## Security

For security concerns, please email security@chirper.build

## Audits

- Hashlock (Date: TBD)

## Acknowledgments

- OpenZeppelin Contracts
- Uniswap V2
- Velodrome
- Ethereum Foundation
- Chirper Community

## License

MIT License. See [LICENSE](./LICENSE) for details.