// test/Manager.test.ts
import { ethers } from "hardhat";
import { expect } from "chai";
import { setupTestContext, TestContext, createToken } from "./helper";

describe("Manager", function() {
  let context: TestContext;

  beforeEach(async function() {
    context = await setupTestContext();
  });

  describe("Initialization", function() {
    it("should set correct initial values", async function() {
      const { manager, factory, router, owner } = context;
      
      expect(await manager.factory()).to.equal(factory.address);
      expect(await manager.router()).to.equal(router.address);
      expect(await manager.feeReceiver()).to.equal(await owner.getAddress());
      expect(await manager.fee()).to.equal(ethers.utils.parseEther("0.5")); // 5%
      expect(await manager.initialSupply()).to.equal(1_000_000);
      expect(await manager.assetRate()).to.equal(100);
      expect(await manager.graduationThreshold()).to.equal(1000);
    });

    it("should have correct owner", async function() {
      const { manager, owner } = context;
      expect(await manager.owner()).to.equal(await owner.getAddress());
    });
  });

  describe("Token Launch", function() {
    it("should launch new agent token successfully", async function() {
      const { manager, alice, assetToken } = context;
      
      const purchaseAmount = ethers.utils.parseEther("1000");
      await assetToken.connect(alice).approve(manager.address, purchaseAmount);
      
      await expect(manager.connect(alice).launch(
        "Test Agent",
        "TEST",
        "Test prompt",
        "Test intention",
        "https://test.com",
        purchaseAmount
      )).to.emit(manager, "Launched");
    });

    it("should revert launch with insufficient funds", async function() {
      const { manager, alice } = context;
      
      await expect(manager.connect(alice).launch(
        "Test Agent",
        "TEST",
        "Test prompt",
        "Test intention",
        "https://test.com",
        ethers.utils.parseEther("0.1")
      )).to.be.revertedWith("Purchase amount below fee");
    });

    it("should set correct token metrics after launch", async function() {
      const { manager, alice, assetToken } = context;
      
      const purchaseAmount = ethers.utils.parseEther("1000");
      await assetToken.connect(alice).approve(manager.address, purchaseAmount);
      
      const tx = await manager.connect(alice).launch(
        "Test Agent",
        "TEST",
        "Test prompt",
        "Test intention",
        "https://test.com",
        purchaseAmount
      );
      
      const receipt = await tx.wait();
      const event = receipt.events?.find(e => e.event === "Launched");
      const tokenAddress = event?.args?.token;
      
      const metrics = await manager.agentTokens(tokenAddress);
      expect(metrics.creator).to.equal(await alice.getAddress());
      expect(metrics.isTrading).to.be.true;
      expect(metrics.hasGraduated).to.be.false;
    });
  });

  describe("Trading Operations", function() {
    it("should execute buy correctly", async function() {
      const { manager, alice, bob, assetToken } = context;
      
      // First launch a token
      const agentToken = await createToken(context, alice);
      
      // Bob buys some tokens
      const buyAmount = ethers.utils.parseEther("100");
      await assetToken.connect(bob).approve(manager.address, buyAmount);
      
      const beforeBalance = await agentToken.balanceOf(await bob.getAddress());
      await manager.connect(bob).buy(buyAmount, agentToken.address);
      const afterBalance = await agentToken.balanceOf(await bob.getAddress());
      
      expect(afterBalance).to.be.gt(beforeBalance);
    });

    it("should execute sell correctly", async function() {
      const { manager, alice, bob, assetToken } = context;
      
      // Launch token and buy some first
      const agentToken = await createToken(context, alice);
      
      const buyAmount = ethers.utils.parseEther("100");
      await assetToken.connect(bob).approve(manager.address, buyAmount);
      await manager.connect(bob).buy(buyAmount, agentToken.address);
      
      // Now sell half
      const sellAmount = ethers.utils.parseEther("50");
      await agentToken.connect(bob).approve(manager.address, sellAmount);
      
      const beforeBalance = await assetToken.balanceOf(await bob.getAddress());
      await manager.connect(bob).sell(sellAmount, agentToken.address);
      const afterBalance = await assetToken.balanceOf(await bob.getAddress());
      
      expect(afterBalance).to.be.gt(beforeBalance);
    });

    it("should update metrics after trades", async function() {
      const { manager, alice, bob, assetToken } = context;
      
      const agentToken = await createToken(context, alice);
      
      // Execute a buy
      const buyAmount = ethers.utils.parseEther("100");
      await assetToken.connect(bob).approve(manager.address, buyAmount);
      await manager.connect(bob).buy(buyAmount, agentToken.address);
      
      const metrics = await manager.agentTokens(agentToken.address);
      expect(metrics.metrics.vol).to.be.gt(0);
      expect(metrics.metrics.vol24h).to.be.gt(0);
    });
  });

  describe("Graduation", function() {
    it("should graduate token when threshold reached", async function() {
      const { manager, alice, bob, assetToken } = context;
      
      // Set a low graduation threshold for testing
      await manager.setGraduationThreshold(ethers.utils.parseEther("10"));
      
      const agentToken = await createToken(context, alice);
      
      // Buy enough to trigger graduation
      const buyAmount = ethers.utils.parseEther("1000");
      await assetToken.connect(bob).approve(manager.address, buyAmount);
      
      await expect(
        manager.connect(bob).buy(buyAmount, agentToken.address)
      ).to.emit(manager, "Graduated");
      
      const tokenInfo = await manager.agentTokens(agentToken.address);
      expect(tokenInfo.hasGraduated).to.be.true;
      expect(tokenInfo.isTrading).to.be.false;
    });
  });

  describe("Admin Functions", function() {
    it("should update fee parameters correctly", async function() {
      const { manager, alice, owner } = context;
      
      const newFee = ethers.utils.parseEther("0.6");
      await manager.connect(owner).setFee(newFee, await alice.getAddress());
      
      expect(await manager.fee()).to.equal(newFee);
      expect(await manager.feeReceiver()).to.equal(await alice.getAddress());
    });

    it("should update graduation threshold correctly", async function() {
      const { manager, owner } = context;
      
      const newThreshold = ethers.utils.parseEther("2000");
      await manager.connect(owner).setGraduationThreshold(newThreshold);
      
      expect(await manager.graduationThreshold()).to.equal(newThreshold);
    });
  });
});