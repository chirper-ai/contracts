import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture, createToken } from "./setup";
import type { TestContext } from "./setup";
import { Contract } from "ethers";

describe("Router", function () {
  let context: TestContext;
  let token: Contract;
  let pair: Contract;

  beforeEach(async function () {
    context = await loadFixture(deployFixture);

    token = await createToken(context, context.alice);
    const pairAddress = await context.factory.getPair(
      await token.getAddress(),
      await context.assetToken.getAddress()
    );
    const Pair = await ethers.getContractFactory("Pair");
    pair = Pair.attach(pairAddress);
  });

  describe("Initialization", function () {
    it("should initialize with correct parameters", async function () {
      const { router, factory, assetToken } = context;

      expect(await router.factory()).to.equal(await factory.getAddress());
      expect(await router.assetToken()).to.equal(await assetToken.getAddress());
      expect(Number(await router.maxHold())).to.be.gt(0);
    });
  });

  describe("Swap Functions", function () {
    beforeEach(async function () {
      const { router, alice, bob, assetToken } = context;

      // Approve tokens
      await token
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await assetToken
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
    });

    it("should execute swapExactTokensForTokens for buying", async function () {
      const { router, alice, bob, assetToken } = context;
      const amountIn = ethers.parseEther("0.01");

      const balanceBefore = await token.balanceOf(await bob.getAddress());

      // approve tokens
      await assetToken
        .connect(bob)
        .approve(await router.getAddress(), amountIn);

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
    
      // Execute swap
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
  });

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
  });

  describe("Liquidity Management", function () {
    it("should add initial liquidity correctly", async function () {
      const { router, factory, alice, assetToken } = context;
      const newToken = await createToken(context, alice);

      // Only factory can add initial liquidity
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

      // Only manager can transfer liquidity
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

  describe("Max Hold", function () {
    beforeEach(async function () {
      const { router, alice, bob, assetToken } = context;

      // Approve tokens
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

      let error;
      try {
        await router
          .connect(bob)
          .swapExactTokensForTokens(
            largeAmount,
            0,
            [await assetToken.getAddress(), await token.getAddress()],
            await bob.getAddress(),
            ethers.MaxUint256
          );
      } catch (e) {
        error = e;
      }

      expect(error?.message).to.include("Exceeds max holding");
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

      expect(Number(await token.balanceOf(await alice.getAddress()))).to.be.lt(Number(agentBalance));
    });

    it("should enforce max hold in swapTokensForExactTokens", async function () {
      const { router, owner, alice, assetToken } = context;

      const largeAmount = ethers.parseEther(`${10_000_000}`);
      await router.connect(owner).setMaxHold(500);

      let error;
      try {
        await router
          .connect(alice)
          .swapTokensForExactTokens(
            largeAmount,
            ethers.MaxUint256,
            [await assetToken.getAddress(), await token.getAddress()],
            await alice.getAddress(),
            ethers.MaxUint256
          );
      } catch (e) {
        error = e;
      }

      expect(error?.message).to.include("Exceeds max holding");
    });

    it("should update max hold limit correctly", async function () {
      const { router, owner } = context;
      const newMaxHold = 5_000;

      await router.connect(owner).setMaxHold(newMaxHold);
      expect(Number(await router.maxHold())).to.equal(newMaxHold);
    });
  });
});
