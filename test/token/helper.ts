/**
 * @file setup.ts
 * @description Test setup and utilities for DeFi protocol testing with Uniswap V2 and V3 integration
 * 
 * This file provides the core testing infrastructure for the protocol, including:
 * - Deployment of all necessary contracts (Protocol contracts, Uniswap V2/V3, WETH, Mock tokens)
 * - Test context management
 * - Token creation utilities
 * - Common test fixtures
 * 
 * The setup supports both Uniswap V2 and V3 protocols, allowing for comprehensive testing
 * of different DEX integration scenarios.
 */

import { ethers, upgrades } from "hardhat";
import { Contract } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

// Uniswap V2 Dependencies
import WETH9 from '@uniswap/v2-periphery/build/WETH9.json';
import UniswapV2Factory from '@uniswap/v2-core/build/UniswapV2Factory.json';
import UniswapV2Router02 from '@uniswap/v2-periphery/build/UniswapV2Router02.json';

// Uniswap V3 Dependencies
import NFTPositionManager from '@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json';
import UniswapV3Factory from '@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json';
import SwapRouter from '@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json';

/**
 * @enum RouterType
 * @description Identifies the type of DEX router being used
 * Used to differentiate between Uniswap V2 and V3 integrations
 */
export enum RouterType {
  UniswapV2,  // Standard Uniswap V2 router
  UniswapV3   // Advanced Uniswap V3 router with concentrated liquidity
}

/**
 * @interface TestContext
 * @description Comprehensive testing context containing all necessary contracts and signers
 * This interface represents the complete state needed for running protocol tests
 */
export interface TestContext {
  // Signers
  owner: HardhatEthersSigner;      // Protocol owner/admin
  alice: HardhatEthersSigner;      // Test user 1
  bob: HardhatEthersSigner;        // Test user 2
  
  // Protocol Contracts
  factory: Contract;               // Main protocol factory
  router: Contract;                // Protocol router for managing trades
  manager: Contract;               // Protocol manager for token creation/management
  
  // Asset Tokens
  assetToken: Contract;            // Mock USDC for testing
  weth: Contract;                  // Wrapped ETH contract
  
  // Uniswap V2 Contracts
  uniswapV2Router: Contract;       // Uniswap V2 Router contract
  uniswapV2Factory: Contract;      // Uniswap V2 Factory contract
  
  // Uniswap V3 Contracts
  uniswapV3Router: Contract;       // Uniswap V3 Router contract
  uniswapV3Factory: Contract;      // Uniswap V3 Factory contract
  nftPositionManager: Contract;    // V3 NFT Position Manager for LP positions
}

/**
 * @function createToken
 * @description Creates a new token through the protocol manager with specified DEX router configuration
 * 
 * @param context - The test context containing all necessary contracts
 * @param creator - The signer that will create the token
 * @param dexRouters - Optional array of DEX router configurations
 * @returns Promise<Contract> - The newly created token contract
 * 
 * @example
 * // Create token with V3 router
 * const token = await createToken(context, alice, [{
 *   routerAddress: await context.uniswapV3Router.getAddress(),
 *   weight: 100_000,
 *   routerType: RouterType.UniswapV3
 * }]);
 */
export async function createToken(
  context: TestContext,
  creator: HardhatEthersSigner,
  dexRouters?: Array<{ 
    routerAddress: string,     // Address of the DEX router
    weight: number,            // Weight for this router (basis points)
    feeAmount: number,         // Fee amount for Uniswap V3 routers
    routerType: RouterType     // Type of router (V2 or V3)
  }>
): Promise<Contract> {
  const { manager, assetToken, uniswapV2Router } = context;
  
  // Standard purchase amount for token creation
  const purchaseAmount = ethers.parseEther("30"); // $300 in VANA
  await assetToken.connect(creator).approve(await manager.getAddress(), purchaseAmount);
  
  // Default router configuration if none provided
  const defaultDexRouters = [{
    routerAddress: await uniswapV2Router.getAddress(),
    weight: 100_000,  // 100% in basis points
    feeAmount: 0,     // No fee for Uniswap V2
    routerType: RouterType.UniswapV2
  }];

  // Launch the token with specified parameters
  const tx = await manager.connect(creator).launch(
    "Test Agent",
    "TEST",
    "Test intention",
    "https://test.com",
    purchaseAmount,
    dexRouters || defaultDexRouters
  );
  
  // Wait for transaction and extract token address from event
  const receipt = await tx.wait();
  const event = receipt.logs.find(log => log.fragment?.name === "Launched");
  if (!event?.args?.token) {
    throw new Error("Launch event not found or missing token address");
  }
  
  // Return the token contract instance
  const Token = await ethers.getContractFactory("Token");
  return Token.attach(event.args.token);
}

/**
 * @function deployFixture
 * @description Main deployment fixture that sets up the entire testing environment
 * This function deploys all necessary contracts and sets up their initial state
 * 
 * Deployment sequence:
 * 1. Deploy WETH
 * 2. Deploy Uniswap V2 contracts
 * 3. Deploy Uniswap V3 contracts
 * 4. Deploy protocol contracts
 * 5. Setup roles and permissions
 * 6. Initialize test accounts
 * 
 * @returns Promise<TestContext> - Complete test context with all deployed contracts
 */
export async function deployFixture(): Promise<TestContext> {
  // Get signers for testing
  const [owner, alice, bob] = await ethers.getSigners();
  
  // Deploy WETH - Required by both Uniswap V2 and V3
  const WETHFactory = await ethers.getContractFactory(WETH9.abi, WETH9.bytecode);
  const weth = await WETHFactory.deploy();
  await weth.waitForDeployment();

  // === Uniswap V2 Deployment ===
  
  // Deploy Uniswap V2 Factory
  const UniswapV2FactoryFactory = await ethers.getContractFactory(UniswapV2Factory.abi, UniswapV2Factory.bytecode);
  const uniswapV2Factory = await UniswapV2FactoryFactory.deploy(await owner.getAddress());
  await uniswapV2Factory.waitForDeployment();

  // Deploy Uniswap V2 Router
  const UniswapV2RouterFactory = await ethers.getContractFactory(UniswapV2Router02.abi, UniswapV2Router02.bytecode);
  const uniswapV2Router = await UniswapV2RouterFactory.deploy(
    await uniswapV2Factory.getAddress(),
    await weth.getAddress()
  );
  await uniswapV2Router.waitForDeployment();

  // === Uniswap V3 Deployment ===
  
  // Deploy Uniswap V3 Factory
  const UniswapV3FactoryFactory = await ethers.getContractFactory(UniswapV3Factory.abi, UniswapV3Factory.bytecode);
  const uniswapV3Factory = await UniswapV3FactoryFactory.deploy();
  await uniswapV3Factory.waitForDeployment();

  // Enable fee tiers (100 = 0.01%, 500 = 0.05%, 3000 = 0.3%, 10000 = 1%)
  //await uniswapV3Factory.enableFeeAmount(100, 1);
  //await uniswapV3Factory.enableFeeAmount(500, 10);
  //await uniswapV3Factory.enableFeeAmount(3000, 60);
  //await uniswapV3Factory.enableFeeAmount(10000, 200);

  // Deploy NFT Position Manager for V3 liquidity positions
  const NFTPositionManagerFactory = await ethers.getContractFactory(NFTPositionManager.abi, NFTPositionManager.bytecode);
  const nftPositionManager = await NFTPositionManagerFactory.deploy(
    await uniswapV3Factory.getAddress(),
    await weth.getAddress(),
    await owner.getAddress() // Factory owner for token descriptor
  );
  await nftPositionManager.waitForDeployment();

  // Deploy Uniswap V3 Router
  const SwapRouterFactory = await ethers.getContractFactory(SwapRouter.abi, SwapRouter.bytecode);
  const uniswapV3Router = await SwapRouterFactory.deploy(
    await uniswapV3Factory.getAddress(),
    await weth.getAddress()
  );
  await uniswapV3Router.waitForDeployment();
  
  // === Protocol Token Deployment ===
  
  // Deploy Asset Token (Mock USDC)
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const assetToken = await MockERC20.deploy(
    "USD Coin",
    "USDC",
    ethers.parseEther("100000000") // 100M initial supply
  );
  await assetToken.waitForDeployment();

  // Initialize test accounts with tokens
  const initialBalance = ethers.parseEther("50000000"); // 50M USDC each
  await assetToken.transfer(await alice.getAddress(), initialBalance);
  await assetToken.transfer(await bob.getAddress(), initialBalance);

  // === Protocol Core Deployment ===
  
  // Deploy Factory with tax configuration
  const Factory = await ethers.getContractFactory("Factory");
  const factory = await upgrades.deployProxy(Factory, [
    await owner.getAddress(),  // tax vault
    2_000,                     // 2% buy tax
    3_000,                     // 3% sell tax
    5_000                      // 5% launch tax
  ]);
  await factory.waitForDeployment();

  // Deploy Router with transaction limits
  const Router = await ethers.getContractFactory("Router");
  const router = await upgrades.deployProxy(Router, [
    await factory.getAddress(),
    await assetToken.getAddress(),
    10_000, // 10% max transaction percent
  ]);
  await router.waitForDeployment();

  // === Role and Permission Setup ===
  
  // Setup factory roles
  const ADMIN_ROLE = await factory.ADMIN_ROLE();
  const CREATOR_ROLE = await factory.CREATOR_ROLE();
  
  if (!await factory.hasRole(ADMIN_ROLE, await owner.getAddress())) {
    await factory.grantRole(ADMIN_ROLE, await owner.getAddress());
  }

  await factory.setRouter(await router.getAddress());

  // Deploy Manager with protocol parameters
  const Manager = await ethers.getContractFactory("Manager");
  const manager = await upgrades.deployProxy(Manager, [
    await factory.getAddress(),
    await router.getAddress(),
    1_000_000,              // initial supply
    3_420_000_000,          // k constant
    60_000,                 // asset rate
    50_000,                 // graduation threshold percent
  ]);
  await manager.waitForDeployment();

  // Grant necessary roles
  await factory.grantRole(CREATOR_ROLE, await manager.getAddress());
  
  // Setup router roles
  const EXECUTOR_ROLE = await router.EXECUTOR_ROLE();
  await router.grantRole(EXECUTOR_ROLE, await manager.getAddress());

  // Return complete test context
  return {
    owner,
    alice,
    bob,
    factory,
    router,
    manager,
    assetToken,
    uniswapV2Router,
    uniswapV2Factory,
    uniswapV3Router,
    uniswapV3Factory,
    nftPositionManager,
    weth
  };
}

// Export testing utilities
export { expect, loadFixture };