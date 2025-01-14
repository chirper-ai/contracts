// test/Token.test.ts
import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture } from "./helper";
import type { TestContext } from "./helper";
import { Contract } from "ethers";

describe("Token", function() {
  let context: TestContext;
  let token: Contract;

  beforeEach(async function() {
    context = await loadFixture(deployFixture);
    
    // Deploy a test token for each test
    const Token = await ethers.getContractFactory("Token");
    token = await Token.deploy(
      "Test Token",
      "TEST",
      "1000000", // 1M tokens
      50,        // 50% max transaction limit
      await context.factory.getAddress(),
      await context.owner.getAddress() // owner as manager
    );
    await token.waitForDeployment();
  });

  describe("Initialization", function() {
    it("should set correct initial values", async function() {
      expect(await token.name()).to.equal("Test Token");
      expect(await token.symbol()).to.equal("TEST");
      expect(Number(await token.decimals())).to.equal(Number(18));
      expect(Number(await token.totalSupply())).to.equal(Number(ethers.parseEther("1000000")));
      expect(Number(await token.maxTransactionPercent())).to.equal(50);
    });

    it("should assign initial supply to deployer", async function() {
      expect(await token.balanceOf(await context.owner.getAddress()))
        .to.equal(await token.totalSupply());
    });

    it("should set correct factory and manager", async function() {
      expect(await token.factory()).to.equal(await context.factory.getAddress());
      expect(await token.manager()).to.equal(await context.owner.getAddress());
    });
  });

  describe("Transfer Functionality", function() {
    it("should transfer tokens between accounts", async function() {
      const amount = ethers.parseEther("1000");
      
      const initialBalance = await token.balanceOf(await context.alice.getAddress());
      await token.transfer(await context.alice.getAddress(), amount);
      const finalBalance = await token.balanceOf(await context.alice.getAddress());
      
      expect(finalBalance - initialBalance).to.equal(amount);
    });

    it("should fail transfer above max transaction limit", async function() {
      const amount = ethers.parseEther("600000"); // 60% of total supply

      // set limit
      await token.updateMaxTransaction(50);
      
      let failed = false;
      try {
        await token.transfer(await context.alice.getAddress(), amount);
      } catch (error) {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });

  describe("Tax Functionality", function() {
    it("should apply buy tax correctly", async function() {
      // Set token as paired in factory
      await token.setPair(await context.alice.getAddress(), true);
  
      // Transfer a larger amount first to alice
      const setupAmount = ethers.parseEther("10000");
      await token.transfer(await context.alice.getAddress(), setupAmount);
      
      // Transfer from pair address to simulate buy (should apply tax)
      const transferAmount = ethers.parseEther("1000");
      await token.connect(context.alice).transfer(await context.bob.getAddress(), transferAmount);
      
      // Get tax vault balance
      const taxVaultBalance = await token.balanceOf(await context.factory.taxVault());
      expect(Number(taxVaultBalance)).to.be.gt(0);
  });

    it("should apply sell tax correctly", async function() {
      // Set token as paired in factory
      await token.setPair(await context.alice.getAddress(), true);

      // Transfer tokens to bob first
      const transferAmount = ethers.parseEther("1000");
      await token.transfer(await context.bob.getAddress(), transferAmount);
      
      // Transfer to pair address to simulate sell (should apply tax)
      await token.connect(context.bob).transfer(await context.alice.getAddress(), transferAmount);
      
      // Get tax vault balance
      const taxVaultBalance = await token.balanceOf(await context.factory.taxVault());
      expect(Number(taxVaultBalance)).to.be.gt(0);
    });
  });

  describe("Owner Functions", function() {
    it("should update max transaction limit", async function() {
      const newLimit = 75; // 75%
      await token.updateMaxTransaction(newLimit);
      expect(Number(await token.maxTransactionPercent())).to.equal(newLimit);
    });

    it("should exclude address from transaction limit", async function() {
      const amount = ethers.parseEther("600000"); // 60% of supply
      await token.excludeFromTransactionLimit(await context.alice.getAddress());
      
      // Transfer should now succeed despite being above limit
      await token.transfer(await context.alice.getAddress(), amount);
      expect(Number(await token.balanceOf(await context.alice.getAddress()))).to.equal(Number(amount));
    });
  });

  describe("Graduation", function() {
    it("should set graduated status correctly", async function() {
      expect(await token.hasGraduated()).to.be.false;
      
      // Only manager can graduate
      await token.graduate(await context.alice.getAddress()); // using alice as pair address
      
      expect(await token.hasGraduated()).to.be.true;
      expect(await token.isPair(await context.alice.getAddress())).to.be.true;
    });

    it("should fail graduation from non-manager", async function() {
      let failed = false;
      try {
        await token.connect(context.alice).graduate(await context.bob.getAddress());
      } catch (error) {
        failed = true;
      }
      expect(failed).to.be.true;
    });

    it("should fail graduation if already graduated", async function() {
      await token.graduate(await context.alice.getAddress());
      
      let failed = false;
      try {
        await token.graduate(await context.bob.getAddress());
      } catch (error) {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });
});