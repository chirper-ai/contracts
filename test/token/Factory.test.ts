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
      expect(Number(await factory.buyTax())).to.equal(Number(200));
      expect(Number(await factory.sellTax())).to.equal(Number(300));
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
        1000000,
        100
      );
      await agentToken.waitForDeployment();

      // Create pair
      const CREATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("CREATOR_ROLE"));
      await factory.grantRole(CREATOR_ROLE, await alice.getAddress());
      
      const agentTokenAddress = await agentToken.getAddress();
      const assetTokenAddress = await assetToken.getAddress();
      
      // Get expected pair address
      const tx = await factory.connect(alice).createPair(agentTokenAddress, assetTokenAddress);
      const receipt = await tx.wait();
      
      // Verify the PairCreated event was emitted
      const event = receipt.logs.find(
        log => log.fragment?.name === "PairCreated"
      );
      expect(event).to.not.be.undefined;
      
      // Verify pair was created correctly
      const pairAddress = await factory.getPair(agentTokenAddress, assetTokenAddress);
      expect(pairAddress).to.not.equal(ethers.ZeroAddress);
      expect(pairAddress).to.equal(event?.args?.pair);
    });

    it("should revert when creating duplicate pair", async function() {
      const { factory, assetToken, alice } = context;
      
      const Token = await ethers.getContractFactory("Token");
      const agentToken = await Token.deploy(
        "Test Agent",
        "TEST",
        1000000,
        100
      );
      await agentToken.waitForDeployment();

      const CREATOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("CREATOR_ROLE"));
      await factory.grantRole(CREATOR_ROLE, await alice.getAddress());
      
      const agentTokenAddress = await agentToken.getAddress();
      const assetTokenAddress = await assetToken.getAddress();
      
      await factory.connect(alice).createPair(agentTokenAddress, assetTokenAddress);
      
      // Try to create the same pair again and expect it to fail
      try {
        await factory.connect(alice).createPair(agentTokenAddress, assetTokenAddress);
        expect.fail("Expected transaction to revert");
      } catch (error: any) {
        expect(error.message).to.include("Pair exists");
      }
    });
  });

  describe("Admin Functions", function() {
    it("should update tax parameters correctly", async function() {
      const { factory, alice } = context;
      
      const newTaxVault = await alice.getAddress();
      const newBuyTax = 250;
      const newSellTax = 350;

      await factory.setTaxParams(newTaxVault, newBuyTax, newSellTax);

      expect(await factory.taxVault()).to.equal(newTaxVault);
      expect(Number(await factory.buyTax())).to.equal(Number(newBuyTax));
      expect(Number(await factory.sellTax())).to.equal(Number(newSellTax));
    });

    it("should revert tax parameter updates from non-admin", async function() {
      const { factory, alice } = context;
      
      try {
        await factory.connect(alice).setTaxParams(await alice.getAddress(), 250, 350);
        expect.fail("Expected transaction to revert");
      } catch (error: any) {
        const ADMIN_ROLE = await factory.ADMIN_ROLE();
        expect(error.message).to.include("AccessControlUnauthorizedAccount");
        expect(error.message).to.include(await alice.getAddress());
        expect(error.message).to.include(ADMIN_ROLE);
      }
    });

    it("should set router address correctly", async function() {
      const { factory, alice } = context;
      
      await factory.setRouter(await alice.getAddress());
      expect(await factory.router()).to.equal(await alice.getAddress());
    });

    it("should revert router update from non-admin", async function() {
      const { factory, alice } = context;
      
      try {
        await factory.connect(alice).setRouter(await alice.getAddress());
        expect.fail("Expected transaction to revert");
      } catch (error: any) {
        const ADMIN_ROLE = await factory.ADMIN_ROLE();
        expect(error.message).to.include("AccessControlUnauthorizedAccount");
        expect(error.message).to.include(await alice.getAddress());
        expect(error.message).to.include(ADMIN_ROLE);
      }
    });
  });
});