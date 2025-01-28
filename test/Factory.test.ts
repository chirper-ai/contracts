// test/Factory.test.ts
import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture } from "./setup";
import type { TestContext } from "./setup";
import { Contract } from "ethers";

describe("Factory Extended Tests", function () {
  let context: TestContext;

  beforeEach(async function () {
    context = await loadFixture(deployFixture);
  });

  describe("Admin Functions", function () {
    it("should update impactMultiplier correctly", async function () {
      const { factory, owner } = context;
      const newMultiplier = ethers.parseEther("2");
      
      await factory.connect(owner).setImpactMultiplier(newMultiplier);
      expect(await factory.impactMultiplier()).to.equal(newMultiplier);
    });

    it("should reject invalid impactMultiplier values", async function () {
      const { factory, owner } = context;
      await expect(factory.connect(owner).setImpactMultiplier(0))
        .to.be.revertedWith("Invalid Impact Multiplier");
    });

    it("should update initialReserveAsset correctly", async function () {
      const { factory, owner } = context;
      const newReserve = ethers.parseEther("6000");
      
      await factory.connect(owner).setInitialReserveAsset(newReserve);
      expect(await factory.initialReserveAsset()).to.equal(newReserve);
    });

    it("should reject invalid initialReserveAsset values", async function () {
      const { factory, owner } = context;
      await expect(factory.connect(owner).setInitialReserveAsset(0))
        .to.be.revertedWith("Invalid asset reserve");
    });
    
    it("should update platformTreasury correctly", async function () {
      const { factory, owner, bob } = context;
      await factory.connect(owner).setPlatformTreasury(await bob.getAddress());
      expect(await factory.platformTreasury()).to.equal(await bob.getAddress());
    });

    it("should reject zero address for platformTreasury", async function () {
      const { factory, owner } = context;
      await expect(factory.connect(owner).setPlatformTreasury(ethers.ZeroAddress))
        .to.be.revertedWith("Invalid treasury");
    });
  });

  describe("Airdrop Functionality", function () {
    it("should create airdrop contract with valid parameters", async function () {
      const { factory, alice, assetToken, uniswapV2Router } = context;
      const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test"));
      
      const airdropParams = {
        merkleRoot: merkleRoot,
        claimantCount: 100,
        percentage: 5000 // 5%
      };

      const dexConfig = [{
        router: await uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: 0
      }];

      await assetToken
        .connect(alice)
        .approve(await factory.getAddress(), ethers.parseEther("10"));

      const tx = await factory
        .connect(alice)
        .launch(
          "Test Agent",
          "TEST",
          "https://test.com",
          "Test intention",
          ethers.parseEther("10"),
          dexConfig,
          airdropParams
        );

      const receipt = await tx.wait();
      const event = receipt?.logs.find(log => log.fragment?.name === "Launch");
      expect(event?.args?.airdrop).to.not.equal(ethers.ZeroAddress);
    });

    it("should reject invalid airdrop percentages", async function () {
      const { factory, alice, assetToken, uniswapV2Router } = context;
      const merkleRoot = ethers.keccak256(ethers.toUtf8Bytes("test"));
      
      const airdropParams = {
        merkleRoot: merkleRoot,
        claimantCount: 100,
        percentage: 6000 // 6% - exceeds MAX_AIRDROP_PERCENTAGE
      };

      const dexConfig = [{
        router: await uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: 0
      }];

      await assetToken
        .connect(alice)
        .approve(await factory.getAddress(), ethers.parseEther("10"));

      await expect(factory
        .connect(alice)
        .launch(
          "Test Agent",
          "TEST",
          "https://test.com",
          "Test intention",
          ethers.parseEther("10"),
          dexConfig,
          airdropParams
        )).to.be.revertedWith("Invalid percentage");
    });
  });

  describe("Platform Fee Collection", function () {
    it("should transfer correct platform fee on launch", async function () {
      const { factory, alice, assetToken, uniswapV2Router, owner } = context;
      
      const defaultAirdropParams = {
        merkleRoot: ethers.ZeroHash,
        claimantCount: 0,
        percentage: 0
      };

      const dexConfig = [{
        router: await uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: 0
      }];

      await assetToken
        .connect(alice)
        .approve(await factory.getAddress(), ethers.parseEther("10"));

      const tx = await factory
        .connect(alice)
        .launch(
          "Test Agent",
          "TEST",
          "https://test.com",
          "Test intention",
          ethers.parseEther("10"),
          dexConfig,
          defaultAirdropParams
        );

      const receipt = await tx.wait();
      const event = receipt?.logs.find(log => log.fragment?.name === "Launch");
      const token = event?.args?.token;

      // Get token contract
      const Token = await ethers.getContractFactory("Token");
      const agentToken = Token.attach(token);

      // Calculate expected fee (1% of total supply)
      const totalSupply = await agentToken.totalSupply();
      const expectedFee = totalSupply * BigInt(1000) / BigInt(100_000); // 1%

      // Verify platform treasury received correct fee
      const treasuryBalance = await agentToken.balanceOf(await owner.getAddress());
      expect(treasuryBalance).to.be.gte(expectedFee);
    });
  });

  describe("Initial Purchase Limits", function () {
    it("should reject excessive initial purchases", async function () {
      const { factory, alice, assetToken, uniswapV2Router } = context;
      
      const defaultAirdropParams = {
        merkleRoot: ethers.ZeroHash,
        claimantCount: 0,
        percentage: 0
      };

      const dexConfig = [{
        router: await uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: 0
      }];

      await assetToken
        .connect(alice)
        .approve(await factory.getAddress(), ethers.parseEther(`${10_000}`)); // Large amount

      await expect(factory
        .connect(alice)
        .launch(
          "Test Agent",
          "TEST",
          "https://test.com",
          "Test intention",
          ethers.parseEther(`${10_000}`), // Trying to purchase more than 5% of supply
          dexConfig,
          defaultAirdropParams
        )).to.be.revertedWith("Initial purchase too large");
    });
  });
});