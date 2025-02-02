import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture, createToken } from "./setup";
import type { TestContext } from "./setup";
import { Contract } from "ethers";

describe("Token", function () {
  let context: TestContext;
  let token: Contract;

  beforeEach(async function () {
    context = await loadFixture(deployFixture);
    token = await createToken(context, context.alice);

    // Setup for token trading
    const { router, owner, assetToken } = context;

    // set max holding to 100
    await router.connect(owner).setMaxHold(100_000);

    await assetToken
      .connect(context.alice)
      .approve(await router.getAddress(), ethers.MaxUint256);

    // Buy some tokens to start with
    const assetAmountIn = ethers.parseEther("0.1");
    await router
      .connect(context.alice)
      .swapExactTokensForTokens(
        assetAmountIn,
        0,
        [await assetToken.getAddress(), await token.getAddress()],
        await context.alice.getAddress(),
        ethers.MaxUint256
      );
  });

  describe("Initialization", function () {
    it("should set correct initial values", async function () {
      expect(await token.name()).to.equal("Test Agent");
      expect(await token.symbol()).to.equal("TEST");
      expect(await token.url()).to.equal("https://test.com");
      expect(await token.intention()).to.equal("Test intention");
      expect(await token.hasGraduated()).to.be.false;
    });
  });

  describe("Graduation", function () {
    it("should properly graduate token", async function () {
      const { router, alice, assetToken } = context;
      const assetAmountIn = ethers.parseEther("1000000");

      await assetToken
        .connect(alice)
        .approve(await router.getAddress(), assetAmountIn);

      await router
        .connect(alice)
        .swapExactTokensForTokens(
          assetAmountIn,
          0,
          [await assetToken.getAddress(), await token.getAddress()],
          await alice.getAddress(),
          ethers.MaxUint256
        );

      expect(await token.hasGraduated()).to.be.true;
    });

    it("should prevent non-manager from graduating", async function () {
      const pools = [
        await context.alice.getAddress(),
        await context.bob.getAddress(),
      ];

      let error;
      try {
        await token.connect(context.bob).graduate(pools);
      } catch (e) {
        error = e;
      }
      expect(error?.message).to.not.be.undefined;
    });
  });
});
