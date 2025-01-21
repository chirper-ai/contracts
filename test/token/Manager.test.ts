// test/Manager.test.ts
import { ethers } from "hardhat";
import { expect, loadFixture, createToken, deployFixture, RouterType } from "./helper";
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
      expect(Number(await factory.launchTax())).to.equal(5_000); // 5%
      expect(Number(await manager.initialSupply())).to.equal(1_000_000);
      expect(Number(await manager.assetRate())).to.equal(60_000);
      expect(Number(await manager.gradThresholdPercent())).to.equal(50_000);
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
      
      // before metrics
      const beforeMetrics = await manager.agentTokens(await agentToken.getAddress());
      
      // Execute a buy
      const buyAmount = ethers.parseEther("100");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      await manager.connect(bob).buy(buyAmount, await agentToken.getAddress());
      
      const metrics = await manager.agentTokens(await agentToken.getAddress());
      expect(Number(metrics.metrics.price)).to.be.gt(Number(beforeMetrics.metrics.price));
      expect(Number(metrics.metrics.marketCap)).to.be.gt(Number(beforeMetrics.metrics.marketCap));
    });

    it("should maintain constant product K after buys", async function() {
      const { manager, alice, bob, router, factory, assetToken } = context;
      
      // Launch a token
      const agentToken = await createToken(context, alice);
      
      // Get initial reserves
      const pair = await ethers.getContractAt("IBondingPair", await factory.getPair(await agentToken.getAddress(), await assetToken.getAddress()));
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
      const pair = await ethers.getContractAt("IBondingPair", await factory.getPair(await agentToken.getAddress(), await assetToken.getAddress()));
      const [reserveAgent, reserveAsset] = await pair.getReserves();
      
      // Calculate expected output using constant product formula
      const inputAmount = ethers.parseEther("100");
      // Account for buy tax (default is usually around 5%)
      const taxRate = await factory.buyTax();
      const inputAfterTax = inputAmount - (inputAmount * BigInt(taxRate)) / 100000n;
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
      const { manager, alice, owner, bob, router, factory, assetToken } = context;
      
      // Launch a token
      const agentToken = await createToken(context, alice);

      // set max trade size
      await router.connect(owner).setMaxTxPercent(100_000);
      
      // Get initial state
      const pair = await ethers.getContractAt("IBondingPair", await factory.getPair(await agentToken.getAddress(), await assetToken.getAddress()));
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
      const { manager, owner, router, alice, bob, assetToken, uniswapV2Router } = context;
      
      await manager.setGradThresholdPercent(50_000);
      await router.connect(owner).setMaxTxPercent(100_000);
      
      // Launch with DEX router
      const dexRouters = [{
        routerAddress: await uniswapV2Router.getAddress(),
        weight: 100_000,
        routerType: RouterType.UniswapV2,
        feeAmount: 0, // No fee for V2
      }];
      
      const agentToken = await createToken(context, alice, dexRouters);
      const tokenAddress = await agentToken.getAddress();
      
      // Buy enough to trigger graduation
      const buyAmount = ethers.parseEther("6000"); // 5_000 $VANA or $50,000
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      
      const buyTx = await manager.connect(bob).buy(buyAmount, tokenAddress);
      await buyTx.wait();
    
      // Wait a bit to ensure state is updated
      await ethers.provider.send("evm_mine", []);
    
      // Get token data after graduation
      const dexPools = await manager.getDexPools(tokenAddress);
    
      return {
        agentToken,
        dexRouters,
        dexPools
      };
    }

    it("should graduate token when threshold reached", async function() {
      const { manager, owner, router, alice, bob, assetToken } = context;

      // set max trade size
      await router.connect(owner).setMaxTxPercent(100_000);
      
      await manager.setGradThresholdPercent(50_000);
      const agentToken = await createToken(context, alice);
      const tokenAddress = await agentToken.getAddress();
      
      const buyAmount = ethers.parseEther("6000");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      
      const tx = await manager.connect(bob).buy(buyAmount, tokenAddress);
      const receipt = await tx.wait();
      
      // Check for graduation event
      const graduatedEvent = receipt.logs.find(log => log.fragment?.name === "Graduated");
      expect(graduatedEvent).to.not.be.undefined;
      
      // Verify token state
      const tokenInfo = await manager.agentTokens(tokenAddress);
      const dexPools = await manager.getDexPools(tokenAddress);
      
      expect(tokenInfo.hasGraduated).to.be.true;
      expect(tokenInfo.isTrading).to.be.false;
      expect(dexPools.length).to.be.gt(0); // Should have at least one DEX pair
    });

    it("should migrate liquidity to multiple DEXes correctly", async function() {
      const { assetToken } = context;
      const { agentToken, dexPools } = await graduateToken(context);
      const tokenAddress = await agentToken.getAddress();

      // Check each DEX pair
      for (const pairAddress of dexPools) {
        const pair = await ethers.getContractAt("IUniswapV2Pair", pairAddress);
        
        // Get initial reserves
        const [reserve0, reserve1] = await pair.getReserves();
        expect(Number(reserve0)).to.be.gt(0);
        expect(Number(reserve1)).to.be.gt(0);

        // Get the tokens in the pair
        const token0 = await pair.token0();
        const token1 = await pair.token1();

        // Check pair has correct tokens
        expect(
          (token0.toLowerCase() === tokenAddress.toLowerCase() &&
           token1.toLowerCase() === (await assetToken.getAddress()).toLowerCase()) ||
          (token1.toLowerCase() === tokenAddress.toLowerCase() &&
           token0.toLowerCase() === (await assetToken.getAddress()).toLowerCase())
        ).to.be.true;

        // Verify constant product formula
        const k = BigInt(reserve0) * BigInt(reserve1);
        expect(Number(k)).to.be.gt(0);
      }
    });

    it("should distribute liquidity according to weights", async function() {
      const { agentToken, dexRouters, dexPools } = await graduateToken(context);
      
      // Calculate total TVL across all pools
      let totalTVL = 0n;
      const poolTVLs = [];
      
      for (const poolAddress of dexPools) {
        const pair = await ethers.getContractAt("IUniswapV2Pair", poolAddress);
        const [reserve0, reserve1] = await pair.getReserves();
        const tvl = reserve0 * reserve1;
        poolTVLs.push(tvl);
        totalTVL += tvl;
      }
      
      // Verify each pool's TVL matches its weight within 5% tolerance
      for (let i = 0; i < dexPools.length; i++) {
        const actualRatio = (poolTVLs[i] * 100_000n) / totalTVL;
        const expectedWeight = BigInt(dexRouters[i].weight);
        
        // Allow 5% tolerance (5000 = 5%)
        const tolerance = 5_000n;
        const lowerBound = expectedWeight - tolerance;
        const upperBound = expectedWeight + tolerance;
        
        expect(Number(actualRatio)).to.be.within(
          Number(lowerBound),
          Number(upperBound),
          `Pool ${i} liquidity ratio (${actualRatio}) does not match weight (${expectedWeight})`
        );
      }
    });
  });

  describe("Graduation with Uniswap V3", function() {
    async function graduateTokenToV3(context: TestContext) {
      const { manager, owner, router, alice, bob, assetToken, nftPositionManager } = context;
      
      await manager.setGradThresholdPercent(50_000);
      await router.connect(owner).setMaxTxPercent(100_000);
      
      // Launch with V3 DEX router
      const dexRouters = [{
        routerAddress: await nftPositionManager.getAddress(),
        weight: 100_000,
        routerType: RouterType.UniswapV3,
        feeAmount: 3000, // 0.03% fee for V3
      }];
      
      const agentToken = await createToken(context, alice, dexRouters);
      const tokenAddress = await agentToken.getAddress();
      
      // Buy enough to trigger graduation
      const buyAmount = ethers.parseEther("6000"); // $60,000
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      
      const buyTx = await manager.connect(bob).buy(buyAmount, tokenAddress);
      await buyTx.wait();
    
      // Wait for state update
      await ethers.provider.send("evm_mine", []);
    
      // Get token data after graduation
      const dexPools = await manager.getDexPools(tokenAddress);
    
      return {
        agentToken,
        dexRouters,
        dexPools
      };
    }
  
    it("should graduate token to Uniswap V3 pool", async function() {
      const { manager, owner, router, alice, bob, assetToken, uniswapV3Factory } = context;
  
      // set max trade size
      await router.connect(owner).setMaxTxPercent(100_000);
      
      await manager.setGradThresholdPercent(50_000);
      
      // Launch with V3 router
      const dexRouters = [{
        routerAddress: await context.uniswapV3Router.getAddress(),
        weight: 100_000,
        routerType: RouterType.UniswapV3,
        feeAmount: 3000, // 0.03% fee for V3
      }];
      
      const agentToken = await createToken(context, alice, dexRouters);
      const tokenAddress = await agentToken.getAddress();
      
      const buyAmount = ethers.parseEther("6000");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      
      const tx = await manager.connect(bob).buy(buyAmount, tokenAddress);
      const receipt = await tx.wait();
      
      // Check for graduation event
      const graduatedEvent = receipt.logs.find(log => log.fragment?.name === "Graduated");
      expect(graduatedEvent).to.not.be.undefined;
      
      // Verify token state
      const tokenInfo = await manager.agentTokens(tokenAddress);
      const dexPools = await manager.getDexPools(tokenAddress);
      
      expect(tokenInfo.hasGraduated).to.be.true;
      expect(tokenInfo.isTrading).to.be.false;
      expect(dexPools.length).to.be.gt(0);
  
      // Verify V3 pool creation
      const poolAddress = await uniswapV3Factory.getPool(
        tokenAddress,
        await assetToken.getAddress(),
        100
      );
      expect(poolAddress).to.not.equal(ethers.ZeroAddress);
    });
  
    it("should initialize V3 pool with correct liquidity ranges", async function() {
      const { assetToken, uniswapV3Factory, nftPositionManager } = context;
      const { agentToken, dexPools } = await graduateTokenToV3(context);
      const tokenAddress = await agentToken.getAddress();
  
      // Get the V3 pool
      const poolAddress = await uniswapV3Factory.getPool(
        tokenAddress,
        await assetToken.getAddress(),
        100
      );
      const pool = await ethers.getContractAt("IUniswapV3Pool", poolAddress);
  
      // Check pool initialization
      const slot0 = await pool.slot0();
      expect(slot0.sqrtPriceX96).to.not.equal(0);
      expect(slot0.tick).to.not.equal(0);
  
      // Check liquidity
      const liquidity = await pool.liquidity();
      expect(liquidity).to.be.gt(0);
  
      // Verify position through NFT manager
      const positions = await nftPositionManager.positions(1); // First position
      expect(positions.liquidity).to.be.gt(0);
      
      // Verify tick ranges 
      // Assuming default range of ±10% around current price
      const currentTick = slot0.tick;
      expect(positions.tickLower).to.be.lt(currentTick);
      expect(positions.tickUpper).to.be.gt(currentTick);
    });
  
    it("should distribute V3 liquidity effectively across price ranges", async function() {
      const { assetToken, uniswapV3Factory } = context;
      const { agentToken } = await graduateTokenToV3(context);
      const tokenAddress = await agentToken.getAddress();
  
      const pool = await ethers.getContractAt(
        "IUniswapV3Pool",
        await uniswapV3Factory.getPool(
          tokenAddress,
          await assetToken.getAddress(),
          100
        )
      );
  
      // Get current price and liquidity
      const slot0 = await pool.slot0();
      const basePrice = slot0.sqrtPriceX96;
      
      // Check liquidity distribution around current price
      const tickSpacing = await pool.tickSpacing();
      const currentTick = slot0.tick;
      
      // Sample liquidity at different tick ranges
      const ranges = [-2, -1, 0, 1, 2].map(i => currentTick + (i * tickSpacing));
      
      let previousLiquidity = 0n;
      for (const tick of ranges) {
        const liquidityNet = await pool.ticks(tick);
        // Ensure we have some liquidity changes at different ticks
        expect(liquidityNet).to.not.equal(previousLiquidity);
        previousLiquidity = liquidityNet;
      }
    });
  
    it("should migrate to both V2 and V3 pools during graduation", async function() {
      const { manager, owner, router, alice, bob, assetToken, uniswapV2Router, uniswapV3Router, uniswapV2Factory, uniswapV3Factory } = context;
      
      await manager.setGradThresholdPercent(50_000);
      await router.connect(owner).setMaxTxPercent(100_000);
      
      // Launch with both V2 and V3 routers
      const dexRouters = [
        {
          routerAddress: await uniswapV2Router.getAddress(),
          weight: 50_000,
          routerType: RouterType.UniswapV2,
          feeAmount: 0, // No fee for V2
        },
        {
          routerAddress: await uniswapV3Router.getAddress(),
          weight: 50_000,
          routerType: RouterType.UniswapV3,
          feeAmount: 3000, // 0.03% fee for V3
        }
      ];
      
      const agentToken = await createToken(context, alice, dexRouters);
      const tokenAddress = await agentToken.getAddress();
      
      // Trigger graduation
      const buyAmount = ethers.parseEther("6000");
      await assetToken.connect(bob).approve(await router.getAddress(), buyAmount);
      await manager.connect(bob).buy(buyAmount, tokenAddress);
      
      // Check V2 pool
      const v2PairAddress = await uniswapV2Factory.getPair(
        tokenAddress,
        await assetToken.getAddress()
      );
      expect(v2PairAddress).to.not.equal(ethers.ZeroAddress);
      
      const v2Pair = await ethers.getContractAt("IUniswapV2Pair", v2PairAddress);
      const [v2Reserve0, v2Reserve1] = await v2Pair.getReserves();
      expect(v2Reserve0).to.be.gt(0);
      expect(v2Reserve1).to.be.gt(0);
      
      // Check V3 pool
      const v3PoolAddress = await uniswapV3Factory.getPool(
        tokenAddress,
        await assetToken.getAddress(),
        100
      );
      expect(v3PoolAddress).to.not.equal(ethers.ZeroAddress);
      
      const v3Pool = await ethers.getContractAt("IUniswapV3Pool", v3PoolAddress);
      const v3Liquidity = await v3Pool.liquidity();
      expect(v3Liquidity).to.be.gt(0);
      
      // Verify proportional liquidity distribution
      const v2TVL = v2Reserve0 * v2Reserve1;
      const slot0 = await v3Pool.slot0();
      const v3TVL = v3Liquidity * (slot0.sqrtPriceX96 ** 2n);
      
      // Check if TVL split is roughly 50/50 (within 10% tolerance)
      const totalTVL = v2TVL + v3TVL;
      const v2Ratio = (v2TVL * 100_000n) / totalTVL;
      expect(Number(v2Ratio)).to.be.within(45_000, 55_000);
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