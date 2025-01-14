// test/setup.ts
import { ethers, upgrades } from "hardhat";
import { Contract } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

import IUniswapV2Factory from '@uniswap/v2-core/build/IUniswapV2Factory.json';
import IUniswapV2Router02 from '@uniswap/v2-periphery/build/IUniswapV2Router02.json';
import WETH9 from '@uniswap/v2-periphery/build/WETH9.json';
import UniswapV2Factory from '@uniswap/v2-core/build/UniswapV2Factory.json';
import UniswapV2Router02 from '@uniswap/v2-periphery/build/UniswapV2Router02.json';

export interface TestContext {
  owner: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
  factory: Contract;
  router: Contract;
  manager: Contract;
  assetToken: Contract;
  uniswapRouter: Contract;
  uniswapFactory: Contract;
  weth: Contract;
}

export async function createToken(
  context: TestContext,
  creator: HardhatEthersSigner
): Promise<Contract> {
  const { manager, assetToken } = context;
  
  const purchaseAmount = ethers.parseEther("1000");
  await assetToken.connect(creator).approve(await manager.getAddress(), purchaseAmount);
  
  const tx = await manager.connect(creator).launch(
    "Test Agent",
    "TEST",
    "Test prompt",
    "Test intention",
    "https://test.com",
    purchaseAmount
  );
  
  const receipt = await tx.wait();
  const event = receipt.logs.find(log => log.fragment?.name === "Launched");
  if (!event?.args?.token) {
    throw new Error("Launch event not found or missing token address");
  }
  
  const Token = await ethers.getContractFactory("Token");
  return Token.attach(event.args.token);
}

export async function deployFixture(): Promise<TestContext> {
  // Get signers
  const [owner, alice, bob] = await ethers.getSigners();
  
  // Deploy WETH
  const WETHFactory = await ethers.getContractFactory(WETH9.abi, WETH9.bytecode);
  const weth = await WETHFactory.deploy();
  await weth.waitForDeployment();

  // Deploy Uniswap Factory
  const UniswapFactoryFactory = await ethers.getContractFactory(UniswapV2Factory.abi, UniswapV2Factory.bytecode);
  const uniswapFactory = await UniswapFactoryFactory.deploy(await owner.getAddress());
  await uniswapFactory.waitForDeployment();

  // Deploy Uniswap Router
  const UniswapRouterFactory = await ethers.getContractFactory(UniswapV2Router02.abi, UniswapV2Router02.bytecode);
  const uniswapRouter = await UniswapRouterFactory.deploy(
    await uniswapFactory.getAddress(),
    await weth.getAddress()
  );
  await uniswapRouter.waitForDeployment();
  
  // Deploy Asset Token (standard ERC20 mock USDC)
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const assetToken = await MockERC20.deploy(
    "USD Coin",
    "USDC",
    ethers.parseEther("100000000") // 100M initial supply
  );
  await assetToken.waitForDeployment();

  // Transfer some initial tokens to test accounts
  const initialBalance = ethers.parseEther("50000000"); // 50M USDC each
  await assetToken.transfer(await alice.getAddress(), initialBalance);
  await assetToken.transfer(await bob.getAddress(), initialBalance);

  // Deploy Factory with proper initialization
  const Factory = await ethers.getContractFactory("Factory");
  const factory = await upgrades.deployProxy(Factory, [
    await owner.getAddress(),  // tax vault
    200,                       // 2% buy tax
    300,                       // 3% sell tax
    500                        // 5% launch tax
  ]);
  await factory.waitForDeployment();

  // Deploy Router with proper addresses
  const Router = await ethers.getContractFactory("Router");
  const router = await upgrades.deployProxy(Router, [
    await factory.getAddress(),
    await assetToken.getAddress()
  ]);
  await router.waitForDeployment();

  // Setup roles for factory
  const ADMIN_ROLE = await factory.ADMIN_ROLE();
  const CREATOR_ROLE = await factory.CREATOR_ROLE();
  
  if (!await factory.hasRole(ADMIN_ROLE, await owner.getAddress())) {
    await factory.grantRole(ADMIN_ROLE, await owner.getAddress());
  }

  await factory.setRouter(await router.getAddress());

  // Deploy Manager with proper initialization
  const Manager = await ethers.getContractFactory("Manager");
  const manager = await upgrades.deployProxy(Manager, [
    await factory.getAddress(),
    await router.getAddress(),
    1_000_000,              // initial supply
    10_000,                 // asset rate
    50,                     // graduation threshold percent
    100,                    // 100% max transaction (no limit)
    await uniswapRouter.getAddress()
  ]);
  await manager.waitForDeployment();

  // Setup remaining roles
  await factory.grantRole(CREATOR_ROLE, await manager.getAddress());
  
  // Setup roles for router
  const EXECUTOR_ROLE = await router.EXECUTOR_ROLE();
  await router.grantRole(EXECUTOR_ROLE, await manager.getAddress());

  return {
    owner,
    alice,
    bob,
    factory,
    router,
    manager,
    assetToken,
    uniswapRouter,
    uniswapFactory,
    weth
  };
}

export { expect, loadFixture };