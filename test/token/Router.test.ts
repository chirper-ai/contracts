// test/Router.test.ts
import { ethers } from "hardhat";
import { expect } from "chai";
import { setupTestContext, TestContext, createToken } from "./helper";

describe("Router", function() {
  let context: TestContext;

  beforeEach(async function() {
    context = await setupTestContext();
  });

  describe("Initialization", function() {
    it("should set correct initial values", async function() {
      const { router, factory, assetToken } = context;
      
      expect(await router.factory()).to.equal(factory.address);
      expect(await router.assetToken()).to.equal(assetToken.address);
    });
  });

  describe("Trading Operations", function() {
    it("should calculate correct amounts out", async function() {
      const { router, alice } = context;
      
      // Create agent token and add liquidity
      const agentToken = await createToken(context, alice);
      
      const amountIn = ethers.utils.parseEther("100");
      const amountOut = await router.getAmountsOut(
        agentToken.address,
        await router.assetToken(),
        amountIn
      );
      
      expect(amountOut).to.be.gt(0);
    });

    it("should execute buys correctly", async function() {
      const { router, alice, assetToken } = context;
      
      // Create agent token
      const agentToken = await createToken(context, alice);
      
      // Approve spending
      const buyAmount = ethers.utils.parseEther("100");
      await assetToken.connect(alice).approve(router.address, buyAmount);
      
      // Execute buy
      const EXECUTOR_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EXECUTOR_ROLE"));
      await router.grantRole(EXECUTOR_ROLE, await alice.getAddress());
      
      const beforeBalance = await agentToken.balanceOf(await alice.getAddress());
      await router.connect(alice).buy(buyAmount, agentToken.address, await alice.getAddress());
      const afterBalance = await agentToken.balanceOf(await alice.getAddress());
      
      expect(afterBalance).to.be.gt(beforeBalance);
    });

    it("should execute sells correctly", async function() {
      const { router, alice, assetToken } = context;
      
      // Create agent token and buy some tokens first
      const agentToken = await createToken(context, alice);
      
      const buyAmount = ethers.utils.parseEther("100");
      await assetToken.connect(alice).approve(router.address, buyAmount);
      
      const EXECUTOR_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EXECUTOR_ROLE"));
      await router.grantRole(EXECUTOR_ROLE, await alice.getAddress());
      
      await router.connect(alice).buy(buyAmount, agentToken.address, await alice.getAddress());
      
      // Now sell
      const sellAmount = ethers.utils.parseEther("50");
      await agentToken.connect(alice).approve(router.address, sellAmount);
      
      const beforeBalance = await assetToken.balanceOf(await alice.getAddress());
      await router.connect(alice).sell(sellAmount, agentToken.address, await alice.getAddress());
      const afterBalance = await assetToken.balanceOf(await alice.getAddress());
      
      expect(afterBalance).to.be.gt(beforeBalance);
    });
  });

  describe("Graduation", function() {
    it("should transfer assets correctly on graduation", async function() {
      const { router, alice, assetToken } = context;
      
      // Create and setup agent token
      const agentToken = await createToken(context, alice);
      
      const EXECUTOR_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EXECUTOR_ROLE"));
      await router.grantRole(EXECUTOR_ROLE, await alice.getAddress());
      
      const beforeBalance = await assetToken.balanceOf(await alice.getAddress());
      await router.connect(alice).graduate(agentToken.address);
      const afterBalance = await assetToken.balanceOf(await alice.getAddress());
      
      expect(afterBalance).to.be.gt(beforeBalance);
    });
  });

  describe("Access Control", function() {
    it("should revert unauthorized operations", async function() {
      const { router, alice, bob } = context;
      
      const agentToken = await createToken(context, alice);
      
      await expect(
        router.connect(bob).graduate(agentToken.address)
      ).to.be.reverted;
      
      await expect(
        router.connect(bob).buy(
          ethers.utils.parseEther("100"),
          agentToken.address,
          await bob.getAddress()
        )
      ).to.be.reverted;
    });
  });
});