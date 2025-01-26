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

    it("should set correct default parameters", async function () {
      expect(await token.buyTax()).to.equal(1000n);
      expect(await token.sellTax()).to.equal(1000n);
      expect(await token.isTaxExempt(await context.manager.getAddress())).to.be
        .true;
    });
  });

  describe("Tax Mechanics", function () {
    it("should correctly apply buy tax through router", async function () {
      const { router, alice, assetToken } = context;
      const assetAmountIn = ethers.parseEther("1");

      const initialAgentBalance = await token.balanceOf(
        await alice.getAddress()
      );
      await router
        .connect(alice)
        .swapExactTokensForTokens(
          assetAmountIn,
          0,
          [await assetToken.getAddress(), await token.getAddress()],
          await alice.getAddress(),
          ethers.MaxUint256
        );

      const agentReceived =
        (await token.balanceOf(await alice.getAddress())) - initialAgentBalance;
      expect(Number(agentReceived)).to.be.gt(0);
    });

    it("should correctly apply sell tax through router", async function () {
      const { router, alice, assetToken } = context;

      // First buy some tokens
      const assetAmountIn = ethers.parseEther("1");

      // approve buy
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

      // Record balances before selling
      const agentBalance = await token.balanceOf(await alice.getAddress());
      const initialAssetBalance = await assetToken.balanceOf(
        await alice.getAddress()
      );

      // Sell portion of tokens
      const agentAmountIn = agentBalance / BigInt(2);

      // approve sell
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

      const assetReceived =
        (await assetToken.balanceOf(await alice.getAddress())) -
        initialAssetBalance;
      expect(Number(assetReceived)).to.be.gt(0);
    });

    it("should not apply tax on wallet transfers", async function () {
      // First buy some tokens to transfer
      const { router, alice, bob, assetToken } = context;
      const assetAmountIn = ethers.parseEther("10");

      // Approve spending
      await token
        .connect(alice)
        .approve(await router.getAddress(), ethers.MaxUint256);
      await assetToken
        .connect(alice)
        .approve(await router.getAddress(), assetAmountIn);

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

      // Get post-purchase balance
      const postPurchaseBalance = await token.balanceOf(
        await alice.getAddress()
      );

      // Transfer half to Bob
      const transferAmount = postPurchaseBalance / 2n;
      await token
        .connect(alice)
        .transfer(await bob.getAddress(), transferAmount);

      // Bob transfers back to Alice
      await token
        .connect(bob)
        .transfer(await alice.getAddress(), transferAmount);

      // Verify final balance
      const finalBalance = await token.balanceOf(await alice.getAddress());
      expect(finalBalance).to.equal(postPurchaseBalance);
    });

    it("should correctly split buy tax between vaults", async function () {
      const { router, bob, alice, assetToken } = context;
      const assetAmountIn = ethers.parseEther("1");

      // alice created the token
      const initialBobBalance = await token.balanceOf(await bob.getAddress());
      const initialAliceBalance = await token.balanceOf(await alice.getAddress());
      const initialPlatformBalance = await token.balanceOf(await token.platformTreasury());
      const initialOwnerVaultBalance = await token.balanceOf(await token.creatorTaxVault());

      // bob has no tokens
      expect(initialBobBalance).to.equal(0n);
      expect(initialAliceBalance).to.equal(initialOwnerVaultBalance);
      expect(await token.creatorTaxVault()).to.equal(await alice.getAddress());

      // approve
      await assetToken.connect(bob).approve(await router.getAddress(), assetAmountIn);

      await router
        .connect(bob)
        .swapExactTokensForTokens(
          assetAmountIn,
          0,
          [await assetToken.getAddress(), await token.getAddress()],
          await bob.getAddress(),
          ethers.MaxUint256
        );

      // post balances
      const finalBobBalance = await token.balanceOf(await bob.getAddress());
      const finalAliceBalance = await token.balanceOf(await alice.getAddress());
      const finalPlatformBalance = await token.balanceOf(await token.platformTreasury());
      const finalOwnerVaultBalance = await token.balanceOf(await token.creatorTaxVault());

      // ensure tax was split correctly
      const bobReceived = finalBobBalance - initialBobBalance;
      const aliceReceived = finalAliceBalance - initialAliceBalance;
      const platformReceived = finalPlatformBalance - initialPlatformBalance;
      const ownerVaultReceived = finalOwnerVaultBalance - initialOwnerVaultBalance;

      // expect
      expect(platformReceived).to.equal(ownerVaultReceived);

      // get total
      const totalReceived = bobReceived + aliceReceived + platformReceived;

      // make sure it's .5% of the total
      const expectedTax = (BigInt(totalReceived) * 1000n) / 100_000n;

      // expect
      expect(platformReceived + ownerVaultReceived).to.equal(expectedTax);
      
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

  describe("Admin Functions", function () {
    it("should prevent non-owner from setting tax exemptions", async function () {
      let error;
      try {
        await token
          .connect(context.bob)
          .setTaxExempt(await context.bob.getAddress(), true);
      } catch (e) {
        error = e;
      }
      expect(error?.message).to.include("OwnableUnauthorizedAccount");
    });
  });
});
