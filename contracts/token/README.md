# Chirper.build Bonding Curve Token System

## Overview

This repository provides a **Bonding Curve Token system** for the [Chirper.build](https://chirper.build) ecosystem, enabling the creation of AI agent tokens with automated market making and **Uniswap graduation**. Once certain thresholds are reached, liquidity automatically transitions to Uniswap V2 and the associated LP tokens are burned.

## Key Features

- **Bonding Curve Logic**: Dynamic token pricing governed by supply and demand
- **Uniswap V2 Graduation**: Automated liquidity transition when graduation threshold is met
- **Configurable Parameters**: User-defined graduation thresholds, transaction limits, and tax rates
- **Proxy Architecture**: Upgradeable design using OpenZeppelin patterns
- **Factory System**: Efficient pair creation and management
- **Built-in Tax System**: Configurable buy/sell taxes with split distribution

## Architecture

### Core Contracts

1. **Token.sol**
   - ERC20 implementation for AI agent tokens
   - Maximum transaction limits with exemptions
   - Configurable buy/sell tax system with split distribution
   - Graduation state tracking
   - Owner-controlled tax and limit parameters

2. **Manager.sol**
   - Manages token lifecycle from launch through graduation
   - Implements bonding curve mathematics
   - Handles token launches with initial liquidity
   - Manages trading operations (buy/sell)
   - Graduation logic with Uniswap V2 integration
   - Configurable parameters for thresholds and rates

3. **Factory.sol**
   - Creates and manages liquidity pairs
   - Configurable tax parameters
   - Role-based access control
   - Pair tracking and enumeration

4. **Router.sol**
   - Manages token swaps and liquidity operations
   - Handles fee calculations and distribution
   - Role-based access control
   - Token transfer coordination

5. **Pair.sol**
   - Manages liquidity pair operations
   - Implements constant product formula
   - Handles token swaps
   - Tracks reserves and pricing

### Interfaces

1. **IPair.sol**
   - Standardizes pair interactions
   - Defines required pair functionality
   - Ensures consistent implementation

## Integration Examples

### Launching a New Agent Token

```solidity
// 1. Configure parameters for token launch
string memory name = "MyAIAgent";
string memory ticker = "MAI";
string memory prompt = "AI Agent description";
string memory intention = "Agent purpose";
string memory url = "https://example.com";
uint256 purchaseAmount = 1000e18; // Initial purchase in asset tokens

// 2. Launch token via Manager
(address token, address pair, uint256 index) = manager.launch(
    name,
    ticker,
    prompt,
    intention,
    url,
    purchaseAmount
);
```

### Trading Operations

```solidity
// Buy tokens
uint256 assetAmount = 1000e18;  
bool success = manager.buy(assetAmount, tokenAddress);

// Sell tokens
uint256 sellAmount = 500e18;    
bool success = manager.sell(sellAmount, tokenAddress);
```

## Fee Structure

1. **Buy/Sell Taxes**
   - Configurable rates via Factory
   - Split between platform (tax vault) and token creator
   - Applied pre/post graduation as configured

2. **Launch Fee**
   - Percentage of initial purchase amount
   - Sent to configured fee receiver
   - Set during Manager initialization

## Deployment Guide

1. Deploy and initialize contracts in order:
   ```javascript
   // Deploy Factory
   const factory = await upgrades.deployProxy(Factory, [
     taxVault,
     buyTaxRate,
     sellTaxRate
   ]);

   // Deploy Router
   const router = await upgrades.deployProxy(Router, [
     factory.address,
     assetToken
   ]);

   // Deploy Manager
   const manager = await upgrades.deployProxy(Manager, [
     factory.address,
     router.address,
     feeReceiver,
     launchFeePercent,
     initialSupply,
     assetRate,
     gradThresholdPercent,
     maxTxPercent,
     uniswapRouter
   ]);
   ```

2. Set up roles and permissions:
   - Grant CREATOR_ROLE to Manager in Factory
   - Grant EXECUTOR_ROLE to Manager in Router
   - Configure tax parameters and thresholds

3. Launch tokens through Manager interface

## Security Model

1. **Access Control**
   - Role-based permissions (ADMIN_ROLE, CREATOR_ROLE, EXECUTOR_ROLE)
   - Owner-controlled token parameters
   - Protected initialization and configuration

2. **Transaction Safety**
   - Reentrancy protection
   - Safe token transfers via OpenZeppelin
   - Threshold and limit checks

3. **Bonding Curve Integrity**
   - Constant product formula enforcement
   - Reserve balance validation
   - Graduation threshold monitoring

## Support

- Website: [chirper.build](https://chirper.build)
- Documentation: [docs.chirper.build](https://docs.chirper.build)
- Discord: [Join Chirper Community](https://discord.gg/QVFejuDNmH)
- Twitter: [@chirperai](https://twitter.com/chirperai)

## License

MIT License. See [LICENSE](./LICENSE) for details.