// test/BondingPair.test.ts
import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture, createToken } from "./setup";
import type { TestContext } from "./setup";
import { Contract } from "ethers";

describe("BondingPair", function () {
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
    const BondingPair = await ethers.getContractFactory("BondingPair");
    pair = BondingPair.attach(pairAddress);
  });

  describe("Initialization", function () {
    it("should set correct initial values", async function () {
      const { factory, router, assetToken } = context;

      expect(await pair.factory()).to.equal(await factory.getAddress());
      expect(await pair.router()).to.equal(await router.getAddress());
      expect(await pair.agentToken()).to.equal(await token.getAddress());
      expect(await pair.assetToken()).to.equal(await assetToken.getAddress());
      expect(await pair.K()).to.equal(await factory.K());
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

    describe("Buying Agent Tokens", function () {
      it("should calculate correct output amount for asset input", async function () {
        const assetAmountIn = ethers.parseEther("1");
        const expectedAgentOut = await pair.getAgentAmountOut(assetAmountIn);
        expect(Number(expectedAgentOut)).to.be.gt(0);
      });

      it("should execute buy trades correctly", async function () {
        const { router, bob, assetToken } = context;
        const assetAmountIn = ethers.parseEther("0.1");

        const initialAgentBalance = await token.balanceOf(
          await bob.getAddress()
        );
        const initialAssetBalance = await assetToken.balanceOf(
          await bob.getAddress()
        );

        // approve
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

        const finalAgentBalance = await token.balanceOf(
          await bob.getAddress()
        );
        const finalAssetBalance = await assetToken.balanceOf(
          await bob.getAddress()
        );

        expect(Number(finalAgentBalance)).to.be.gt(Number(initialAgentBalance));
        expect(Number(finalAssetBalance)).to.be.lt(Number(initialAssetBalance));
      });

      it("should update reserves after buying", async function () {
        const { router, bob, assetToken } = context;
        const assetAmountIn = ethers.parseEther("0.1");

        const [initialReserveAgent, initialReserveAsset] =
          await pair.getReserves();

        // approve
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
        expect(Number(expectedAssetOut)).to.be.gt(0);
      });

      it("should execute sell trades correctly", async function () {
        const { router, alice, assetToken } = context;
        const agentAmountIn = ethers.parseEther("0.1");

        const initialAgentBalance = await token.balanceOf(
          await alice.getAddress()
        );
        const initialAssetBalance = await assetToken.balanceOf(
          await alice.getAddress()
        );

        // approve
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

        const finalAgentBalance = await token.balanceOf(
          await alice.getAddress()
        );
        const finalAssetBalance = await assetToken.balanceOf(
          await alice.getAddress()
        );

        expect(Number(finalAgentBalance)).to.be.lt(Number(initialAgentBalance));
        expect(Number(finalAssetBalance)).to.be.gt(Number(initialAssetBalance));
      });

      it("should update reserves after selling", async function () {
        const { router, alice, assetToken } = context;
        const agentAmountIn = ethers.parseEther("0.1");

        const [initialReserveAgent, initialReserveAsset] =
          await pair.getReserves();

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

        // Use getAssetAmountIn to calculate required asset tokens (if such a function exists)
        // For now, we'll estimate with a larger amount to ensure we hit threshold
        const assetAmountIn = ethers.parseEther("1000000"); // Large enough to trigger graduation

        // owner set max holding to 100_000
        router.connect(owner).setMaxHold(100_000);

        // Approve asset tokens for spending
        await assetToken
          .connect(alice)
          .approve(await router.getAddress(), assetAmountIn);

        // Swap asset tokens for agent tokens
        await router.connect(alice).swapExactTokensForTokens(
          assetAmountIn,
          0, // Accept any amount of agent tokens out
          [await assetToken.getAddress(), await token.getAddress()], // Path: asset -> agent
          await alice.getAddress(),
          ethers.MaxUint256
        );

        expect(await token.hasGraduated()).to.be.true;
      });

      it("should not allow trading after graduation", async function () {
        const { router, alice, owner, assetToken } = context;

        // Use getAssetAmountIn to calculate required asset tokens (if such a function exists)
        // For now, we'll estimate with a larger amount to ensure we hit threshold
        const assetAmountIn = ethers.parseEther("1000000"); // Large enough to trigger graduation

        // owner set max holding to 100_000
        router.connect(owner).setMaxHold(100_000);

        // Approve asset tokens for spending
        await assetToken
          .connect(alice)
          .approve(await router.getAddress(), assetAmountIn);
        await router.connect(alice).swapExactTokensForTokens(
          assetAmountIn,
          0,
          [await assetToken.getAddress(), await token.getAddress()], // Path: asset -> agent
          await alice.getAddress(),
          ethers.MaxUint256
        );

        // Approve asset tokens for spending
        await assetToken
          .connect(alice)
          .approve(await router.getAddress(), ethers.parseEther("1"));

        let error;
        try {
          await router
            .connect(alice)
            .swapExactTokensForTokens(
              ethers.parseEther("1"),
              0,
              [await assetToken.getAddress(), await token.getAddress()],
              await alice.getAddress(),
              ethers.MaxUint256
            );
        } catch (e) {
          error = e;
        }

        expect(error?.message).to.include("Already graduated");
      });
    });
  });

  describe("Security", function () {
    it("should only allow router to call swap", async function () {
      const { alice } = context;

      let error;
      try {
        await pair.connect(alice).swap(ethers.parseEther("1"), 0, 0, 0);
      } catch (e) {
        error = e;
      }

      expect(error?.message).to.include("Only router");
    });
  });
});
