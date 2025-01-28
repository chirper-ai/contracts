/**
 * @file setup.ts
 * @description Test setup and utilities for AI Agent protocol testing
 */

import { ethers, upgrades } from "hardhat";
import { Contract } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

// Uniswap V2 Dependencies
import WETH9 from "@uniswap/v2-periphery/build/WETH9.json";
import UniswapV2Factory from "@uniswap/v2-core/build/UniswapV2Factory.json";
import UniswapV2Router02 from "@uniswap/v2-periphery/build/UniswapV2Router02.json";

// Uniswap V3 Dependencies
import NFTPositionManager from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
import UniswapV3Factory from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
import SwapRouter from "@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json";

/**
 * @enum DexType
 * @description Matches the DexType enum in the Manager contract
 */
export enum DexType {
  UniswapV2,
  UniswapV3,
  Velodrome,
}

/**
 * @interface TestContext
 * @description Testing context containing all necessary contracts and signers
 */
export interface TestContext {
  // Signers
  owner: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;

  // Core Protocol Contracts
  factory: Contract;
  router: Contract;
  manager: Contract;

  // Token Contracts
  assetToken: Contract;
  weth: Contract;
  tokenFactory: Contract;

  // DEX Contracts
  uniswapV2Router: Contract;
  uniswapV2Factory: Contract;
  uniswapV3Router: Contract;
  uniswapV3Factory: Contract;
  nftPositionManager: Contract;
  velodromeRouter: Contract;
  velodromeFactory: Contract;
}

/**
 * @function createToken
 * @description Creates a new agent token with specified DEX configurations
 */
export async function createToken(
  context: TestContext,
  creator: HardhatEthersSigner,
  dexConfigs?: Array<{
    router: string;
    fee: number;
    weight: number;
    dexType: DexType;
  }>,
  airdropParams?: {
    merkleRoot: string;
    claimantCount: number;
    percentage: number;
  }
): Promise<Contract> {
  const { factory, assetToken, uniswapV2Router } = context;

  // Default to Uniswap V2 if no config provided
  const defaultDexConfig = [
    {
      router: await uniswapV2Router.getAddress(),
      fee: 3000,
      weight: 100_000, // 100%
      dexType: DexType.UniswapV2,
    },
  ];

  // Default empty airdrop params if none provided
  const defaultAirdropParams = {
    merkleRoot: ethers.ZeroHash,
    claimantCount: 0,
    percentage: 0,
  };

  // Launch token through factory
  await assetToken
    .connect(creator)
    .approve(await factory.getAddress(), ethers.parseEther("10"));

  const tx = await factory.connect(creator).launch(
    "Test Agent",
    "TEST",
    "https://test.com",
    "Test intention",
    ethers.parseEther("10"), // initial purchase
    dexConfigs || defaultDexConfig,
    airdropParams || defaultAirdropParams
  );

  const receipt = await tx.wait();
  const event = receipt.logs.find((log) => log.fragment?.name === "Launch");
  if (!event?.args?.token) {
    throw new Error("Launch event not found or missing token address");
  }

  // Return token contract instance
  const Token = await ethers.getContractFactory("Token");
  return Token.attach(event.args.token);
}

/**
 * @function deployFixture
 * @description Deploys all contracts and sets up the testing environment
 */
export async function deployFixture(): Promise<TestContext> {
  const [owner, alice, bob] = await ethers.getSigners();

  // Deploy WETH
  const WETHFactory = await ethers.getContractFactory(
    WETH9.abi,
    WETH9.bytecode
  );
  const weth = await WETHFactory.deploy();

  // === Deploy DEX Infrastructure ===

  // Uniswap V2
  const UniswapV2FactoryFactory = await ethers.getContractFactory(
    UniswapV2Factory.abi,
    UniswapV2Factory.bytecode
  );
  const uniswapV2Factory = await UniswapV2FactoryFactory.deploy(
    await owner.getAddress()
  );

  const UniswapV2RouterFactory = await ethers.getContractFactory(
    UniswapV2Router02.abi,
    UniswapV2Router02.bytecode
  );
  const uniswapV2Router = await UniswapV2RouterFactory.deploy(
    await uniswapV2Factory.getAddress(),
    await weth.getAddress()
  );

  // Uniswap V3
  const UniswapV3FactoryFactory = await ethers.getContractFactory(
    UniswapV3Factory.abi,
    UniswapV3Factory.bytecode
  );
  const uniswapV3Factory = await UniswapV3FactoryFactory.deploy();

  const NFTPositionManagerFactory = await ethers.getContractFactory(
    NFTPositionManager.abi,
    NFTPositionManager.bytecode
  );
  const nftPositionManager = await NFTPositionManagerFactory.deploy(
    await uniswapV3Factory.getAddress(),
    await weth.getAddress(),
    await uniswapV3Factory.getAddress()
  );

  const SwapRouterFactory = await ethers.getContractFactory(
    SwapRouter.abi,
    SwapRouter.bytecode
  );
  const uniswapV3Router = await SwapRouterFactory.deploy(
    await uniswapV3Factory.getAddress(),
    await weth.getAddress()
  );

  // === Deploy Asset Token ===
  // Deploy Asset Token (VANA)
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const assetToken = await MockERC20.deploy(
    "VANA Token",
    "VANA",
    ethers.parseEther(`${10_000_000_000}`) // 10B supply with 18 decimals
  );

  // Fund test accounts with 100M VANA each
  const testBalance = ethers.parseEther(`${100_000_000}`); // Changed to use parseEther for 18 decimals
  await assetToken.transfer(await alice.getAddress(), testBalance);
  await assetToken.transfer(await bob.getAddress(), testBalance);

  // === Deploy Protocol Core ===
  // Factory First
  const Factory = await ethers.getContractFactory("Factory");
  const factory = await upgrades.deployProxy(Factory, [
    ethers.parseEther(`${5_000}`), // initial reserve agent
    5, // impact multiplier
  ]);

  // Then Router
  const Router = await ethers.getContractFactory("Router");
  const router = await upgrades.deployProxy(Router, [
    await factory.getAddress(),
    await assetToken.getAddress(),
    1_000, // maximum hold percentage
  ]);

  // Then Manager
  const Manager = await ethers.getContractFactory("Manager");
  const manager = await upgrades.deployProxy(Manager, [
    await factory.getAddress(),
    await assetToken.getAddress(),
    50_000 // 50% graduation threshold
  ]);

  // Token Factory
  const TokenFactory = await ethers.getContractFactory("TokenFactory");
  const tokenFactory = await upgrades.deployProxy(TokenFactory, [
    await factory.getAddress(),
    await manager.getAddress(),
    ethers.parseEther(`${1_000_000_000}`), // 1B initial supply
  ]);


  // Set manager and router in factory
  await factory.connect(owner).setRouter(await router.getAddress());
  await factory.connect(owner).setManager(await manager.getAddress());
  await factory.connect(owner).setTokenFactory(await tokenFactory.getAddress());

  return {
    owner,
    alice,
    bob,
    factory,
    router,
    manager,
    assetToken,
    weth,
    tokenFactory,
    uniswapV2Router,
    uniswapV2Factory,
    uniswapV3Router,
    uniswapV3Factory,
    nftPositionManager,
    velodromeRouter: uniswapV2Router,
    velodromeFactory: uniswapV2Factory,
  };
}

// Export testing utilities
export { expect, loadFixture };
