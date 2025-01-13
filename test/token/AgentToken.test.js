const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deployTokenFixture } = require("./fixtures");

describe("AgentToken", function () {
  // State variables
  let token;
  let manager;
  let baseAsset;
  let agentFactory;
  let uniswapFactory;
  let uniswapRouter;
  let deployer;
  let user1;
  let user2;
  let defaultConfig;

  async function deployFresh() {
    // Load the fixture
    const fixture = await loadFixture(deployTokenFixture);
    
    // Get references to all contracts and accounts
    baseAsset = fixture.baseAsset;
    agentFactory = fixture.agentFactory;
    uniswapFactory = fixture.uniswapFactory;
    uniswapRouter = fixture.uniswapRouter;
    defaultConfig = fixture.defaultConfig;
    deployer = fixture.deployer;
    user1 = fixture.user1;
    user2 = fixture.user2;

    // Important: The factory needs a base asset allowance to handle the initial buy
    const factoryAddress = await agentFactory.getAddress();
    await baseAsset.connect(deployer).mint(deployer.address, defaultConfig.initialBuyAmount);
    await baseAsset.connect(deployer).approve(factoryAddress, defaultConfig.initialBuyAmount);

    // Deploy system
    const tx = await agentFactory.connect(deployer).deploySystem(defaultConfig);
    const receipt = await tx.wait();

    // Get deployment info from event
    const deployEvent = receipt.logs.find(
      (log) => log.fragment && log.fragment.name === "SystemDeployed"
    );
    const { deployment } = deployEvent.args;

    // Get contract instances
    token = await ethers.getContractAt("AgentToken", deployment.tokenProxy);
    manager = await ethers.getContractAt("AgentBondingManager", deployment.managerProxy);

    // Setup users for testing
    const INITIAL_USER_AMOUNT = ethers.parseUnits("100000", 18);
    
    // Mint and approve for user1
    await baseAsset.connect(deployer).mint(user1.address, INITIAL_USER_AMOUNT);
    await baseAsset.connect(user1).approve(deployment.managerProxy, ethers.MaxUint256);
    
    // Mint and approve for user2
    await baseAsset.connect(deployer).mint(user2.address, INITIAL_USER_AMOUNT);
    await baseAsset.connect(user2).approve(deployment.managerProxy, ethers.MaxUint256);

    return { token, manager, baseAsset };
  }

  describe("Initialization", function () {
    beforeEach(async function() {
      ({ token, manager, baseAsset } = await deployFresh());
    });

    it("Should initialize with correct name and symbol", async function () {
      expect(await token.name()).to.equal(defaultConfig.name);
      expect(await token.symbol()).to.equal(defaultConfig.symbol);
    });

    it("Should set correct manager parameters", async function () {
      expect(await manager.baseAsset()).to.equal(await baseAsset.getAddress());
      expect(await manager.taxVault()).to.equal(defaultConfig.taxVault);
      expect(await manager.uniswapFactory()).to.equal(await uniswapFactory.getAddress());
      expect(await manager.uniswapRouter()).to.equal(await uniswapRouter.getAddress());
      expect(await manager.graduationThreshold()).to.equal(defaultConfig.graduationThreshold);
      expect(await manager.assetRate()).to.equal(defaultConfig.assetRate);
    });

    it("Should initialize with correct initial reserves", async function () {
      const tokenAddr = await token.getAddress();
      const [tokenReserve, assetReserve, marketCap] = await manager.getTokenState(tokenAddr);
      
      expect(tokenReserve).to.be.gt(0);
      expect(assetReserve).to.equal(defaultConfig.initialBuyAmount);
      expect(marketCap).to.be.gt(0);
    });
  });

  describe("Trading", function () {
    beforeEach(async function() {
      ({ token, manager, baseAsset } = await deployFresh());
    });

    it("Should allow buying tokens", async function () {
      const buyAmount = ethers.parseUnits("100", 18);
      const balanceBefore = await token.balanceOf(user1.address);
      
      const tx = await manager.connect(user1).buy(await token.getAddress(), buyAmount);
      const receipt = await tx.wait();
      
      const tradeEvent = receipt.logs.find(log => 
        log.fragment && log.fragment.name === "Trade"
      );
      
      expect(await token.balanceOf(user1.address)).to.be.gt(balanceBefore);
      expect(tradeEvent.args.isBuy).to.be.true;
      expect(tradeEvent.args.assetAmount).to.equal(buyAmount);
    });

    it("Should allow selling tokens", async function () {
      // First buy some tokens
      const buyAmount = ethers.parseUnits("100", 18);
      await manager.connect(user1).buy(await token.getAddress(), buyAmount);
      const tokenBalance = await token.balanceOf(user1.address);
      
      // Then sell half
      const sellAmount = tokenBalance / 2n;
      await token.connect(user1).approve(await manager.getAddress(), sellAmount);
      const balanceBefore = await baseAsset.balanceOf(user1.address);
      
      await manager.connect(user1).sell(await token.getAddress(), sellAmount);
      
      expect(await baseAsset.balanceOf(user1.address)).to.be.gt(balanceBefore);
      expect(await token.balanceOf(user1.address)).to.equal(tokenBalance - sellAmount);
    });
  });

  describe("Graduation", function () {
    beforeEach(async function() {
      ({ token, manager, baseAsset } = await deployFresh());
    });

    it("Should graduate to Uniswap when threshold is reached", async function () {
      const tokenAddr = await token.getAddress();
      
      // Buy enough to trigger graduation
      const buyAmount = ethers.parseUnits("1000000", 18);
      await manager.connect(user1).buy(tokenAddr, buyAmount);
      
      const curveData = await manager.getTokenInfo(tokenAddr);
      expect(curveData.graduated).to.be.true;
      expect(curveData.uniswapPair).to.not.equal(ethers.ZeroAddress);
      
      // Check Uniswap pair liquidity
      const pair = await ethers.getContractAt("IUniswapV2Pair", curveData.uniswapPair);
      const [reserve0, reserve1] = await pair.getReserves();
      expect(reserve0).to.be.gt(0);
      expect(reserve1).to.be.gt(0);
      
      // Verify trading is enabled on token
      expect(await token.tradingEnabled()).to.be.true;
    });

    it("Should not allow bonding curve trades after graduation", async function () {
      const tokenAddr = await token.getAddress();
      
      // Graduate first
      const buyAmount = ethers.parseUnits("1000000", 18);
      await manager.connect(user1).buy(tokenAddr, buyAmount);
      
      // Try to buy more through bonding curve
      const smallBuy = ethers.parseUnits("1", 18);
      await expect(
        manager.connect(user1).buy(tokenAddr, smallBuy)
      ).to.be.revertedWith("Token graduated");
      
      // Try to sell through bonding curve
      const sellAmount = ethers.parseUnits("1", 18);
      await expect(
        manager.connect(user1).sell(tokenAddr, sellAmount)
      ).to.be.revertedWith("Token graduated");
    });
  });

  describe("Tax Collection", function () {
    beforeEach(async function() {
      ({ token, manager, baseAsset } = await deployFresh());
    });

    it("Should collect and distribute taxes correctly", async function () {
      const tokenAddr = await token.getAddress();
      const taxVaultAddr = await manager.taxVault();
      const curveData = await manager.getTokenInfo(tokenAddr);
      
      const vaultBefore = await baseAsset.balanceOf(taxVaultAddr);
      const creatorBefore = await baseAsset.balanceOf(curveData.creator);
      
      const buyAmount = ethers.parseUnits("100", 18);
      await manager.connect(user1).buy(tokenAddr, buyAmount);
      
      expect(await baseAsset.balanceOf(taxVaultAddr)).to.be.gt(vaultBefore);
      expect(await baseAsset.balanceOf(curveData.creator)).to.be.gt(creatorBefore);
    });
  });

  describe("Admin Functions", function () {
    beforeEach(async function() {
      ({ token, manager, baseAsset } = await deployFresh());
    });

    it("Should allow updating tax configuration", async function () {
      const newTaxVault = user2.address;
      const newBuyTax = 200; // 2%
      const newSellTax = 200; // 2%
      
      await manager.connect(deployer).updateTaxConfig(newTaxVault, newBuyTax, newSellTax);
      
      expect(await manager.taxVault()).to.equal(newTaxVault);
      expect(await manager.buyTax()).to.equal(newBuyTax);
      expect(await manager.sellTax()).to.equal(newSellTax);
    });

    it("Should allow pausing and unpausing", async function () {
      await manager.connect(deployer).pause();
      
      const buyAmount = ethers.parseUnits("1", 18);
      await expect(
        manager.connect(user1).buy(await token.getAddress(), buyAmount)
      ).to.be.revertedWith("Pausable: paused");
      
      await manager.connect(deployer).unpause();
      
      // Should work after unpausing
      await expect(
        manager.connect(user1).buy(await token.getAddress(), buyAmount)
      ).to.not.be.reverted;
    });
  });
});