// test/Factory.test.ts
import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture } from "./setup";
import type { TestContext } from "./setup";
import { Contract } from "ethers";

describe("Factory", function () {
  let context: TestContext;

  beforeEach(async function () {
    context = await loadFixture(deployFixture);
  });

  describe("Initialization", function () {
    it("should set correct initial values", async function () {
      const { factory, router, owner } = context;

      expect(await factory.router()).to.equal(await router.getAddress());
      expect(await factory.platformTreasury()).to.equal(
        await owner.getAddress()
      );
      expect(Number(await factory.initialSupply())).to.equal(
        Number(ethers.parseEther("1000000000"))
      );
      expect(await factory.K()).to.equal(250n);
    });

    it("should grant ADMIN_ROLE to deployer", async function () {
      const { factory, owner } = context;
      const ADMIN_ROLE = await factory.ADMIN_ROLE();

      expect(await factory.hasRole(ADMIN_ROLE, await owner.getAddress())).to.be
        .true;
    });
  });

  describe("Token Launch", function () {
    it("should launch new token correctly", async function () {
      const { factory, alice, assetToken, uniswapV2Router } = context;

      const dexConfig = [
        {
          router: await uniswapV2Router.getAddress(),
          fee: 3_000,
          weight: 100_000,
          dexType: 0, // UniswapV2
        },
      ];

      // approve
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
          dexConfig
        );

      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log) => log.fragment?.name === "Launch"
      );

      expect(event).to.not.be.undefined;
      expect(event?.args?.token).to.not.equal(ethers.ZeroAddress);
      expect(event?.args?.pair).to.not.equal(ethers.ZeroAddress);
      expect(event?.args?.creator).to.equal(await alice.getAddress());
      expect(event?.args?.name).to.equal("Test Agent");
      expect(event?.args?.symbol).to.equal("TEST");
    });

    it("should verify pair creation and bonding curve parameters", async function () {
      const { factory, alice, uniswapV2Router, assetToken } = context;

      const dexConfig = [
        {
          router: await uniswapV2Router.getAddress(),
          fee: 3000,
          weight: 100_000,
          dexType: 0,
        },
      ];

      // approve
      await assetToken
        .connect(alice)
        .approve(await factory.getAddress(), ethers.parseEther("10"));

      const tx = await factory
        .connect(alice)
        .launch(
          "Test Agent",
          "TEST",
          "Test intention",
          "https://test.com",
          ethers.parseEther("10"),
          dexConfig
        );

      const receipt = await tx.wait();
      const event = receipt?.logs.find(
        (log) => log.fragment?.name === "Launch"
      );
      const token = event?.args?.token;
      const pair = event?.args?.pair;

      // Verify pair exists
      expect(
        await factory.getPair(token, await assetToken.getAddress())
      ).to.equal(pair);

      // Verify bonding pair parameters
      const BondingPair = await ethers.getContractFactory("BondingPair");
      const bondingPair = BondingPair.attach(pair);

      expect(await bondingPair.K()).to.equal(await factory.K());
      expect(await bondingPair.router()).to.equal(await factory.router());
    });

    it("should not launch with invalid parameters", async function () {
      const { factory, alice, assetToken, uniswapV2Router } = context;

      const dexConfig = [
        {
          router: await uniswapV2Router.getAddress(),
          fee: 3000,
          weight: 50_000, // Invalid weight (not 100%)
          dexType: 0,
        },
      ];

      // approve
      await assetToken
        .connect(alice)
        .approve(await factory.getAddress(), ethers.parseEther("10"));

      let failed = false;
      try {
        await factory
          .connect(alice)
          .launch(
            "Test Agent",
            "TEST",
            "Test intention",
            "https://test.com",
            ethers.parseEther("10"),
            dexConfig
          );
      } catch (e) {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });

  describe("Admin Functions", function () {
    it("should update bonding curve parameters correctly", async function () {
      const { factory } = context;

      const newK = ethers.parseEther("2");

      await factory.setK(newK);

      expect(await factory.K()).to.equal(newK);
    });

    it("should update initial supply correctly", async function () {
      const { factory } = context;

      const newSupply = 2_000_000;
      await factory.setInitialSupply(newSupply);
      expect(Number(await factory.initialSupply())).to.equal(Number(newSupply));
    });

    it("should not allow parameter updates from non-admin", async function () {
      const { factory, alice } = context;

      let failed = false;
      try {
        await factory.connect(alice).setK(ethers.parseEther("2"));
      } catch (e) {
        failed = true;
      }
      expect(failed).to.be.true;

      failed = false;
      try {
        await factory.connect(alice).setInitialSupply(2_000_000);
      } catch (e) {
        failed = true;
      }
      expect(failed).to.be.true;
    });

    it("should not allow setting invalid parameters", async function () {
      const { factory } = context;

      // Invalid K (zero)
      let failed = false;
      try {
        await factory.setK(0);
      } catch (e) {
        failed = true;
      }
      expect(failed).to.be.true;

      // Invalid initial supply (zero)
      failed = false;
      try {
        await factory.setInitialSupply(0);
      } catch (e) {
        failed = true;
      }
      expect(failed).to.be.true;
    });
  });
});
