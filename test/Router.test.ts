import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture, createToken } from "./setup";
import type { TestContext } from "./setup";
import { Contract } from "ethers";

/**
 * Test suite for the Router contract
 * 
 * Tests cover:
 * - Contract initialization
 * - Swapping functionality (both buying and selling)
 * - Price calculations
 * - Liquidity management
 * - Maximum holding limits
 * - Tax handling and distribution
 */
describe("Router", function () {
  let context: TestContext;
  let token: Contract;
  let pair: Contract;

  // Set up fresh contracts before each test
  beforeEach(async function () {
    // Deploy fresh contracts
    context = await loadFixture(deployFixture);

    // Create a new test token and get its trading pair
    token = await createToken(context, context.alice);
    const pairAddress = await context.factory.getPair(
      await token.getAddress(),
      await context.assetToken.getAddress()
    );
    const Pair = await ethers.getContractFactory("Pair");
    pair = Pair.attach(pairAddress);
  });

  /**
   * Tests for contract initialization
   * Verifies that the router is properly initialized with correct parameters
   */
  describe("Initialization", function () {
    it("should initialize with correct parameters", async function () {
      const { router, factory, assetToken } = context;

      expect(await router.factory()).to.equal(await factory.getAddress());
      expect(await router.assetToken()).to.equal(await assetToken.getAddress());
      expect(Number(await router.maxHold())).to.be.gt(0);
    });
  });

  /**
   * Tests for core swap functionality
   * Covers both buying and selling tokens through the router
   */
  describe("Swap Functions", function () {
    beforeEach(async function () {
      const { router, alice, bob, assetToken } = context;

      // Set up token approvals
      await token
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await assetToken
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await token
        .connect(bob)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await assetToken
        .connect(bob)
        .approve(await router.getAddress(), ethers.MaxUint256);
    });

    it("should execute swapExactTokensForTokens for buying", async function () {
      const { router, alice, bob, assetToken } = context;
      const amountIn = ethers.parseEther("0.01");

      const balanceBefore = await token.balanceOf(await bob.getAddress());

      await router
        .connect(bob)
        .swapExactTokensForTokens(
          amountIn,
          0,
          [await assetToken.getAddress(), await token.getAddress()],
          await bob.getAddress(),
          ethers.MaxUint256
        );

      expect(await token.balanceOf(await bob.getAddress())).to.be.gt(
        balanceBefore
      );
    });

    it("should execute swapTokensForExactTokens for selling", async function () {
      const { router, alice, assetToken } = context;
      const amountOut = ethers.parseEther("0.01");
      
      const aliceAddress = await alice.getAddress();
      const assetBalanceBefore = await assetToken.balanceOf(aliceAddress);
    
      await router
        .connect(alice)
        .swapTokensForExactTokens(
          amountOut,
          ethers.MaxUint256,
          [await token.getAddress(), await assetToken.getAddress()],
          aliceAddress,
          ethers.MaxUint256
        );

      const assetBalanceAfter = await assetToken.balanceOf(aliceAddress);
      expect(Number(assetBalanceAfter)).to.be.gt(Number(assetBalanceBefore));
    });

    it("should revert if deadline has passed", async function () {
      const { router, bob, assetToken } = context;
      const amountIn = ethers.parseEther("0.01");
      const pastDeadline = Math.floor(Date.now() / 1000) - 1; // 1 second ago

      await expect(
        router
          .connect(bob)
          .swapExactTokensForTokens(
            amountIn,
            0,
            [await assetToken.getAddress(), await token.getAddress()],
            await bob.getAddress(),
            pastDeadline
          )
      ).to.be.revertedWith("Expired");
    });

    it("should revert with invalid path length", async function () {
      const { router, bob, assetToken } = context;
      const amountIn = ethers.parseEther("0.01");

      await expect(
        router
          .connect(bob)
          .swapExactTokensForTokens(
            amountIn,
            0,
            [await assetToken.getAddress()], // Invalid path length
            await bob.getAddress(),
            ethers.MaxUint256
          )
      ).to.be.revertedWith("Invalid path");
    });
  });

  /**
   * Tests for price calculation functionality
   * Verifies that the router correctly calculates amounts for swaps
   */
  describe("Price Calculation", function () {
    it("should calculate correct amounts out", async function () {
      const { router, assetToken } = context;
      const amountIn = ethers.parseEther("100");

      const amounts = await router.getAmountsOut(amountIn, [
        await assetToken.getAddress(),
        await token.getAddress(),
      ]);

      expect(amounts[0]).to.equal(amountIn);
      expect(Number(amounts[1])).to.be.gt(0);
    });

    it("should calculate correct amounts in", async function () {
      const { router, assetToken } = context;
      const amountOut = ethers.parseEther("10");

      const amounts = await router.getAmountsIn(amountOut, [
        await assetToken.getAddress(),
        await token.getAddress(),
      ]);

      expect(amounts[1]).to.equal(amountOut);
      expect(Number(amounts[0])).to.be.gt(0);
    });

    it("should revert getAmountsOut with invalid path", async function () {
      const { router, assetToken } = context;
      const amountIn = ethers.parseEther("100");

      await expect(
        router.getAmountsOut(amountIn, [await assetToken.getAddress()])
      ).to.be.revertedWith("Invalid path");
    });

    it("should revert getAmountsIn with invalid path", async function () {
      const { router, assetToken } = context;
      const amountOut = ethers.parseEther("10");

      await expect(
        router.getAmountsIn(amountOut, [await assetToken.getAddress()])
      ).to.be.revertedWith("Invalid path");
    });
  });

  /**
   * Tests for liquidity management functionality
   * Covers initial liquidity addition and transfers to manager
   */
  describe("Liquidity Management", function () {
    it("should add initial liquidity correctly", async function () {
      const { router, factory, alice, assetToken } = context;
      const newToken = await createToken(context, alice);

      await expect(
        router
          .connect(alice)
          .addInitialLiquidity(
            await newToken.getAddress(),
            await assetToken.getAddress(),
            ethers.parseEther("1000"),
            ethers.parseEther("1000")
          )
      ).to.be.revertedWith("only factory");
    });

    it("should handle liquidity transfer to manager", async function () {
      const { router, manager, alice } = context;

      await expect(
        router
          .connect(alice)
          .transferLiquidityToManager(
            await token.getAddress(),
            ethers.parseEther("100"),
            ethers.parseEther("100")
          )
      ).to.be.revertedWith("Only manager");
    });
  });

  /**
   * Tests for maximum holding limit functionality
   * Verifies that the router enforces holding limits correctly
   */
  describe("Max Hold", function () {
    beforeEach(async function () {
      const { router, alice, bob, assetToken } = context;

      // Set up approvals
      await token
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await token
        .connect(bob)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await assetToken
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await assetToken
        .connect(bob)
        .approve(await router.getAddress(), ethers.MaxUint256);
    });

    it("should enforce max hold on subsequent buys", async function () {
      const { router, bob, assetToken } = context;
      const largeAmount = ethers.parseEther("1000000");

      await expect(
        router
          .connect(bob)
          .swapExactTokensForTokens(
            largeAmount,
            0,
            [await assetToken.getAddress(), await token.getAddress()],
            await bob.getAddress(),
            ethers.MaxUint256
          )
      ).to.be.revertedWith("Exceeds max holding");
    });

    it("should allow selling regardless of max hold", async function () {
      const { router, alice, assetToken } = context;
      const agentBalance = await token.balanceOf(await alice.getAddress());

      await router
        .connect(alice)
        .swapExactTokensForTokens(
          agentBalance,
          0,
          [await token.getAddress(), await assetToken.getAddress()],
          await alice.getAddress(),
          ethers.MaxUint256
        );

      expect(Number(await token.balanceOf(await alice.getAddress()))).to.be.lt(
        Number(agentBalance)
      );
    });

    it("should enforce max hold in swapTokensForExactTokens", async function () {
      const { router, owner, alice, assetToken } = context;
      const largeAmount = ethers.parseEther(`${10_000_000}`);
      
      await router.connect(owner).setMaxHold(500);

      await expect(
        router
          .connect(alice)
          .swapTokensForExactTokens(
            largeAmount,
            ethers.MaxUint256,
            [await assetToken.getAddress(), await token.getAddress()],
            await alice.getAddress(),
            ethers.MaxUint256
          )
      ).to.be.revertedWith("Exceeds max holding");
    });

    it("should update max hold limit correctly", async function () {
      const { router, owner } = context;
      const newMaxHold = 5_000;

      await router.connect(owner).setMaxHold(newMaxHold);
      expect(Number(await router.maxHold())).to.equal(newMaxHold);
    });

    it("should revert if non-admin tries to update max hold", async function () {
      const { router, alice } = context;
      const newMaxHold = 5_000;

      let error;
      try {
        await router.connect(alice).setMaxHold(newMaxHold)
      } catch (e) {
        error = `${e}`
      }

      await expect(error).to.include("AccessControl");
    });

    it("should revert if max hold is set to zero", async function () {
      const { router, owner } = context;

      await expect(
        router.connect(owner).setMaxHold(0)
      ).to.be.revertedWith("Invalid max hold percentage");
    });

    it("should revert if max hold exceeds basis points", async function () {
      const { router, owner } = context;
      const tooLarge = 100_001; // BASIS_POINTS is 100_000

      await expect(
        router.connect(owner).setMaxHold(tooLarge)
      ).to.be.revertedWith("Invalid max hold percentage");
    });
  });

  /**
   * Tests for tax functionality
   * Verifies tax calculation, collection, and distribution
   */
  describe("Tax Handling", function () {
    beforeEach(async function () {
      const { router, alice, bob, assetToken } = context;

      // Set up approvals
      await token
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await assetToken
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await token
        .connect(bob)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await assetToken
        .connect(bob)
        .approve(await router.getAddress(), ethers.MaxUint256);
    });

    it("should apply buy tax correctly", async function () {
      const { router, bob, assetToken, factory } = context;
      const amountIn = ethers.parseEther("1");
      
      // Get initial amounts out
      const [_, expectedAmountOut] = await router.getAmountsOut(amountIn, [
        await assetToken.getAddress(),
        await token.getAddress()
      ]);
    
      // Get platform and creator addresses
      const platformTreasury = await factory.platformTreasury();
      const creator = await token.creator();
    
      // Track initial balances
      const initialPlatformBalance = await token.balanceOf(platformTreasury);
      const initialCreatorBalance = await token.balanceOf(creator);
    
      // Execute swap
      await router
        .connect(bob)
        .swapExactTokensForTokens(
          amountIn,
          0,
          [await assetToken.getAddress(), await token.getAddress()],
          await bob.getAddress(),
          ethers.MaxUint256
        );
    
      // Check tax distribution
      const platformTax = await token.balanceOf(platformTreasury);
      const creatorTax = await token.balanceOf(creator);
      
      expect(platformTax).to.be.gt(initialPlatformBalance);
      expect(creatorTax).to.be.gt(initialCreatorBalance);
      
      // Platform and creator should get equal shares (allowing for 1 wei rounding difference)
      const platformShare = platformTax - initialPlatformBalance;
      const creatorShare = creatorTax - initialCreatorBalance;
      const difference = BigInt(platformShare - creatorShare);
      expect(difference).to.be.lte(1n, "Platform and creator shares differ by more than 1 wei");
    });

    it("should apply sell tax correctly", async function () {
      const { router, alice, assetToken, factory } = context;
      const amountIn = ethers.parseEther("1");
      
      // Get initial amounts out
      const [_, expectedAmountOut] = await router.getAmountsOut(amountIn, [
        await token.getAddress(),
        await assetToken.getAddress()
      ]);
    
      // Get platform and creator addresses
      const platformTreasury = await factory.platformTreasury();
      const creator = await token.creator();
    
      // Track initial balances
      const initialPlatformBalance = await assetToken.balanceOf(platformTreasury);
      const initialCreatorBalance = await assetToken.balanceOf(creator);
    
      // Execute swap
      await router
        .connect(alice)
        .swapExactTokensForTokens(
          amountIn,
          0,
          [await token.getAddress(), await assetToken.getAddress()],
          await alice.getAddress(),
          ethers.MaxUint256
        );
    
      // Check tax distribution
      const platformTax = await assetToken.balanceOf(platformTreasury);
      const creatorTax = await assetToken.balanceOf(creator);
      
      const platformShare = platformTax - initialPlatformBalance;
      const creatorShare = creatorTax - initialCreatorBalance - expectedAmountOut;
    
      expect(platformTax).to.be.gt(initialPlatformBalance, "Platform should receive tax");
      expect(creatorTax).to.be.gt(initialCreatorBalance, "Creator should receive tax");
      
      // Check the actual shares
      const difference = platformShare > creatorShare ? 
        platformShare - creatorShare : 
        creatorShare - platformShare;
      expect(difference).to.be.lte(1n, 
        `Tax shares differ by more than 1 wei. Platform: ${platformShare}, Creator: ${creatorShare}`
      );
    });

    it("should calculate correct amounts with buy tax", async function () {
      const { router, assetToken } = context;
      const amountIn = ethers.parseEther("1");

      const buyTax = await router.buyTax();
      const amounts = await router.getAmountsOut(amountIn, [
        await assetToken.getAddress(),
        await token.getAddress(),
      ]);

      // Get pre-tax amount through pair directly
      const pairAddress = await context.factory.getPair(
        await token.getAddress(),
        await assetToken.getAddress()
      );
      const pair = await ethers.getContractAt("Pair", pairAddress);
      const preTaxAmount = await pair.getAgentAmountOut(amountIn);

      // Calculate expected after-tax amount
      const expectedAfterTax = (preTaxAmount * (100_000n - buyTax)) / 100_000n;
      const difference = expectedAfterTax > amounts[1] ? 
      expectedAfterTax - amounts[1] : 
        amounts[1] - expectedAfterTax;
      expect(difference).to.be.lte(1n, 
        `Tax shares differ by more than 1 wei.`
      );
    });

    it("should calculate correct amounts with sell tax", async function () {
      const { router, assetToken } = context;
      const amountIn = ethers.parseEther("1");

      const sellTax = await router.sellTax();
      const amounts = await router.getAmountsOut(amountIn, [
        await token.getAddress(),
        await assetToken.getAddress(),
      ]);

      // Get pre-tax amount through pair directly
      const pairAddress = await context.factory.getPair(
        await token.getAddress(),
        await assetToken.getAddress()
      );
      const pair = await ethers.getContractAt("Pair", pairAddress);
      const preTaxAmount = await pair.getAssetAmountOut(amountIn);

      // Calculate expected after-tax amount
      const expectedAfterTax = (preTaxAmount * (100_000n - BigInt(sellTax))) / 100_000n;
      const difference = expectedAfterTax > amounts[1] ? 
        expectedAfterTax - amounts[1] : 
        amounts[1] - expectedAfterTax;
      expect(difference).to.be.lte(1n, 
        `Tax amounts differ by more than 1 wei. Expected: ${expectedAfterTax}, Got: ${amounts[1]}`
      );
    });

    it("should allow admin to update tax rates", async function () {
      const { router, owner } = context;
      const newBuyTax = 5_000; // 5%
      const newSellTax = 3_000; // 3%

      await router.connect(owner).setBuyTax(newBuyTax);
      await router.connect(owner).setSellTax(newSellTax);

      expect(await router.buyTax()).to.equal(newBuyTax);
      expect(await router.sellTax()).to.equal(newSellTax);
    });

    it("should revert if non-admin tries to update tax rates", async function () {
      const { router, alice } = context;
      const newTax = 5_000;

      let buyTaxError;
      try {
        await router.connect(alice).setBuyTax(newTax)
      } catch (e) {
        buyTaxError = `${e}`
      }

      // expect
      expect(buyTaxError).to.include("AccessControl");

      let sellTaxError;
      try {
        await router.connect(alice).setSellTax(newTax)
      } catch (e) {
        sellTaxError = `${e}`
      }

      // expect
      expect(sellTaxError).to.include("AccessControl");
    });

    it("should handle swaps with zero tax correctly", async function () {
      const { router, owner, bob, assetToken } = context;
      
      // Set taxes to zero
      await router.connect(owner).setBuyTax(0);
      await router.connect(owner).setSellTax(0);

      const amountIn = ethers.parseEther("1");
      
      // Execute swap and verify no tax was taken
      const platformTreasury = await context.factory.platformTreasury();
      const creator = await token.creator();
      
      const initialPlatformBalance = await token.balanceOf(platformTreasury);
      const initialCreatorBalance = await token.balanceOf(creator);

      await router
        .connect(bob)
        .swapExactTokensForTokens(
          amountIn,
          0,
          [await assetToken.getAddress(), await token.getAddress()],
          await bob.getAddress(),
          ethers.MaxUint256
        );

      expect(await token.balanceOf(platformTreasury)).to.equal(initialPlatformBalance);
      expect(await token.balanceOf(creator)).to.equal(initialCreatorBalance);
    });
  });
});