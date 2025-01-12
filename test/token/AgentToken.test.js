// test/token/AgentToken.test.js
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deployTokenFixture } = require("./fixtures");

describe("AgentToken", function () {
  let token;
  let manager;
  let usdc;
  let factory;
  let deployer;
  let user1;
  let user2;
  let defaultConfig;

  beforeEach(async function () {
    // Load the fixture
    const fixture = await loadFixture(deployTokenFixture);
    usdc = fixture.usdc;
    factory = fixture.factory;
    defaultConfig = fixture.defaultConfig;
    deployer = fixture.deployer;
    user1 = fixture.user1;
    user2 = fixture.user2;

    // Deploy a new token system
    const tx = await factory.deploySystem(defaultConfig);
    const receipt = await tx.wait();
    
    // Get the deployed addresses from the event
    const event = receipt.events?.find(e => e.event === 'SystemDeployed');
    const { deployment } = event.args;
    
    // Get contract instances
    token = await ethers.getContractAt("AgentToken", deployment.tokenProxy);
    manager = await ethers.getContractAt("AgentBondingManager", deployment.managerProxy);

    // Setup: Mint some USDC to users
    await usdc.mint(user1.address, ethers.utils.parseUnits("100000", 6));
    await usdc.mint(user2.address, ethers.utils.parseUnits("100000", 6));
    
    // Approve USDC spending
    await usdc.connect(user1).approve(manager.address, ethers.constants.MaxUint256);
    await usdc.connect(user2).approve(manager.address, ethers.constants.MaxUint256);
  });

  describe("Initialization", function () {
    it("Should initialize with correct name and symbol", async function () {
      expect(await token.name()).to.equal(defaultConfig.name);
      expect(await token.symbol()).to.equal(defaultConfig.symbol);
    });

    it("Should set correct roles", async function () {
      const PLATFORM_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("PLATFORM_ROLE"));
      expect(await token.hasRole(PLATFORM_ROLE, defaultConfig.platform)).to.be.true;
    });
  });

  describe("Trading", function () {
    it("Should allow buying tokens", async function () {
      const buyAmount = ethers.utils.parseUnits("1000", 6); // 1000 USDC
      const tx = await manager.connect(user1).buy(token.address, buyAmount);
      const receipt = await tx.wait();
      
      // Find the Trade event
      const event = receipt.events?.find(e => e.event === 'Trade');
      expect(event.args.isBuy).to.be.true;
      expect(event.args.trader).to.equal(user1.address);
      
      // Verify token balance increased
      expect(await token.balanceOf(user1.address)).to.be.gt(0);
    });

    it("Should allow selling tokens", async function () {
      // First buy some tokens
      const buyAmount = ethers.utils.parseUnits("1000", 6);
      await manager.connect(user1).buy(token.address, buyAmount);
      
      // Get token balance
      const tokenBalance = await token.balanceOf(user1.address);
      
      // Approve tokens for selling
      await token.connect(user1).approve(manager.address, tokenBalance);
      
      // Sell all tokens
      const tx = await manager.connect(user1).sell(token.address, tokenBalance);
      const receipt = await tx.wait();
      
      // Verify token balance is now 0
      expect(await token.balanceOf(user1.address)).to.equal(0);
    });
  });

  describe("Graduation", function () {
    it("Should graduate after reaching threshold", async function () {
      // Buy enough tokens to trigger graduation
      const buyAmount = ethers.utils.parseUnits("10000", 6); // 10k USDC
      await manager.connect(user1).buy(token.address, buyAmount);
      
      // Verify graduation status
      expect(await token.isGraduated()).to.be.true;
      expect(await manager.isGraduated(token.address)).to.be.true;
      
      // Verify DEX pairs were created
      const pairs = await manager.getDexPairs(token.address);
      expect(pairs.length).to.equal(1); // One pair for Uniswap
    });
  });

  describe("Tax Collection", function () {
    it("Should collect and distribute taxes correctly", async function () {
      const buyAmount = ethers.utils.parseUnits("1000", 6);
      const taxVaultBalanceBefore = await usdc.balanceOf(defaultConfig.registry);
      
      await manager.connect(user1).buy(token.address, buyAmount);
      
      // Verify tax vault received its share
      const taxVaultBalanceAfter = await usdc.balanceOf(defaultConfig.registry);
      expect(taxVaultBalanceAfter).to.be.gt(taxVaultBalanceBefore);
    });
  });
});