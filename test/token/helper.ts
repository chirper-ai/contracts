// test/setup.ts
import { expect } from "chai";
import { Contract } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { ethers } from "hardhat";

export interface TestContext {
  owner: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
  factory: Contract;
  router: Contract;
  manager: Contract;
  assetToken: Contract;
}

export async function deployFixture(): Promise<TestContext> {
  // Get signers
  const [owner, alice, bob] = await ethers.getSigners();
  
  // Deploy Asset Token (mock USDC) first
  const AssetToken = await ethers.getContractFactory("Token");
  const assetToken = await AssetToken.deploy(
    "USD Coin",
    "USDC",
    1_000_000,  // 1M initial supply
    100         // 100% max transaction (no limit)
  );
  await assetToken.waitForDeployment();

  // Deploy Factory with proper initialization
  const Factory = await ethers.getContractFactory("Factory");
  const factory = await upgrades.deployProxy(Factory, [
    await owner.getAddress(),  // tax vault
    200,  // 2% buy tax
    300   // 3% sell tax
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
  
  // Grant roles to owner if they don't already have them
  if (!await factory.hasRole(ADMIN_ROLE, await owner.getAddress())) {
    await factory.grantRole(ADMIN_ROLE, await owner.getAddress());
  }

  // Now we can set the router
  await factory.setRouter(await router.getAddress());

  // Deploy Manager
  const Manager = await ethers.getContractFactory("Manager");
  const manager = await upgrades.deployProxy(Manager, [
    await factory.getAddress(),
    await router.getAddress(),
    await owner.getAddress(),  // fee receiver
    500,  // 5% fee
    1_000_000,  // initial supply
    100,        // asset rate
    1000        // graduation threshold
  ]);
  await manager.waitForDeployment();

  // Setup remaining roles
  await factory.grantRole(CREATOR_ROLE, await router.getAddress());
  
  // Setup roles for router
  const EXECUTOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EXECUTOR_ROLE"));
  await router.grantRole(EXECUTOR_ROLE, await manager.getAddress());

  return {
    owner,
    alice,
    bob,
    factory,
    router,
    manager,
    assetToken
  };
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
  const event = receipt.events?.find(e => e.event === "Launched");
  if (!event || !event.args) {
    throw new Error("Launch event not found");
  }
  
  const tokenAddress = event.args.token;
  const TokenContract = await ethers.getContractFactory("Token");
  
  return TokenContract.attach(tokenAddress);
}

export { expect, loadFixture };