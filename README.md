# AgentSkill Smart Contract System

## Overview

AgentSkill is a sophisticated smart contract system that enables AI agents to interact with the blockchain through NFT-bound accounts. Each NFT represents a specific AI capability or "skill" that can be used to perform inferences and execute blockchain transactions.

## Key Features

- **Token-Bound Accounts**: Each NFT has its own autonomous account (based on ERC-6551)
- **Dual Control**: Both AI agents and NFT owners can control the bound accounts
- **Inference System**: Pay-per-use system for AI capabilities
- **Fee Distribution**: Automated fee splitting between creators and platform
- **Emergency Systems**: Protected withdrawal mechanisms for asset safety
- **Upgradeable Design**: Future-proof architecture using OpenZeppelin's upgrade patterns

## Architecture

### Core Components

1. **AgentSkillCore (`contracts/core/AgentSkillCore.sol`)**
   - Main NFT implementation
   - Handles minting, burning, and inference requests
   - Manages fee distribution and emergency procedures
   - Upgradeable using UUPS pattern

2. **AgentSkillAccount (`contracts/account/AgentSkillAccount.sol`)**
   - Token-bound account implementation
   - Handles transaction execution
   - Implements signature validation
   - Provides security controls

3. **ERC6551Registry (`contracts/registry/ERC6551Registry.sol`)**
   - Manages creation of token-bound accounts
   - Ensures deterministic account addresses
   - Provides account lookup functionality

4. **AgentSkillFactory (`contracts/factory/AgentSkillFactory.sol`)**
   - One-click deployment of entire system
   - Handles initialization and configuration
   - Sets up proper permissions

### Libraries

1. **ErrorLibrary (`contracts/libraries/ErrorLibrary.sol`)**
   - Centralized error handling
   - Custom error definitions
   - Validation helpers

2. **Constants (`contracts/libraries/Constants.sol`)**
   - System-wide constants
   - Fee configurations
   - Role definitions

3. **SafeCall (`contracts/libraries/SafeCall.sol`)**
   - Secure external call handling
   - ETH transfer safety
   - Contract interaction utilities

### Interfaces

1. **IAgentSkill (`contracts/interfaces/IAgentSkill.sol`)**
   - Core protocol interface
   - Event definitions
   - External function specifications

2. **IERC6551Account (`contracts/interfaces/IERC6551Account.sol`)**
   - Token-bound account standard
   - Account capabilities definition

3. **Additional Interfaces**
   - IERC6551Registry
   - IERC1271 (signature validation)
   - IAgentSkillEvents
   - IAgentSkillErrors

## Security Features

### Access Control
- Role-based access control (RBAC)
- Platform signer validation
- Dual signature requirements for critical operations

### Asset Protection
- Reentrancy guards
- Emergency withdrawal system
- Timelock on upgrades
- Signature replay protection

### Validation
- Comprehensive parameter validation
- Chain ID verification
- Nonce tracking
- Deadline enforcement

## Fee Structure

1. **Inference Fees**
   - Platform: 70%
   - Creator: 30%
   - Customizable per skill

2. **Trade Royalties**
   - Platform: 1%
   - Creator: 1%
   - Applied to secondary sales

3. **Execution Fees**
   - 1% fee on token transfers through bound accounts
   - Collected by platform

## Integration Guide

### Deployment

```solidity
// 1. Deploy using factory
AgentSkillFactory.DeploymentConfig memory config = AgentSkillFactory.DeploymentConfig({
    name: "My AI Skills",
    symbol: "AISKILL",
    platform: platformAddress,
    admin: adminAddress,
    initData: ""
});

AgentSkillFactory.DeployedSystem memory deployment = factory.deploySystem(config);

// 2. Access deployed contracts
IAgentSkill agentSkill = IAgentSkill(deployment.agentSkill);
IERC6551Registry registry = IERC6551Registry(deployment.registry);
```

### Minting Skills

```solidity
// Create a new skill
IAgentSkill.MintConfig memory mintConfig = IAgentSkill.MintConfig({
    to: recipient,
    agent: aiAgentAddress,
    mintPrice: 0.1 ether,
    inferencePrice: 0.01 ether,
    data: "",
    deadline: block.timestamp + 1 hours,
    platformSignature: signature
});

(uint256 tokenId, address account) = agentSkill.mint{value: 0.1 ether}(mintConfig);
```

### Requesting Inferences

```solidity
// Request an inference
IAgentSkill.InferenceRequest[] memory requests = new IAgentSkill.InferenceRequest[](1);
requests[0] = IAgentSkill.InferenceRequest({
    tokenId: tokenId,
    data: inferenceData,
    maxFee: 0.01 ether,
    deadline: block.timestamp + 1 hours
});

uint256[] memory requestIds = agentSkill.requestInference{value: 0.01 ether}(requests);
```

## Testing

The system includes comprehensive tests for all components:

```bash
# Install dependencies
npm install

# Run tests
npx hardhat test

# Run coverage
npx hardhat coverage

# Run gas report
REPORT_GAS=true npx hardhat test
```

## Upgrading

The system supports upgrades through OpenZeppelin's UUPS pattern:

1. Deploy new implementation
2. Call `upgradeTo()` with timelock delay
3. Verify storage layout compatibility
4. Update documentation and ABIs

## License

MIT License. See [LICENSE](./LICENSE) for details.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines.

## Security

For security concerns, please email security@yourproject.com

## Audits

- Trail of Bits (Date: TBD)
- OpenZeppelin (Date: TBD)
- Consensys Diligence (Date: TBD)

## Support

- Documentation: [docs.yourproject.com](https://docs.yourproject.com)
- Discord: [discord.gg/yourproject](https://discord.gg/yourproject)
- Twitter: [@yourproject](https://twitter.com/yourproject)

## Acknowledgments

- OpenZeppelin Contracts
- ERC-6551 Standard Authors
- Ethereum Foundation