const { ethers, upgrades } = require("hardhat");

async function deployTokenFixture() {
  // Get signers
  const [deployer, user1, user2] = await ethers.getSigners();

  // Deploy mock USDC
  const MockUSDC = await ethers.getContractFactory("MockERC20");
  const usdc = await MockUSDC.deploy("USD Coin", "USDC", 6);
  // Remove await usdc.deployed();

  // Deploy UniswapV2Adapter
  const UniswapV2Adapter = await ethers.getContractFactory("UniswapAdapter");
  const uniswapAdapter = await UniswapV2Adapter.deploy(
    "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D" // We can use mainnet address in tests
  );
  // Remove await uniswapAdapter.deployed();

  // Deploy AgentTokenFactory with proxy
  const AgentTokenFactory = await ethers.getContractFactory("AgentTokenFactory");
  const factory = await upgrades.deployProxy(AgentTokenFactory, [deployer.address], {
    initializer: 'initialize',
  });
  // Remove await factory.deployed();

  // Default curve config
  const defaultConfig = {
    name: "Test Token",
    symbol: "TEST",
    platform: deployer.address,
    baseAsset: usdc.address,
    registry: deployer.address,
    managerPlatform: deployer.address,
    curveConfig: {
      gradThreshold: ethers.utils.parseUnits("10000", 18),
      dexAdapters: [uniswapAdapter.address],
      dexWeights: [100]
    }
  };

  return {
    usdc,
    uniswapAdapter,
    factory,
    defaultConfig,
    deployer,
    user1,
    user2
  };
}

module.exports = {
  deployTokenFixture
};