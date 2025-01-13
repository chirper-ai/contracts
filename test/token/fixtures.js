const { ethers, upgrades } = require("hardhat");
const UniswapV2Factory = require('@uniswap/v2-core/build/UniswapV2Factory.json');
const UniswapV2Router02 = require('@uniswap/v2-periphery/build/UniswapV2Router02.json');
const WETH9 = require('@uniswap/v2-periphery/build/WETH9.json');

async function deployTokenFixture() {
  // Get signers
  const [deployer, user1, user2] = await ethers.getSigners();

  // 1. Deploy a mock ERC20 with 18 decimals
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const baseAsset = await MockERC20.deploy("Mock Base Asset", "BASE", 18);
  await baseAsset.waitForDeployment();

  // 2. Deploy WETH
  const wethFactory = await ethers.getContractFactory(WETH9.abi, WETH9.bytecode);
  const weth = await wethFactory.deploy();
  await weth.waitForDeployment();

  // 3. Deploy UniswapV2Factory
  const factoryFactory = await ethers.getContractFactory(UniswapV2Factory.abi, UniswapV2Factory.bytecode);
  const uniswapFactory = await factoryFactory.deploy(deployer.address);
  await uniswapFactory.waitForDeployment();

  // 4. Deploy UniswapV2Router02
  const routerFactory = await ethers.getContractFactory(UniswapV2Router02.abi, UniswapV2Router02.bytecode);
  const uniswapRouter = await routerFactory.deploy(
    await uniswapFactory.getAddress(),
    await weth.getAddress()
  );
  await uniswapRouter.waitForDeployment();

  // 5. Deploy AgentTokenFactory with proxy
  const AgentTokenFactory = await ethers.getContractFactory("AgentTokenFactory");
  const agentFactory = await upgrades.deployProxy(
    AgentTokenFactory,
    [deployer.address],
    {
      initializer: "initialize",
    }
  );
  await agentFactory.waitForDeployment();

  // 6. Set up initial buy amount (10 BASE)
  const initialBuyAmount = ethers.parseUnits("10", 18);

  // 7. Define deployment config with simplified structure
  const defaultConfig = {
    // AgentToken init args
    name: "Test Token",
    symbol: "TEST",
    platform: deployer.address,
    
    // BondingManager init args
    baseAsset: await baseAsset.getAddress(),
    taxVault: deployer.address,
    managerPlatform: deployer.address,
    uniswapFactory: await uniswapFactory.getAddress(),
    uniswapRouter: await uniswapRouter.getAddress(),
    graduationThreshold: ethers.parseUnits("1000000", 18), // 1M BASE for graduation
    assetRate: ethers.parseUnits("1", 18),
    initialBuyAmount: initialBuyAmount
  };

  // 8. Mint initial base asset for deployer and approve
  await baseAsset.mint(deployer.address, ethers.parseUnits("1000000", 18));
  await baseAsset.connect(deployer).approve(await agentFactory.getAddress(), ethers.MaxUint256);

  // 9. Mint initial base asset for users
  const INITIAL_ASSET_AMOUNT = ethers.parseUnits("1000000", 18);
  await baseAsset.mint(user1.address, INITIAL_ASSET_AMOUNT);
  await baseAsset.mint(user2.address, INITIAL_ASSET_AMOUNT);

  // Log deployment addresses for debugging
  console.log("\nDeployment addresses:");
  console.log("Base Asset:", await baseAsset.getAddress());
  console.log("WETH:", await weth.getAddress());
  console.log("Uniswap Factory:", await uniswapFactory.getAddress());
  console.log("Uniswap Router:", await uniswapRouter.getAddress());
  console.log("Agent Factory:", await agentFactory.getAddress());
  console.log("Initial Buy Amount:", initialBuyAmount.toString());

  return {
    baseAsset,
    uniswapFactory,
    uniswapRouter,
    agentFactory,
    defaultConfig,
    deployer,
    user1,
    user2,
    initialBuyAmount,
  };
}

module.exports = {
  deployTokenFixture,
};