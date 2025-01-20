// test/Factory.test.ts
import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture } from "./helper";
import { Contract } from "ethers";
import type { TestContext } from "./helper";

describe("Factory", function() {
  let context: TestContext;

  beforeEach(async function() {
    context = await loadFixture(deployFixture);
  });

  describe("Initialization", function() {
    it("should set correct initial values", async function() {
      const { factory, owner } = context;
      
      expect(await factory.taxVault()).to.equal(await owner.getAddress());
      expect(Number(await factory.buyTax())).to.equal(2_000);
      expect(Number(await factory.sellTax())).to.equal(3_000);
      expect(Number(await factory.launchTax())).to.equal(5_000);
    });

    it("should grant DEFAULT_ADMIN_ROLE to deployer", async function() {
      const { factory, owner } = context;
      const DEFAULT_ADMIN_ROLE = await factory.DEFAULT_ADMIN_ROLE();
      
      expect(await factory.hasRole(DEFAULT_ADMIN_ROLE, await owner.getAddress())).to.be.true;
    });
  });

  describe("Pair Creation", function() {
    it("should create new pair correctly", async function() {
      const { factory, assetToken, alice } = context;
      
      // Deploy a mock agent token
      const Token = await ethers.getContractFactory("Token");
      const agentToken = await Token.deploy(
        "Test Agent",
        "TEST",
        "1000000",
        await alice.getAddress(),  // manager address
        1_000,
        1_000,
        alice.getAddress()
      );
      await agentToken.waitForDeployment();

      // Create pair
      const CREATOR_ROLE = await factory.CREATOR_ROLE();
      await factory.grantRole(CREATOR_ROLE, await alice.getAddress());
      
      const agentTokenAddress = await agentToken.getAddress();
      const assetTokenAddress = await assetToken.getAddress();
      
      // Create pair and check
      const tx = await factory.connect(alice).createPair(agentTokenAddress, assetTokenAddress);
      const receipt = await tx.wait();
      
      // Get pair address and verify it exists
      const pairAddress = await factory.getPair(agentTokenAddress, assetTokenAddress);
      expect(pairAddress).to.not.equal(ethers.ZeroAddress);
    });

    it("should revert when creating duplicate pair", async function() {
      const { factory, assetToken, alice } = context;
      
      const Token = await ethers.getContractFactory("Token");
      const agentToken = await Token.deploy(
        "Test Agent",
        "TEST",
        "1000000",
        await factory.getAddress(),
        100,
        100,
        alice.getAddress()
      );
      await agentToken.waitForDeployment();

      const CREATOR_ROLE = await factory.CREATOR_ROLE();
      await factory.grantRole(CREATOR_ROLE, await alice.getAddress());
      
      const agentTokenAddress = await agentToken.getAddress();
      const assetTokenAddress = await assetToken.getAddress();
      
      // First creation should succeed
      await factory.connect(alice).createPair(agentTokenAddress, assetTokenAddress);
      
      // Second creation should fail
      let failed = false;
      try {
        await factory.connect(alice).createPair(agentTokenAddress, assetTokenAddress);
      } catch (error) {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });

  describe("Admin Functions", function() {
    it("should update tax parameters correctly", async function() {
      const { factory, alice } = context;
      
      const newTaxVault = await alice.getAddress();
      const newBuyTax = 250;
      const newSellTax = 350;
      const newLaunchTax = 600;

      await factory.setTaxParameters(newBuyTax, newSellTax, newLaunchTax, newTaxVault);

      expect(await factory.taxVault()).to.equal(newTaxVault);
      expect(Number(await factory.buyTax())).to.equal(newBuyTax);
      expect(Number(await factory.sellTax())).to.equal(newSellTax);
      expect(Number(await factory.launchTax())).to.equal(newLaunchTax);
    });

    it("should revert tax parameter updates from non-admin", async function() {
      const { factory, alice } = context;
      
      let failed = false;
      try {
        await factory.connect(alice).setTaxParameters(250, 350, 600, await alice.getAddress());
      } catch (error) {
        failed = true;
      }
      expect(failed).to.be.true;
    });

    it("should set router address correctly", async function() {
      const { factory, alice } = context;
      
      await factory.setRouter(await alice.getAddress());
      expect(await factory.router()).to.equal(await alice.getAddress());
    });

    it("should revert router update from non-admin", async function() {
      const { factory, alice } = context;
      
      let failed = false;
      try {
        await factory.connect(alice).setRouter(await alice.getAddress());
      } catch (error) {
        failed = true;
      }
      expect(failed).to.be.true;
    });

    it("should revert when setting invalid tax values", async function() {
      const { factory, owner } = context;
      
      let failed = false;
      try {
        await factory.setTaxParameters(10001, 300, 500, await owner.getAddress());
      } catch (error) {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });
});