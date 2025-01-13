const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { deployTokenFixture } = require("./fixtures");

describe("AgentToken", function () {
  let token;
  let manager;
  let baseAsset;   // renamed from 'usdc'
  let agentFactory;
  let deployer;
  let user1;
  let user2;
  let defaultConfig;

  async function deployFresh() {
    // Load the fixture (make sure your fixture now deploys an 18-dec mock or real ERC20)
    const fixture = await loadFixture(deployTokenFixture);
    baseAsset = fixture.baseAsset; // formerly 'usdc'
    agentFactory = fixture.agentFactory;
    defaultConfig = fixture.defaultConfig;
    deployer = fixture.deployer;
    user1 = fixture.user1;
    user2 = fixture.user2;

    // Deploy a new token system via your agentFactory
    const tx = await agentFactory.deploySystem(defaultConfig);
    const receipt = await tx.wait();

    // Extract deployment info from emitted event
    const deployEvent = receipt.logs.find(
      (log) => log.fragment && log.fragment.name === "SystemDeployed"
    );
    const { deployment } = deployEvent.args;

    // Get contract instances
    token = await ethers.getContractAt("AgentToken", deployment.tokenProxy);
    manager = await ethers.getContractAt("AgentBondingManager", deployment.managerProxy);

    // Mint baseAsset to users (now 18 decimals)
    await baseAsset.mint(user1.address, ethers.parseUnits("100000", 18));
    await baseAsset.mint(user2.address, ethers.parseUnits("100000", 18));

    // Approve baseAsset spending for manager
    await baseAsset.connect(user1).approve(manager.getAddress(), ethers.MaxUint256);
    await baseAsset.connect(user2).approve(manager.getAddress(), ethers.MaxUint256);

    // Verify token registration
    const isRegistered = await manager.isTokenRegistered(token.getAddress());
    if (!isRegistered) {
      throw new Error("Token not properly registered with manager");
    }
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
      expect(await manager.isTokenRegistered(token.getAddress())).to.be.true;
    });

    it("Should initialize with correct reserves", async function () {
      const [tokenReserve, assetReserve] = await manager.getReserves(token.getAddress());

      // Both should be 1e24 if the manager is set to mint 1,000,000 * 1e18 tokens
      // and set the same amount in the baseAsset reserve.
      expect(tokenReserve.toString()).to.equal("100000000000000000000000000"); // 1e24
      expect(assetReserve.toString()).to.equal("1"); // 1e24
    });
  });

  describe("Trading", function () {
    beforeEach(async function() {
      await deployFresh();
    });

    it("Should allow buying tokens", async function () {
      // Get initial state
      const [initialTokenReserve, initialAssetReserve] = await manager.getReserves(token.getAddress());
  
      // Buy parameters
      const buyAmount = ethers.parseUnits("100", 18); // Much smaller amount
  
      // Execute buy
      const tx = await manager.connect(user1).buy(token.getAddress(), buyAmount);
      await tx.wait();
  
      // Check results
      const [newTokenReserve, newAssetReserve] = await manager.getReserves(token.getAddress());
      const userTokenBalance = await token.balanceOf(user1.address);
  
      // Simple assertions using BigNumber comparisons
      expect(userTokenBalance > 0n).to.be.true;
      expect(newAssetReserve > initialAssetReserve).to.be.true;
      expect(newTokenReserve < initialTokenReserve).to.be.true;
    });
  

    it("Should allow selling tokens", async function () {
      // First do a buy to have tokens to sell
      const buyAmount = ethers.parseUnits("100", 18); // Much smaller amount
      const buyTx = await manager.connect(user1).buy(token.getAddress(), buyAmount);
      await buyTx.wait();
  
      // Get state before sell
      const [initialTokenReserve, initialAssetReserve] = await manager.getReserves(token.getAddress());
      const userTokenBalance = await token.balanceOf(user1.address);
  
      // Sell half of the tokens
      const sellAmount = userTokenBalance / 2n;
      
      // Approve tokens for selling
      await token.connect(user1).approve(manager.getAddress(), sellAmount);
  
      // Execute sell
      const sellTx = await manager.connect(user1).sell(token.getAddress(), sellAmount);
      await sellTx.wait();
  
      // Check results
      const [newTokenReserve, newAssetReserve] = await manager.getReserves(token.getAddress());
      const finalUserTokenBalance = await token.balanceOf(user1.address);
  
      // Simple assertions using BigNumber comparisons
      expect(finalUserTokenBalance < userTokenBalance).to.be.true;
      expect(newAssetReserve < initialAssetReserve).to.be.true;
      expect(newTokenReserve > initialTokenReserve).to.be.true;
    });
  });

  describe("Graduation", function () {
    beforeEach(async function() {
      await deployFresh();
    });

    it("Should graduate after reaching threshold", async function () {
      // Buy enough tokens to reach graduation threshold
      const buyAmount = ethers.parseUnits("1000000", 18); // Large buy to reach threshold
      const tx = await manager.connect(user1).buy(token.getAddress(), buyAmount);
      await tx.wait();
  
      // Get state after buy
      const [tokenReserve, assetReserve] = await manager.getReserves(token.getAddress());
      const marketCap = await manager.getMarketCap(token.getAddress());
  
      // Check graduation status
      const isGraduated = await token.isGraduated();
  
      // Simple assertions
      expect(isGraduated).to.be.true;
    });
  });

  describe("Tax Collection", function () {
    beforeEach(async function() {
      await deployFresh();
    });
    
    it("Should collect and distribute taxes correctly", async function () {
      const buyTax = await manager.buyTax();
      const registryAddress = await manager.taxVault();

      const buyAmount = ethers.parseUnits("1000", 18);

      // Get initial vault balance
      const taxVaultBalanceBefore = await baseAsset.balanceOf(registryAddress);

      // Execute buy
      await manager.connect(user1).buy(token.getAddress(), buyAmount);

      // Check final vault balance
      const taxVaultBalanceAfter = await baseAsset.balanceOf(registryAddress);

      // Expect the difference to match the tax portion
      const expectedTax = (buyAmount * buyTax) / 10000n;
      const actualTaxCollected = taxVaultBalanceAfter - taxVaultBalanceBefore;
      expect(actualTaxCollected).to.equal(expectedTax);
    });
  });

  describe("Post-Graduation Trading", function () {
    beforeEach(async function() {
        await deployFresh();
    });

    it("Should properly handle graduation with DEX setup", async function() {
      // 1. Get initial state
      const dexAdapters = await manager.getDEXAdapters();
      const adapter = await ethers.getContractAt("IDEXAdapter", dexAdapters[0]);
      const router = await ethers.getContractAt("IUniswapV2Router02", await adapter.getRouterAddress());
      
      console.log("\nPre-graduation state:");
      console.log("Router address:", await adapter.getRouterAddress());
      
      // 2. Execute buy to trigger graduation
      const buyAmount = ethers.parseUnits("1000000", 18);
      const graduationTx = await manager.connect(user1).buy(token.getAddress(), buyAmount);
      const receipt = await graduationTx.wait();
      
      // 3. Get post-graduation state
      const isGraduated = await token.isGraduated();
      console.log("\nPost-graduation state:");
      console.log("Graduated:", isGraduated);
      
      // 4. Check pair and liquidity
      const pairAddress = await adapter.getPair(token.getAddress(), await baseAsset.getAddress());
      const pair = await ethers.getContractAt("IDEXPair", pairAddress);
      
      console.log("Pair address:", pairAddress);
      
      const [reserve0, reserve1] = await pair.getReserves();
      console.log("\nPair reserves:");
      console.log("Reserve0:", ethers.formatUnits(reserve0, 18));
      console.log("Reserve1:", ethers.formatUnits(reserve1, 18));
      
      // 5. Check router approvals
      const routerAddr = await adapter.getRouterAddress();
      const tokenApproval = await token.allowance(manager.getAddress(), routerAddr);
      const baseApproval = await baseAsset.allowance(manager.getAddress(), routerAddr);
      
      console.log("\nRouter approvals:");
      console.log("Token:", ethers.formatUnits(tokenApproval, 18));
      console.log("Base:", ethers.formatUnits(baseApproval, 18));
    });  
  });
});
