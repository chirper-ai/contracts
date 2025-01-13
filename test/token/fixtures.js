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
  const factory = await factoryFactory.deploy(deployer.address);
  await factory.waitForDeployment();

  // 4. Deploy UniswapV2Router02
  const routerFactory = await ethers.getContractFactory(UniswapV2Router02.abi, UniswapV2Router02.bytecode);
  const router = await routerFactory.deploy(
    await factory.getAddress(),
    await weth.getAddress()
  );
  await router.waitForDeployment();

  // 5. Deploy UniswapV2Adapter with real router
  const UniswapV2Adapter = await ethers.getContractFactory("UniswapAdapter");
  const uniswapAdapter = await UniswapV2Adapter.deploy(
    await router.getAddress()
  );
  await uniswapAdapter.waitForDeployment();

  // 6. Deploy AgentTokenFactory with proxy
  const AgentTokenFactory = await ethers.getContractFactory("AgentTokenFactory");
  const agentFactory = await upgrades.deployProxy(
    AgentTokenFactory,
    [deployer.address],
    {
      initializer: "initialize",
    }
  );
  await agentFactory.waitForDeployment();

  // 7. Set up initial buy amount (10 BASE)
  const initialBuyAmount = ethers.parseUnits("10", 18);

  // 8. Define default curve config
  const defaultConfig = {
    name: "Test Token",
    symbol: "TEST",
    platform: deployer.address,
    baseAsset: await baseAsset.getAddress(),
    registry: deployer.address,
    managerPlatform: deployer.address,
    initialAssetRate: ethers.parseUnits("1", 18),
    initialBuyAmount: initialBuyAmount,
    curveConfig: {
      gradThreshold: ethers.parseUnits("1000000", 18), // 1M BASE for graduation
      dexAdapters: [await uniswapAdapter.getAddress()],
      dexWeights: [100], // 100%
    },
  };

  // 9. Mint larger initial supply of base asset to users for testing
  const INITIAL_ASSET_AMOUNT = ethers.parseUnits("1000000", 18); // 1M BASE tokens
  await baseAsset.mint(user1.address, INITIAL_ASSET_AMOUNT);
  await baseAsset.mint(user2.address, INITIAL_ASSET_AMOUNT);

  // 10. Approve router for token spending
  await baseAsset.connect(user1).approve(router.getAddress(), ethers.MaxUint256);
  await baseAsset.connect(user2).approve(router.getAddress(), ethers.MaxUint256);

  // Log deployment addresses for debugging
  console.log("Deployment addresses:");
  console.log("Base Asset:", await baseAsset.getAddress());
  console.log("WETH:", await weth.getAddress());
  console.log("Factory:", await factory.getAddress());
  console.log("Router:", await router.getAddress());
  console.log("Adapter:", await uniswapAdapter.getAddress());
  console.log("Buy Amount:", initialBuyAmount);

  return {
    baseAsset,
    uniswapAdapter,
    factory,
    router,
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