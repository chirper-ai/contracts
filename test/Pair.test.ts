// test/Pair.test.ts
import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture, createToken } from "./setup";
import type { TestContext } from "./setup";
import { Contract } from "ethers";

describe("Pair", function () {
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
    it("should set correct initial values", async function () {
      const { factory, router, assetToken } = context;

      expect(await pair.factory()).to.equal(await factory.getAddress());
      expect(await pair.router()).to.equal(await router.getAddress());
      expect(await pair.agentToken()).to.equal(await token.getAddress());
      expect(await pair.assetToken()).to.equal(await assetToken.getAddress());
      expect(await pair.initialReserveAsset()).to.equal(await factory.initialReserveAsset());
      expect(await pair.impactMultiplier()).to.equal(await factory.impactMultiplier());
      expect(await token.hasGraduated()).to.be.false;
    });

    it("should have correct minimum reserves", async function () {
      const [reserveAgent, reserveAsset] = await pair.getReserves();
      expect(Number(reserveAgent)).to.be.gt(Number(1000));
      expect(Number(reserveAsset)).to.be.gt(Number(1000));
    });
  });

  describe("Trading Functions", function () {
    beforeEach(async function () {
      const { assetToken, alice, router } = context;

      await token
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await assetToken
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
    });

    describe("Price Impact", function () {
      it("should demonstrate increasing price impact with larger trades", async function () {
        const smallTrade = ethers.parseEther("0.1");
        const largeTrade = ethers.parseEther("10");

        const smallTradeOutput = await pair.getAgentAmountOut(smallTrade);
        const largeTradeOutput = await pair.getAgentAmountOut(largeTrade);

        // Calculate effective rates
        const smallTradeRate = Number(smallTrade) / Number(smallTradeOutput);
        const largeTradeRate = Number(largeTrade) / Number(largeTradeOutput);

        // Large trade should have worse rate due to price impact
        expect(largeTradeRate).to.be.gt(smallTradeRate);
      });

      it("should have symmetric price impact for buys and sells accounting for tax", async function () {
        const { router, alice, assetToken } = context;
        const assetAmountIn = ethers.parseEther("10");

        // Track initial balances
        const initialAssetBalance = await assetToken.balanceOf(await alice.getAddress());
        const initialAgentBalance = await token.balanceOf(await alice.getAddress());

        // Buy tokens
        await router
          .connect(alice)
          .swapExactTokensForTokens(
            assetAmountIn,
            0,
            [await assetToken.getAddress(), await token.getAddress()],
            await alice.getAddress(),
            ethers.MaxUint256
          );

        const midAgentBalance = await token.balanceOf(await alice.getAddress());
        const midAssetBalance = await assetToken.balanceOf(await alice.getAddress());
        const agentReceived = BigInt(midAgentBalance) - BigInt(initialAgentBalance);

        // Sell tokens back
        await token
          .connect(alice)
          .approve(await router.getAddress(), agentReceived);
        
        await router
          .connect(alice)
          .swapExactTokensForTokens(
            agentReceived,
            0,
            [await token.getAddress(), await assetToken.getAddress()],
            await alice.getAddress(),
            ethers.MaxUint256
          );

        // final balance
        const finalAssetBalance = await assetToken.balanceOf(await alice.getAddress());

        // spent = initial - mid
        const assetSpent = BigInt(initialAssetBalance) - BigInt(midAssetBalance);  // Should be 10.0
        const assetReturned = BigInt(finalAssetBalance) - BigInt(midAssetBalance); // Should be ~9.8

        // difference in % between spent and returned
        const percentageDiff = Number(
          (assetSpent - assetReturned) *
          10000n / assetSpent
        ) / 100;
        
        // Allow for up to 2% difference from expected after-tax amount due to price impact
        expect(percentageDiff).to.be.lt(2);
      });
    });

    describe("Buying Agent Tokens", function () {
      it("should calculate correct output amount for asset input", async function () {
        const assetAmountIn = ethers.parseEther("1");
        const [reserveAgent] = await pair.getReserves();
        const expectedAgentOut = await pair.getAgentAmountOut(assetAmountIn);

        // Output should follow formula: agentOut = (assetIn * reserveAgent) / ((reserveAsset + initialReserveAsset) * impactMultiplier + assetIn)
        expect(Number(expectedAgentOut)).to.be.gt(0);
        expect(Number(expectedAgentOut)).to.be.lt(Number(reserveAgent)); // Can't get more than reserves
      });

      it("should execute buy trades correctly", async function () {
        const { router, bob, assetToken } = context;
        const assetAmountIn = ethers.parseEther("0.1");

        const initialAgentBalance = await token.balanceOf(await bob.getAddress());
        const initialAssetBalance = await assetToken.balanceOf(await bob.getAddress());

        await assetToken
          .connect(bob)
          .approve(await router.getAddress(), assetAmountIn);

        await router
          .connect(bob)
          .swapExactTokensForTokens(
            assetAmountIn,
            0,
            [await assetToken.getAddress(), await token.getAddress()],
            await bob.getAddress(),
            ethers.MaxUint256
          );

        const finalAgentBalance = await token.balanceOf(await bob.getAddress());
        const finalAssetBalance = await assetToken.balanceOf(await bob.getAddress());

        expect(Number(finalAgentBalance)).to.be.gt(Number(initialAgentBalance));
        expect(Number(finalAssetBalance)).to.be.lt(Number(initialAssetBalance));
      });

      it("should update reserves after buying", async function () {
        const { router, bob, assetToken } = context;
        const assetAmountIn = ethers.parseEther("0.1");

        const [initialReserveAgent, initialReserveAsset] = await pair.getReserves();

        await assetToken
          .connect(bob)
          .approve(await router.getAddress(), assetAmountIn);

        await router
          .connect(bob)
          .swapExactTokensForTokens(
            assetAmountIn,
            0,
            [await assetToken.getAddress(), await token.getAddress()],
            await bob.getAddress(),
            ethers.MaxUint256
          );

        const [finalReserveAgent, finalReserveAsset] = await pair.getReserves();

        expect(Number(finalReserveAgent)).to.be.lt(Number(initialReserveAgent));
        expect(Number(finalReserveAsset)).to.be.gt(Number(initialReserveAsset));
      });
    });

    describe("Selling Agent Tokens", function () {
      it("should calculate correct output amount for agent input", async function () {
        const agentAmountIn = ethers.parseEther("0.1");
        const expectedAssetOut = await pair.getAssetAmountOut(agentAmountIn);
        const [, reserveAsset] = await pair.getReserves();

        // Output should follow formula: assetOut = agentIn * (reserveAsset + initialReserveAsset) / (reserveAgent * impactMultiplier + agentIn)
        expect(Number(expectedAssetOut)).to.be.gt(0);
        expect(Number(expectedAssetOut)).to.be.lt(Number(reserveAsset)); // Can't get more than reserves
      });

      it("should execute sell trades correctly", async function () {
        const { router, alice, assetToken } = context;
        const agentAmountIn = ethers.parseEther("0.1");

        const initialAgentBalance = await token.balanceOf(await alice.getAddress());
        const initialAssetBalance = await assetToken.balanceOf(await alice.getAddress());

        await token
          .connect(alice)
          .approve(await router.getAddress(), agentAmountIn);

        await router
          .connect(alice)
          .swapExactTokensForTokens(
            agentAmountIn,
            0,
            [await token.getAddress(), await assetToken.getAddress()],
            await alice.getAddress(),
            ethers.MaxUint256
          );

        const finalAgentBalance = await token.balanceOf(await alice.getAddress());
        const finalAssetBalance = await assetToken.balanceOf(await alice.getAddress());

        expect(Number(finalAgentBalance)).to.be.lt(Number(initialAgentBalance));
        expect(Number(finalAssetBalance)).to.be.gt(Number(initialAssetBalance));
      });

      it("should update reserves after selling", async function () {
        const { router, alice, assetToken } = context;
        const agentAmountIn = ethers.parseEther("0.1");

        const [initialReserveAgent, initialReserveAsset] = await pair.getReserves();

        await router
          .connect(alice)
          .swapExactTokensForTokens(
            agentAmountIn,
            0,
            [await token.getAddress(), await assetToken.getAddress()],
            await alice.getAddress(),
            ethers.MaxUint256
          );

        const [finalReserveAgent, finalReserveAsset] = await pair.getReserves();

        expect(Number(finalReserveAgent)).to.be.gt(Number(initialReserveAgent));
        expect(Number(finalReserveAsset)).to.be.lt(Number(initialReserveAsset));
      });
    });

    describe("Graduation", function () {
      it("should trigger graduation at correct threshold", async function () {
        const { router, alice, owner, assetToken } = context;
        const assetAmountIn = ethers.parseEther("1000000"); // Large enough to trigger graduation

        await router.connect(owner).setMaxHold(100_000);

        await assetToken
          .connect(alice)
          .approve(await router.getAddress(), assetAmountIn);

        await router.connect(alice).swapExactTokensForTokens(
          assetAmountIn,
          0,
          [await assetToken.getAddress(), await token.getAddress()],
          await alice.getAddress(),
          ethers.MaxUint256
        );

        expect(await token.hasGraduated()).to.be.true;
      });

      it("should not allow trading after graduation", async function () {
        const { router, alice, owner, assetToken } = context;
        const assetAmountIn = ethers.parseEther("1000000");

        await router.connect(owner).setMaxHold(100_000);

        await assetToken
          .connect(alice)
          .approve(await router.getAddress(), assetAmountIn);

        await router.connect(alice).swapExactTokensForTokens(
          assetAmountIn,
          0,
          [await assetToken.getAddress(), await token.getAddress()],
          await alice.getAddress(),
          ethers.MaxUint256
        );

        await assetToken
          .connect(alice)
          .approve(await router.getAddress(), ethers.parseEther("1"));

        await expect(
          router
            .connect(alice)
            .swapExactTokensForTokens(
              ethers.parseEther("1"),
              0,
              [await assetToken.getAddress(), await token.getAddress()],
              await alice.getAddress(),
              ethers.MaxUint256
            )
        ).to.be.revertedWith("Already graduated");
      });
    });
  });

  describe("Security", function () {
    it("should only allow router to call swap", async function () {
      const { alice } = context;
      await expect(
        pair.connect(alice).swap(ethers.parseEther("1"), 0, 0, 0)
      ).to.be.revertedWith("Only router");
    });
  });
});