const { ethers, upgrades, network, run } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Network:", network.name);
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

  // Initial parameters
  const TAX_VAULT = deployer.address; // Set your tax vault address
  const INITIAL_BUY_TAX = 1_000; // 1% in basis points
  const INITIAL_SELL_TAX = 1_000; // 1% in basis points
  const INITIAL_LAUNCH_TAX = 25_000; // 25% in basis points
  const INITIAL_SUPPLY = 1_000_000; // 1M tokens
  const K_CONSTANT = 3_420_000_000; // K constant for bonding curve
  const ASSET_RATE = 60_000; // Rate for asset requirements
  const GRAD_THRESHOLD_PERCENT = 50_000; // 50% threshold for graduation
  const MAX_TX_PERCENT = 10_000; // 10% max transaction size (no limit)

  // Use VANA (native token) and DEX addresses on moksha testnet
  const UNISWAP_ROUTER_ADDRESS = "0x2e7bfff8185C5a32991D2b0d68d4d2EFAaAA8F7B"; // TODO: Replace with actual DEX router on moksha
  const ASSET_TOKEN_ADDRESS = ethers.ZeroAddress; // Using ZeroAddress to represent native token (VANA)

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
    ASSET_TOKEN_ADDRESS,
    MAX_TX_PERCENT  // Using zero address for native token
  ]);
  await router.waitForDeployment();
  console.log("Router deployed to:", await router.getAddress());

  console.log("Deploying Manager...");
  const Manager = await ethers.getContractFactory("Manager");
  const manager = await upgrades.deployProxy(Manager, [
    await factory.getAddress(),
    await router.getAddress(),
    INITIAL_SUPPLY,
    K_CONSTANT,
    ASSET_RATE,
    GRAD_THRESHOLD_PERCENT
  ]);
  await manager.waitForDeployment();
  console.log("Manager deployed to:", await manager.getAddress());

  // Set up roles and permissions
  console.log("Setting up roles and permissions...");

  // Factory setup
  const CREATOR_ROLE = await factory.CREATOR_ROLE();
  const ADMIN_ROLE = await factory.ADMIN_ROLE();

  // Check if deployer has admin role
  if (!await factory.hasRole(ADMIN_ROLE, deployer.address)) {
      console.log("Deployer missing ADMIN_ROLE, something is wrong");
      return;
  }

  // Set router first using deployer's admin privileges
  const currentRouter = await factory.router();
  if (currentRouter !== await router.getAddress()) {
      await factory.connect(deployer).setRouter(await router.getAddress());
      console.log("Set router address in factory");
  }

  // Then grant roles to manager
  if (!await factory.hasRole(ADMIN_ROLE, await manager.getAddress())) {
      await factory.grantRole(ADMIN_ROLE, await manager.getAddress());
      console.log("Granted ADMIN_ROLE to manager");
  }

  if (!await factory.hasRole(CREATOR_ROLE, await manager.getAddress())) {
      await factory.grantRole(CREATOR_ROLE, await manager.getAddress());
      console.log("Granted CREATOR_ROLE to manager");
  }

  // Router setup - check before granting
  const EXECUTOR_ROLE = await router.EXECUTOR_ROLE();
  if (!await router.hasRole(EXECUTOR_ROLE, await manager.getAddress())) {
      await router.grantRole(EXECUTOR_ROLE, await manager.getAddress());
      console.log("Granted EXECUTOR_ROLE to manager");
  }

  console.log("Deployment completed!");
  console.log({
    factory: await factory.getAddress(),
    router: await router.getAddress(),
    manager: await manager.getAddress(),
  });

  // Verify contracts on VANAScan
  if (network.name === "moksha") {
    console.log("Verifying contracts on VANAScan...");
    try {
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
    } catch (error) {
      console.log("Verification error:", error);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });