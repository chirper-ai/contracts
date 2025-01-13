const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deployTokenFixture } = require("./fixtures");

describe("AgentToken", function () {
  let token;
  let manager;
  let baseAsset;
  let agentFactory;
  let deployer;
  let user1;
  let user2;
  let defaultConfig;

  // Helper function to check reserves and sync if needed
  async function checkAndSyncReserves(token, manager) {
    const actualTokenBalance = await token.balanceOf(manager.getAddress());
    const actualAssetBalance = await baseAsset.balanceOf(manager.getAddress());
    const [storedTokenReserve, storedAssetReserve] = await manager.getTotalReserves(await token.getAddress());

    if (actualTokenBalance !== storedTokenReserve || actualAssetBalance !== storedAssetReserve) {
      await manager.updatePriceData(token.getAddress());
    }
  }

  async function deployFresh() {
    // Load the fixture
    const fixture = await loadFixture(deployTokenFixture);
    baseAsset = fixture.baseAsset;
    agentFactory = fixture.agentFactory;
    defaultConfig = fixture.defaultConfig;
    deployer = fixture.deployer;
    user1 = fixture.user1;
    user2 = fixture.user2;

    // Mint baseAsset to deployer and approve factory
    await baseAsset.mint(deployer.address, ethers.parseUnits("1000000", 18));
    await baseAsset.connect(deployer).approve(await agentFactory.getAddress(), ethers.MaxUint256);

    // Deploy system
    const tx = await agentFactory.deploySystem(defaultConfig);
    const receipt = await tx.wait();

    // Extract deployment info from event
    const deployEvent = receipt.logs.find(
        (log) => log.fragment && log.fragment.name === "SystemDeployed"
    );
    const { deployment } = deployEvent.args;

    // Get contract instances
    token = await ethers.getContractAt("AgentToken", deployment.tokenProxy);
    manager = await ethers.getContractAt("AgentBondingManager", deployment.managerProxy);

    // Mint and approve baseAsset for users
    await baseAsset.mint(user1.address, ethers.parseUnits("100000", 18));
    await baseAsset.mint(user2.address, ethers.parseUnits("100000", 18));
    await baseAsset.connect(user1).approve(deployment.managerProxy, ethers.MaxUint256);
    await baseAsset.connect(user2).approve(deployment.managerProxy, ethers.MaxUint256);

    // Verify registration
    const isRegistered = await manager.isTokenRegistered(await token.getAddress());
    if (!isRegistered) {
        throw new Error("Token not properly registered");
    }

    return { token, manager, baseAsset };
  }

  describe("Initialization", function () {
    beforeEach(async function() {
      await deployFresh();
    });

    it("Should initialize with correct name and symbol", async function () {
      expect(await token.name()).to.equal(defaultConfig.name);
      expect(await token.symbol()).to.equal(defaultConfig.symbol);
    });

    it("Should set correct roles", async function () {
      const PLATFORM_ROLE = ethers.keccak256(ethers.toUtf8Bytes("PLATFORM_ROLE"));
      expect(await token.hasRole(PLATFORM_ROLE, defaultConfig.platform)).to.be.true;
    });

    it("Should be properly registered with manager", async function () {
      expect(await manager.isTokenRegistered(await token.getAddress())).to.be.true;
    });

    it("Should initialize with correct reserves and sync properly", async function () {
      // First check actual balances
      await checkAndSyncReserves(token, manager);
      
      // Now get reserves after potential sync
      const [tokenReserve, assetReserve, marketCap] = await manager.getTokenState(await token.getAddress());
      const tokenDecimals = await token.decimals();
      const baseDecimals = await baseAsset.decimals();

      // Expected values based on initialization parameters
      const expectedTokenReserve = ethers.parseUnits("1000000", tokenDecimals);
      const expectedAssetReserve = ethers.parseUnits("10000", baseDecimals);

      expect(tokenReserve).to.equal(expectedTokenReserve);
      expect(assetReserve).to.equal(expectedAssetReserve);
      expect(marketCap).to.be.gt(0);
    });
  });

  describe("Trading", function () {
    beforeEach(async function() {
      await deployFresh();
    });

    it("Should allow buying tokens and update reserves correctly", async function () {
      // Ensure reserves are synced before trade
      await checkAndSyncReserves(token, manager);
      
      // Get initial state
      const [initialTokenReserve, initialAssetReserve, initialMarketCap] = await manager.getTokenState(await token.getAddress());
      const initialPrice = await manager.getPrice(await token.getAddress());
      
      // Buy parameters
      const buyAmount = ethers.parseUnits("100", 18);
      
      // Get expected tokens out
      const expectedTokens = await manager.getBuyPrice(await token.getAddress(), buyAmount);
      
      // Execute buy
      const tx = await manager.connect(user1).buy(await token.getAddress(), buyAmount);
      await tx.wait();
      
      // Ensure reserves are synced after trade
      await checkAndSyncReserves(token, manager);
      
      // Get final state
      const [newTokenReserve, newAssetReserve, newMarketCap] = await manager.getTokenState(await token.getAddress());
      const userTokenBalance = await token.balanceOf(user1.address);
      const newPrice = await manager.getPrice(await token.getAddress());
      
      // Verify results
      expect(userTokenBalance).to.equal(expectedTokens);
      expect(newAssetReserve).to.be.gt(initialAssetReserve);
      expect(newTokenReserve).to.be.lt(initialTokenReserve);
      expect(newPrice).to.be.gt(initialPrice);
      expect(newMarketCap).to.be.gt(initialMarketCap);
    });

    it("Should allow selling tokens with proper reserve updates", async function () {
      // First do a buy
      const buyAmount = ethers.parseUnits("100", 18);
      await manager.connect(user1).buy(await token.getAddress(), buyAmount);
      await checkAndSyncReserves(token, manager);
      
      // Get state before sell
      const [initialTokenReserve, initialAssetReserve, initialMarketCap] = await manager.getTokenState(await token.getAddress());
      const userTokenBalance = await token.balanceOf(user1.address);
      
      // Sell half
      const sellAmount = userTokenBalance / 2n;
      const expectedAssets = await manager.getSellPrice(await token.getAddress(), sellAmount);
      
      // Approve and sell
      await token.connect(user1).approve(await manager.getAddress(), sellAmount);
      await manager.connect(user1).sell(await token.getAddress(), sellAmount);
      
      // Sync and check final state
      await checkAndSyncReserves(token, manager);
      const [newTokenReserve, newAssetReserve, newMarketCap] = await manager.getTokenState(await token.getAddress());
      const finalUserTokenBalance = await token.balanceOf(user1.address);
      
      // Verify
      expect(finalUserTokenBalance).to.equal(userTokenBalance - sellAmount);
      expect(newAssetReserve).to.be.lt(initialAssetReserve);
      expect(newTokenReserve).to.be.gt(initialTokenReserve);
      expect(newMarketCap).to.be.lt(initialMarketCap);
    });
  });

  describe("Graduation", function () {
    beforeEach(async function() {
      await deployFresh();
    });

    it("Should graduate after reaching threshold and setup DEX properly", async function () {
      // Buy enough to trigger graduation
      const buyAmount = ethers.parseUnits("1000000", 18);
      const tx = await manager.connect(user1).buy(await token.getAddress(), buyAmount);
      await tx.wait();
      
      // Ensure everything is synced
      await checkAndSyncReserves(token, manager);
      
      // Check graduation status and DEX setup
      const isGraduated = await manager.isGraduated(await token.getAddress());
      expect(isGraduated).to.be.true;
      
      // Get DEX pairs
      const dexPairs = await manager.getDexPairs(await token.getAddress());
      expect(dexPairs.length).to.be.gt(0);
      
      // Check pair liquidity
      for (const pair of dexPairs) {
        const pairContract = await ethers.getContractAt("IDEXPair", pair);
        const [reserve0, reserve1] = await pairContract.getReserves();
        expect(reserve0).to.be.gt(0);
        expect(reserve1).to.be.gt(0);
      }
    });
  });

  describe("Tax Collection", function () {
    beforeEach(async function() {
      await deployFresh();
    });
    
    it("Should collect and distribute taxes according to configured splits", async function () {
      const buyTax = await manager.buyTax();
      const taxVaultAddr = await manager.taxVault();
      const tokenAddr = await token.getAddress();
      
      // Get initial balances
      const vaultBalanceBefore = await baseAsset.balanceOf(taxVaultAddr);
      const creatorBalanceBefore = await baseAsset.balanceOf(await manager.curves(tokenAddr).creator);
      
      // Execute buy
      const buyAmount = ethers.parseUnits("1000", 18);
      await manager.connect(user1).buy(tokenAddr, buyAmount);
      
      // Get tax splits
      const [platformTax, creatorTax] = await manager.getTaxSplit(true, buyAmount);
      
      // Check final balances
      const vaultBalanceAfter = await baseAsset.balanceOf(taxVaultAddr);
      const creatorBalanceAfter = await baseAsset.balanceOf(await manager.curves(tokenAddr).creator);
      
      // Verify tax distribution
      expect(vaultBalanceAfter - vaultBalanceBefore).to.equal(platformTax);
      expect(creatorBalanceAfter - creatorBalanceBefore).to.equal(creatorTax);
    });
  });
});