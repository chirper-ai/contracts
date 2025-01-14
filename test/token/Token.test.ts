// test/Token.test.ts
import { ethers } from "hardhat";
import { expect } from "chai";
import { setupTestContext, TestContext } from "./helper";

describe("Token", function() {
  let context: TestContext;

  beforeEach(async function() {
    context = await setupTestContext();
  });

  describe("Deployment", function() {
    it("should deploy with correct parameters", async function() {
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        100
      );

      expect(await token.name()).to.equal("Test Token");
      expect(await token.symbol()).to.equal("TEST");
      expect(await token.totalSupply()).to.equal(ethers.utils.parseEther("1000000"));
      expect(await token.maxTransactionPercent()).to.equal(100);
    });
  });

  describe("Tax Functionality", function() {
    it("should set tax rates correctly", async function() {
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        100
      );

      await token.setTaxRates(200, 300); // 2% buy, 3% sell
      expect(await token.buyTaxRate()).to.equal(200);
      expect(await token.sellTaxRate()).to.equal(300);
    });

    it("should revert on excessive tax rates", async function() {
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        100
      );

      await expect(
        token.setTaxRates(1100, 300) // 11% buy tax (over limit)
      ).to.be.revertedWith("Tax too high");
    });

    it("should exclude address from tax correctly", async function() {
      const { alice } = context;
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        100
      );

      await token.excludeFromTax(await alice.getAddress());
      
      // Setup tax collection
      await token.setTaxRates(200, 300);
      await token.setTaxRecipients(
        await alice.getAddress(),
        await alice.getAddress()
      );
      
      // Transfer should not incur tax
      const amount = ethers.utils.parseEther("1000");
      const initialBalance = await token.balanceOf(await alice.getAddress());
      await token.transfer(await alice.getAddress(), amount);
      const finalBalance = await token.balanceOf(await alice.getAddress());
      
      expect(finalBalance.sub(initialBalance)).to.equal(amount);
    });
  });

  describe("Transaction Limits", function() {
    it("should enforce max transaction limit", async function() {
      const { alice } = context;
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        10 // 10% max transaction
      );

      const totalSupply = await token.totalSupply();
      const maxAmount = totalSupply.mul(10).div(100);
      const tooMuch = maxAmount.add(1);

      await expect(
        token.transfer(await alice.getAddress(), tooMuch)
      ).to.be.revertedWith("Exceeds limit");
    });

    it("should exclude address from transaction limit", async function() {
      const { alice } = context;
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        10 // 10% max transaction
      );

      await token.excludeFromTransactionLimit(await alice.getAddress());
      
      const totalSupply = await token.totalSupply();
      const maxAmount = totalSupply.mul(20).div(100); // Try 20% (above limit)
      
      // Should not revert
      await token.transfer(await alice.getAddress(), maxAmount);
      expect(await token.balanceOf(await alice.getAddress())).to.equal(maxAmount);
    });
  });

  describe("Graduation", function() {
    it("should graduate token correctly", async function() {
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        100
      );

      expect(await token.hasGraduated()).to.be.false;
      
      await expect(token.graduate())
        .to.emit(token, "Graduated");
      
      expect(await token.hasGraduated()).to.be.true;
    });

    it("should prevent multiple graduations", async function() {
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        100
      );

      await token.graduate();
      await expect(token.graduate()).to.be.revertedWith("Already graduated");
    });
  });

  describe("Owner Functions", function() {
    it("should set pair status correctly", async function() {
      const { alice } = context;
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        100
      );

      await token.setPair(await alice.getAddress(), true);
      expect(await token.isPair(await alice.getAddress())).to.be.true;
    });

    it("should burn tokens correctly", async function() {
      const { alice } = context;
      const Token = await ethers.getContractFactory("Token");
      const token = await Token.deploy(
        "Test Token",
        "TEST",
        1000000,
        100
      );

      const burnAmount = ethers.utils.parseEther("1000");
      const initialSupply = await token.totalSupply();
      
      await token.transfer(await alice.getAddress(), burnAmount);
      await token.burnFrom(await alice.getAddress(), burnAmount);
      
      expect(await token.totalSupply()).to.equal(initialSupply.sub(burnAmount));
    });
  });
});