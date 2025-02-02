const { ethers, upgrades, network, run } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Network:", network.name);
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

  // Initial parameters
  const INITIAL_RESERVE = ethers.parseEther(`${5_000}`); // 5K reserve
  const INITIAL_SUPPLY = ethers.parseEther(`${1_000_000_000}`); // 1B tokens
  const MOCK_TOKEN_SUPPLY = ethers.parseEther(`${10_000_000_000}`); // 10B tokens for MockERC20
  const IMPACT_MULTIPLIER = 5; // 5x impact multiplier
  const MAX_HOLD_PERCENT = 100_000; // 100% maximum hold
  const GRADUATION_THRESHOLD = 50_000; // 50% threshold

  // Deploy MockERC20 first
  /*
  console.log("Deploying MockERC20...");
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const mockToken = await MockERC20.deploy(
    "Chirper Mode",  // name
    "CHODE",         // symbol
    MOCK_TOKEN_SUPPLY // 10B supply
  );
  await mockToken.waitForDeployment();
  */
  const ASSET_TOKEN_ADDRESS = '0x6C33C2fa2b532FC922c45468AcAD0612E80ac025'; // CHODE TOKEN
  console.log("MockERC20 deployed to:", ASSET_TOKEN_ADDRESS);

  console.log("Deploying Factory...");
  const Factory = await ethers.getContractFactory("Factory");
  const factory = await upgrades.deployProxy(Factory, [
    INITIAL_RESERVE,
    IMPACT_MULTIPLIER,
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

  console.log("Deploying Token Factory...");
  const TokenFactory = await ethers.getContractFactory("TokenFactory");
  const tokenFactory = await upgrades.deployProxy(TokenFactory, [
    await factory.getAddress(),
    await manager.getAddress(),
    INITIAL_SUPPLY,
  ]);
  await tokenFactory.waitForDeployment();
  console.log("TokenFactory deployed to:", await tokenFactory.getAddress());

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
    network: network.name,
    uniswapV3: uniswapV3Address,
    mockToken: ASSET_TOKEN_ADDRESS,
    factory: await factory.getAddress(),
    router: await router.getAddress(),
    manager: await manager.getAddress(),
    tokenFactory: await tokenFactory.getAddress(),
  });

  // Verify contracts on Mode Explorer
  if (network.name === "mode-mainnet" || network.name === "mode-testnet") {
    console.log(`Verifying contracts on Mode Explorer...`);
    try {
      // Add delay to allow indexing
      console.log("Waiting for contracts to be indexed...");
      await new Promise(resolve => setTimeout(resolve, 20000)); // 20 second delay

      // Verify MockERC20
      await run("verify:verify", {
        address: ASSET_TOKEN_ADDRESS,
        constructorArguments: ["Chirper Mode", "CHODE", MOCK_TOKEN_SUPPLY]
      });

      // Verify implementation contracts
      const factoryImplementation = await upgrades.erc1967.getImplementationAddress(await factory.getAddress());
      await run("verify:verify", {
        address: factoryImplementation,
        constructorArguments: []
      });

      const routerImplementation = await upgrades.erc1967.getImplementationAddress(await router.getAddress());
      await run("verify:verify", {
        address: routerImplementation,
        constructorArguments: []
      });

      const managerImplementation = await upgrades.erc1967.getImplementationAddress(await manager.getAddress());
      await run("verify:verify", {
        address: managerImplementation,
        constructorArguments: []
      });

      const tokenFactoryImplementation = await upgrades.erc1967.getImplementationAddress(await tokenFactory.getAddress());
      await run("verify:verify", {
        address: tokenFactoryImplementation,
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