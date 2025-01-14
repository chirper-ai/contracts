const { ethers, upgrades } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);

  // Initial parameters
  const TAX_VAULT = "0x..."; // Set your tax vault address
  const INITIAL_BUY_TAX = 500; // 5% in basis points
  const INITIAL_SELL_TAX = 500; // 5% in basis points
  const INITIAL_SUPPLY = ethers.parseEther("1000000"); // 1M tokens
  const MAX_TX_PERCENT = 1; // 1% max transaction size
  const ASSET_RATE = 3000; // Rate for asset requirements
  const GRAD_THRESHOLD_PERCENT = 20; // 20% threshold for graduation
  const UNISWAP_ROUTER = "0x..."; // Set your Uniswap V2 router address
  const PAIR_TOKEN_ADDRESS = "0x..."; // Set your USDC/stable token address

  console.log("Deploying Factory...");
  const Factory = await ethers.getContractFactory("Factory");
  const factory = await upgrades.deployProxy(Factory, [
    TAX_VAULT,
    INITIAL_BUY_TAX,
    INITIAL_SELL_TAX
  ]);
  await factory.waitForDeployment();
  console.log("Factory deployed to:", await factory.getAddress());

  console.log("Deploying Router...");
  const Router = await ethers.getContractFactory("Router");
  const router = await upgrades.deployProxy(Router, [
    await factory.getAddress(),
    PAIR_TOKEN_ADDRESS
  ]);
  await router.waitForDeployment();
  console.log("Router deployed to:", await router.getAddress());

  console.log("Deploying Manager...");
  const Manager = await ethers.getContractFactory("Manager");
  const manager = await upgrades.deployProxy(Manager, [
    await factory.getAddress(),
    await router.getAddress(),
    TAX_VAULT,
    INITIAL_SELL_TAX,
    INITIAL_SUPPLY,
    ASSET_RATE,
    GRAD_THRESHOLD_PERCENT,
    MAX_TX_PERCENT,
    UNISWAP_ROUTER
  ]);
  await manager.waitForDeployment();
  console.log("Manager deployed to:", await manager.getAddress());

  // Set up roles and permissions
  console.log("Setting up roles and permissions...");

  // Factory setup
  const CREATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("CREATOR_ROLE"));
  const ADMIN_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ADMIN_ROLE"));
  const EXECUTOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EXECUTOR_ROLE"));

  await factory.grantRole(CREATOR_ROLE, await manager.getAddress());
  await factory.grantRole(ADMIN_ROLE, deployer.address);
  await factory.setRouter(await router.getAddress());

  // Router setup
  await router.grantRole(EXECUTOR_ROLE, await manager.getAddress());
  await router.grantRole(ADMIN_ROLE, deployer.address);

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