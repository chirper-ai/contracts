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
      const curveData = await manager.getTokenInfo(tokenAddr);
      
      // curveData[2] = tokenReserve
      // curveData[3] = assetReserve
      // curveData[6] = marketCap
      expect(Number(curveData[2])).to.be.gt(Number(0n));
      expect(Number(curveData[3])).to.equal(Number(defaultConfig.initialBuyAmount));
      expect(Number(curveData[6])).to.be.gt(Number(0n));
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
      
      const balanceAfter = await token.balanceOf(user1.address);
      expect(Number(balanceAfter)).to.be.gt(Number(balanceBefore));
      expect(tradeEvent.args.isBuy).to.be.true;
      expect(Number(tradeEvent.args.assetAmount)).to.equal(Number(buyAmount));
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
      
      const balanceAfter = await baseAsset.balanceOf(user1.address);
      expect(Number(balanceAfter)).to.be.gt(Number(balanceBefore));
      const finalTokenBalance = await token.balanceOf(user1.address);
      expect(Number(finalTokenBalance)).to.equal(Number(tokenBalance) - Number(sellAmount));
    });
  });

  describe("Graduation", function () {
    beforeEach(async function() {
        ({ token, manager, baseAsset } = await deployFresh());
    });

    it("Should graduate to Uniswap when threshold is reached", async function () {
        const tokenAddr = await token.getAddress();
        
        // Log initial state
        const initialCurveData = await manager.getTokenInfo(tokenAddr);
        console.log("Initial token reserve:", initialCurveData.tokenReserve.toString());
        console.log("Initial asset reserve:", initialCurveData.assetReserve.toString());
        console.log("Initial market cap:", initialCurveData.marketCap.toString());
        
        // Check contract's token balance before buy
        const contractBalance = await token.balanceOf(await manager.getAddress());
        console.log("Contract token balance before buy:", contractBalance.toString());
        
        // Get graduation threshold for reference
        const threshold = await manager.graduationThreshold();
        console.log("Graduation threshold:", threshold.toString());
        
        // Buy enough to trigger graduation - let's try a smaller amount first
        const buyAmount = ethers.parseUnits("100000", 18); // Reduced from 1,000,000
        console.log("Attempting to buy amount:", buyAmount.toString());
        
        // Check buyer's asset balance and allowance
        const buyerBalance = await baseAsset.balanceOf(user1.address);
        const buyerAllowance = await baseAsset.allowance(user1.address, await manager.getAddress());
        console.log("Buyer asset balance:", buyerBalance.toString());
        console.log("Buyer allowance:", buyerAllowance.toString());
        
        // Execute the buy
        const tx = await manager.connect(user1).buy(tokenAddr, buyAmount);
        const receipt = await tx.wait();
        
        // Get post-buy state
        const postBuyCurveData = await manager.getTokenInfo(tokenAddr);
        console.log("Post-buy token reserve:", postBuyCurveData.tokenReserve.toString());
        console.log("Post-buy asset reserve:", postBuyCurveData.assetReserve.toString());
        console.log("Post-buy market cap:", postBuyCurveData.marketCap.toString());
        
        // Check if graduated
        expect(postBuyCurveData.graduated).to.be.true;
        expect(postBuyCurveData.uniswapPair).to.not.equal(ethers.ZeroAddress);
        
        // Check Uniswap pair liquidity
        const pair = await ethers.getContractAt("IUniswapV2Pair", postBuyCurveData.uniswapPair);
        const [reserve0, reserve1] = await pair.getReserves();
        console.log("Uniswap reserve0:", reserve0.toString());
        console.log("Uniswap reserve1:", reserve1.toString());
        
        // Verify trading is enabled on token
        expect(await token.tradingEnabled()).to.be.true;
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
      const creatorBefore = await baseAsset.balanceOf(curveData[1]);
      
      const buyAmount = ethers.parseUnits("100", 18);
      await manager.connect(user1).buy(tokenAddr, buyAmount);
      
      const vaultAfter = await baseAsset.balanceOf(taxVaultAddr);
      const creatorAfter = await baseAsset.balanceOf(curveData[1]);
      
      expect(Number(vaultAfter)).to.be.gt(Number(vaultBefore));
      expect(Number(creatorAfter)).to.be.gt(Number(creatorBefore));
    });
  });
});