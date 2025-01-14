const { ethers, upgrades, network, run } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // Initial parameters
  const TAX_VAULT = deployer.address; // Set your tax vault address
  const INITIAL_BUY_TAX = 200; // 2% in basis points
  const INITIAL_SELL_TAX = 300; // 3% in basis points
  const INITIAL_LAUNCH_TAX = 500; // 5% in basis points
  const INITIAL_SUPPLY = 1_000_000; // 1M tokens
  const ASSET_RATE = 10_000; // Rate for asset requirements
  const GRAD_THRESHOLD_PERCENT = 50; // 50% threshold for graduation
  const MAX_TX_PERCENT = 100; // 100% max transaction size (no limit)

  // Known addresses
  const UNISWAP_ROUTER_ADDRESS = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"; // Uniswap V2 Router
  const ASSET_TOKEN_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // USDC

  console.log("Deploying Factory...");
  const Factory = await ethers.getContractFactory("Factory");
  const factory = await upgrades.deployProxy(Factory, [
    TAX_VAULT,
    INITIAL_BUY_TAX,
    INITIAL_SELL_TAX,
    INITIAL_LAUNCH_TAX
  ]);
  await factory.waitForDeployment();
  console.log("Factory deployed to:", await factory.getAddress());

  console.log("Deploying Router...");
  const Router = await ethers.getContractFactory("Router");
  const router = await upgrades.deployProxy(Router, [
    await factory.getAddress(),
    ASSET_TOKEN_ADDRESS
  ]);
  await router.waitForDeployment();
  console.log("Router deployed to:", await router.getAddress());

  console.log("Deploying Manager...");
  const Manager = await ethers.getContractFactory("Manager");
  const manager = await upgrades.deployProxy(Manager, [
    await factory.getAddress(),
    await router.getAddress(),
    INITIAL_SUPPLY,
    ASSET_RATE,
    GRAD_THRESHOLD_PERCENT,
    MAX_TX_PERCENT,
    UNISWAP_ROUTER_ADDRESS
  ]);
  await manager.waitForDeployment();
  console.log("Manager deployed to:", await manager.getAddress());

  // Set up roles and permissions
  console.log("Setting up roles and permissions...");

  // Factory setup
  const CREATOR_ROLE = await factory.CREATOR_ROLE();
  const ADMIN_ROLE = await factory.ADMIN_ROLE();
  await factory.grantRole(CREATOR_ROLE, await manager.getAddress());
  await factory.setRouter(await router.getAddress());

  // Router setup
  const EXECUTOR_ROLE = await router.EXECUTOR_ROLE();
  await router.grantRole(EXECUTOR_ROLE, await manager.getAddress());

  console.log("Deployment completed!");
  console.log({
    factory: await factory.getAddress(),
    router: await router.getAddress(),
    manager: await manager.getAddress(),
  });

  // Verify contracts on Etherscan
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("Verifying contracts on Etherscan...");
    
    await run("verify:verify", {
      address: await factory.getAddress(),
      constructorArguments: []
    });

    await run("verify:verify", {
      address: await router.getAddress(),
      constructorArguments: []
    });

    await run("verify:verify", {
      address: await manager.getAddress(),
      constructorArguments: []
    });
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });