const { ethers, upgrades, network, run } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Network:", network.name);
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

  // Initial parameters
  const INITIAL_SUPPLY = ethers.parseEther("1000000000"); // 1B tokens
  const K_CONSTANT = 250; // K constant for bonding curve
  const MAX_HOLD_PERCENT = 1_000; // 1% maximum hold
  const GRADUATION_THRESHOLD = 20_000; // 20% threshold

  // Use VANA token address on moksha testnet
  const ASSET_TOKEN_ADDRESS = '0xbccc4b4c6530F82FE309c5E845E50b5E9C89f2AD'; // VANA Address

  console.log("Deploying Factory...");
  const Factory = await ethers.getContractFactory("Factory");
  const factory = await upgrades.deployProxy(Factory, [
    K_CONSTANT
  ]);
  await factory.waitForDeployment();
  console.log("Factory deployed to:", await factory.getAddress());

  console.log("Deploying Router...");
  const Router = await ethers.getContractFactory("Router");
  const router = await upgrades.deployProxy(Router, [
    await factory.getAddress(),
    ASSET_TOKEN_ADDRESS,
    MAX_HOLD_PERCENT
  ]);
  await router.waitForDeployment();
  console.log("Router deployed to:", await router.getAddress());

  console.log("Deploying Manager...");
  const Manager = await ethers.getContractFactory("Manager");
  const manager = await upgrades.deployProxy(Manager, [
    await factory.getAddress(),
    ASSET_TOKEN_ADDRESS,
    GRADUATION_THRESHOLD
  ]);
  await manager.waitForDeployment();
  console.log("Manager deployed to:", await manager.getAddress());

  // Token Factory
  console.log("Deploying Token Factory...");
  const TokenFactory = await ethers.getContractFactory("TokenFactory");
  const tokenFactory = await upgrades.deployProxy(TokenFactory, [
    await factory.getAddress(),
    await manager.getAddress(),
    INITIAL_SUPPLY, // 1B initial supply
  ]);

  // Set up contract relationships
  console.log("Setting up contract relationships...");
  
  await factory.setRouter(await router.getAddress());
  console.log("Router set in Factory");
  
  await factory.setManager(await manager.getAddress());
  console.log("Manager set in Factory");
  
  await factory.setTokenFactory(await tokenFactory.getAddress());
  console.log("TokenFactory set in Factory");

  console.log("Deployment completed!");
  console.log({
    factory: await factory.getAddress(),
    router: await router.getAddress(),
    manager: await manager.getAddress(),
    tokenFactory: await tokenFactory.getAddress(),
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