// test/Manager.test.ts
import { ethers } from "hardhat";
import { expect, loadFixture, createToken, deployFixture } from "./helper";
import type { TestContext } from "./helper";

describe("Manager", function() {
  let context: TestContext;

  beforeEach(async function() {
    context = await loadFixture(deployFixture);
  });

  describe("Initialization", function() {
    it("should set correct initial values", async function() {
      const { manager, factory, router } = context;
      
      expect(await manager.factory()).to.equal(await factory.getAddress());
      expect(await manager.router()).to.equal(await router.getAddress());
      // Launch fee is now handled by factory
      expect(Number(await factory.launchTax())).to.equal(500); // 5%
      expect(Number(await manager.initialSupply())).to.equal(1_000_000);
      expect(Number(await manager.assetRate())).to.equal(10_000);
      expect(Number(await manager.gradThresholdPercent())).to.equal(50);
    });

    it("should have correct owner", async function() {
      const { manager, owner } = context;
      expect(await manager.owner()).to.equal(await owner.getAddress());
    });
  });

  describe("Trading Operations", function() {
    it("should execute buy correctly", async function() {
      const { manager, alice, bob, router, assetToken } = context;
    
      // Launch a token first
      const agentToken = await createToken(context, alice);
    
      // Bob approves the Manager to spend tokens
      const buyAmount = ethers.parseEther("100");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
    
      // Execute the buy operation
      const beforeBalance = await agentToken.balanceOf(bob.getAddress());
      await manager.connect(bob).buy(buyAmount, agentToken.getAddress());
      const afterBalance = await agentToken.balanceOf(bob.getAddress());
    
      // Verify the buyer received tokens
      expect(Number(afterBalance)).to.be.gt(Number(beforeBalance));
    });

    it("should execute sell correctly", async function () {
      const { manager, alice, bob, router, assetToken } = context;
    
      // Launch token and buy some first
      const agentToken = await createToken(context, alice);
    
      // Approve and buy tokens
      const buyAmount = ethers.parseEther("100");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      await manager.connect(bob).buy(buyAmount, agentToken.getAddress());
    
      // Approve and sell tokens
      const sellAmount = await agentToken.balanceOf(bob.getAddress());
      await agentToken.connect(bob).approve(await router.getAddress(), sellAmount);
    
      const beforeBalance = await assetToken.balanceOf(bob.getAddress());
      await manager.connect(bob).sell(sellAmount, agentToken.getAddress());
      const afterBalance = await assetToken.balanceOf(bob.getAddress());
    
      // Verify the seller received funds
      expect(Number(afterBalance)).to.be.gt(Number(beforeBalance));
    });

    it("should update metrics after trades", async function() {
      const { manager, alice, bob, router, assetToken } = context;
      
      const agentToken = await createToken(context, alice);
      
      // Execute a buy
      const buyAmount = ethers.parseEther("100");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      await manager.connect(bob).buy(buyAmount, await agentToken.getAddress());
      
      const metrics = await manager.agentTokens(await agentToken.getAddress());
      expect(Number(metrics.metrics.vol)).to.be.gt(Number(0));
      expect(Number(metrics.metrics.vol24h)).to.be.gt(Number(0));
    });

    it("should maintain constant product K after buys", async function() {
      const { manager, alice, bob, router, factory, assetToken } = context;
      
      // Launch a token
      const agentToken = await createToken(context, alice);
      
      // Get initial reserves
      const pair = await ethers.getContractAt("IPair", await factory.getPair(await agentToken.getAddress(), await assetToken.getAddress()));
      const [initialReserveAgent, initialReserveAsset] = await pair.getReserves();
      const initialK = initialReserveAgent * initialReserveAsset;
      
      // Execute a buy
      const buyAmount = ethers.parseEther("100");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      await manager.connect(bob).buy(buyAmount, await agentToken.getAddress());
      
      // Check reserves after buy
      const [newReserveAgent, newReserveAsset] = await pair.getReserves();
      const newK = newReserveAgent * newReserveAsset;
      
      // Allow for small rounding differences (0.1% tolerance)
      const tolerance = initialK / 1000n;
      expect(Number(newK)).to.be.closeTo(Number(initialK), Number(tolerance));
    });

    it("should calculate correct output amounts based on constant product formula", async function() {
      const { manager, alice, bob, router, factory, assetToken } = context;
      
      // Launch a token
      const agentToken = await createToken(context, alice);
      
      // Get initial reserves
      const pair = await ethers.getContractAt("IPair", await factory.getPair(await agentToken.getAddress(), await assetToken.getAddress()));
      const [reserveAgent, reserveAsset] = await pair.getReserves();
      
      // Calculate expected output using constant product formula
      const inputAmount = ethers.parseEther("100");
      // Account for buy tax (default is usually around 5%)
      const taxRate = await factory.buyTax();
      const inputAfterTax = inputAmount - (inputAmount * BigInt(taxRate)) / 10000n;
      const expectedOutput = (reserveAgent * inputAfterTax) / (reserveAsset + inputAfterTax);
      
      // Execute the buy
      await assetToken.connect(bob).approve(await router.getAddress(), inputAmount);
      await manager.connect(bob).buy(inputAmount, await agentToken.getAddress());
      
      // Check actual received amount
      const actualOutput = await agentToken.balanceOf(bob.getAddress());
      
      // Allow for tax deductions and small rounding differences (2% tolerance)
      const tolerance = expectedOutput * 2n / 100n;
      expect(Number(actualOutput)).to.be.closeTo(Number(expectedOutput), Number(tolerance));
    });

    it("should maintain price impact proportional to trade size", async function() {
      const { manager, alice, bob, router, factory, assetToken } = context;
      
      // Launch a token
      const agentToken = await createToken(context, alice);
      
      // Get initial state
      const pair = await ethers.getContractAt("IPair", await factory.getPair(await agentToken.getAddress(), await assetToken.getAddress()));
      const [initialReserveAgent, initialReserveAsset] = await pair.getReserves();
      
      // Calculate initial price properly scaled
      const initialPrice = (initialReserveAsset * BigInt(1e18)) / initialReserveAgent;
      
      // Execute a small buy
      const smallBuy = ethers.parseEther("10");
      await assetToken.connect(bob).approve(await router.getAddress(), smallBuy);
      await manager.connect(bob).buy(smallBuy, await agentToken.getAddress());
      
      // Get price after small buy
      const [reserveAgent1, reserveAsset1] = await pair.getReserves();
      const priceAfterSmallBuy = (reserveAsset1 * BigInt(1e18)) / reserveAgent1;
      
      // Execute a large buy (100x larger)
      const largeBuy = ethers.parseEther("1000");
      await assetToken.connect(bob).approve(await router.getAddress(), largeBuy);
      await manager.connect(bob).buy(largeBuy, await agentToken.getAddress());
      
      // Get price after large buy
      const [reserveAgent2, reserveAsset2] = await pair.getReserves();
      const priceAfterLargeBuy = (reserveAsset2 * BigInt(1e18)) / reserveAgent2;
      
      // Calculate relative price changes
      const smallBuyImpact = ((priceAfterSmallBuy - initialPrice) * BigInt(10000)) / initialPrice;
      const largeBuyImpact = ((priceAfterLargeBuy - priceAfterSmallBuy) * BigInt(10000)) / priceAfterSmallBuy;
      
      // Large buy should have significantly more impact
      expect(Number(largeBuyImpact)).to.be.gt(Number(smallBuyImpact));
    });
  });

  describe("Graduation", function() {
    async function graduateToken(context: TestContext) {
      const { manager, router, alice, bob, assetToken } = context;
      
      // Set a low graduation threshold for testing
      await manager.setGradThresholdPercent(50);
      
      const agentToken = await createToken(context, alice);
      
      // Buy enough to trigger graduation
      const buyAmount = ethers.parseEther("10000000");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      await manager.connect(bob).buy(buyAmount, await agentToken.getAddress());

      // Get Uniswap Router after graduation
      const uniswapRouter = await ethers.getContractAt(
        "IUniswapV2Router02",
        await manager.uniswapRouter()
      );

      // Get Uniswap pair
      const factory = await ethers.getContractAt(
        "IUniswapV2Factory",
        await uniswapRouter.factory()
      );
      const uniswapPair = await factory.getPair(
        await agentToken.getAddress(),
        await assetToken.getAddress()
      );

      return {
        agentToken,
        uniswapRouter,
        uniswapPair
      };
    }

    it("should graduate token when threshold reached", async function() {
      const { manager, router, alice, bob, assetToken } = context;
      
      await manager.setGradThresholdPercent(50);
      const agentToken = await createToken(context, alice);
      
      const buyAmount = ethers.parseEther("10000000");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      
      const tx = await manager.connect(bob).buy(buyAmount, await agentToken.getAddress());
      const receipt = await tx.wait();
      
      // Check for graduation event
      const graduatedEvent = receipt.logs.find(log => log.fragment?.name === "Graduated");
      expect(graduatedEvent).to.not.be.undefined;
      
      // Verify token state
      const tokenInfo = await manager.agentTokens(await agentToken.getAddress());
      expect(tokenInfo.hasGraduated).to.be.true;
      expect(tokenInfo.isTrading).to.be.false;
    });

    it("should migrate liquidity to Uniswap correctly", async function() {
      const { manager, assetToken } = context;
      const { agentToken, uniswapPair } = await graduateToken(context);

      const pair = await ethers.getContractAt("IUniswapV2Pair", uniswapPair);
      
      // Get initial reserves
      const [reserve0, reserve1] = await pair.getReserves();
      expect(Number(reserve0)).to.be.gt(0);
      expect(Number(reserve1)).to.be.gt(0);

      // Get the tokens in the pair
      const token0 = await pair.token0();
      const token1 = await pair.token1();

      // Check Uniswap pair has correct tokens
      expect(
        (token0.toLowerCase() === (await agentToken.getAddress()).toLowerCase() &&
         token1.toLowerCase() === (await assetToken.getAddress()).toLowerCase()) ||
        (token1.toLowerCase() === (await agentToken.getAddress()).toLowerCase() &&
         token0.toLowerCase() === (await assetToken.getAddress()).toLowerCase())
      ).to.be.true;

      // Verify pool has liquidity
      const liquidityBalance = await pair.balanceOf(await manager.getAddress());
      expect(Number(liquidityBalance)).to.be.equal(0);

      // Verify constant product formula
      const k = BigInt(reserve0) * BigInt(reserve1);
      expect(Number(k)).to.be.gt(0);
    });

    it("should prevent router trading after graduation", async function() {
      const { manager, router, alice, bob, assetToken } = context;
      
      await manager.setGradThresholdPercent(50);
      const agentToken = await createToken(context, alice);
      
      const buyAmount = ethers.parseEther("10000000");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      await manager.connect(bob).buy(buyAmount, await agentToken.getAddress());
      
      // Verify token is graduated
      const tokenInfo = await manager.agentTokens(await agentToken.getAddress());
      expect(tokenInfo.hasGraduated).to.be.true;
      
      // Attempt to buy through router should fail
      const secondBuyAmount = ethers.parseEther("100");
      await assetToken.connect(bob).approve(await router.getAddress(), secondBuyAmount);
      
      let failed = false;
      try {
        await manager.connect(bob).buy(secondBuyAmount, await agentToken.getAddress());
      } catch (e) {
        failed = true;
      }
      expect(failed).to.be.true;
      
      // Attempt to sell through router should fail
      const sellAmount = ethers.parseEther("100");
      await agentToken.connect(bob).approve(await router.getAddress(), sellAmount);
      
      failed = false;
      try {
        await manager.connect(bob).sell(sellAmount, await agentToken.getAddress());
      } catch (e) {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });

  describe("Admin Functions", function() {
    it("should update initial supply correctly", async function() {
      const { manager, owner } = context;
      
      const newSupply = 2_000_000;
      await manager.connect(owner).setInitialSupply(newSupply);
      
      expect(Number(await manager.initialSupply())).to.equal(newSupply);
    });

    it("should update graduation threshold correctly", async function() {
      const { manager, owner } = context;
      
      const newThreshold = 100;
      await manager.connect(owner).setGradThresholdPercent(newThreshold);
      
      expect(Number(await manager.gradThresholdPercent())).to.equal(Number(newThreshold));
    });
  });
});