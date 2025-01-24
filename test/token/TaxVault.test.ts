// test/TaxVault.test.ts
import { ethers, upgrades } from "hardhat";
import { expect, loadFixture, deployFixture, createToken } from "./setup";
import type { TestContext } from "./setup";

describe("TaxVault", function () {
  let context: TestContext;

  beforeEach(async function () {
    context = await loadFixture(deployFixture);
  });

  describe("Initialization", function () {
    it("should set correct initial values", async function () {
      const { taxVault, assetToken, factory } = context;

      expect(await taxVault.assetToken()).to.equal(
        await assetToken.getAddress()
      );
      expect(await taxVault.factory()).to.equal(await factory.getAddress());
    });

    it("should grant correct roles", async function () {
      const { taxVault, owner } = context;

      const ADMIN_ROLE = await taxVault.ADMIN_ROLE();
      const MANAGER_ROLE = await taxVault.MANAGER_ROLE();
      const UPGRADER_ROLE = await taxVault.UPGRADER_ROLE();

      expect(await taxVault.hasRole(ADMIN_ROLE, await owner.getAddress())).to.be
        .true;
      expect(await taxVault.hasRole(MANAGER_ROLE, await owner.getAddress())).to
        .be.true;
      expect(await taxVault.hasRole(UPGRADER_ROLE, await owner.getAddress())).to
        .be.true;
    });

    it("should not allow reinitialization", async function () {
      const { taxVault } = context;
      await expect(
        taxVault.initialize(
          await taxVault.factory(),
          await taxVault.assetToken()
        )
      ).to.be.reverted;
    });
  });

  describe("Token Registration", function () {
    it("should register token correctly", async function () {
      const { taxVault, alice } = context;

      const token = await createToken(context, alice);
      const tokenAddress = await token.getAddress();

      // Verify registration
      const hasRegistered = await taxVault.hasRegistered(tokenAddress);
      expect(hasRegistered).to.be.true;

      const recipients = await taxVault.getRecipients(tokenAddress);
      expect(recipients.length).to.equal(2);
      expect(recipients[0].share).to.equal(50_000);
      expect(recipients[1].share).to.equal(50_000);
    });

    it("should not allow non-factory to register", async function () {
      const { taxVault, alice, owner } = context;

      await expect(
        taxVault
          .connect(alice)
          .registerAgent(
            await alice.getAddress(),
            await alice.getAddress(),
            await owner.getAddress()
          )
      ).to.be.revertedWith("Only factory");
    });
  });

  describe("Distribution", function () {
    it("should distribute funds correctly", async function () {
      const { taxVault, assetToken, owner, alice } = context;

      const token = await createToken(context, alice);
      const tokenAddress = await token.getAddress();

      // Send tokens to vault
      const amount = ethers.parseEther("1");
      await assetToken.transfer(await taxVault.getAddress(), amount);

      // Get initial balances
      const aliceBalanceBefore = await assetToken.balanceOf(
        await alice.getAddress()
      );
      const treasuryBalanceBefore = await assetToken.balanceOf(
        await owner.getAddress()
      );

      // Distribute
      await taxVault.distribute(tokenAddress);

      // Check new balances (50/50 split)
      const aliceBalanceAfter = await assetToken.balanceOf(
        await alice.getAddress()
      );
      const treasuryBalanceAfter = await assetToken.balanceOf(
        await owner.getAddress()
      );

      expect(aliceBalanceAfter - aliceBalanceBefore).to.equal(amount / 2n);
      expect(treasuryBalanceAfter - treasuryBalanceBefore).to.equal(
        amount / 2n
      );
    });

    it("should not distribute for unregistered token", async function () {
      const { taxVault, alice } = context;

      await expect(
        taxVault.distribute(await alice.getAddress())
      ).to.be.revertedWith("Token not registered");
    });
  });

  describe("Recipient Management", function () {
    let tokenAddress: string;
    let token: Contract;

    beforeEach(async function () {
      const { alice } = context;
      token = await createToken(context, alice);
      tokenAddress = await token.getAddress();
    });

    it("should update recipients correctly", async function () {
      const { taxVault, alice, bob, owner } = context;

      const newRecipients = [
        {
          recipient: await alice.getAddress(),
          share: 30_000,
          isActive: true,
        },
        {
          recipient: await bob.getAddress(),
          share: 30_000,
          isActive: true,
        },
        {
          recipient: await owner.getAddress(),
          share: 40_000,
          isActive: true,
        },
      ];

      await taxVault.updateRecipients(tokenAddress, newRecipients);

      const recipients = await taxVault.getRecipients(tokenAddress);
      expect(recipients.length).to.equal(3);
      expect(recipients[0].share).to.equal(30_000);
      expect(recipients[2].share).to.equal(40_000);
    });

    it("should validate share total", async function () {
      const { taxVault, alice, bob } = context;

      const invalidRecipients = [
        {
          recipient: await alice.getAddress(),
          share: 60_000,
          isActive: true,
        },
        {
          recipient: await bob.getAddress(),
          share: 30_000,
          isActive: true,
        },
      ];

      await expect(
        taxVault.updateRecipients(tokenAddress, invalidRecipients)
      ).to.be.revertedWith("Invalid shares");
    });
  });

  describe("Upgradeability", function () {
    it("should allow upgrade by upgrader role", async function () {
      const { taxVault, owner } = context;

      const TaxVault = await ethers.getContractFactory("TaxVault");
      await upgrades.upgradeProxy(await taxVault.getAddress(), TaxVault);
    });

    it("should prevent upgrade by non-upgrader", async function () {
      const { taxVault, alice } = context;

      const TaxVault = await ethers.getContractFactory("TaxVault", alice);
      await expect(upgrades.upgradeProxy(await taxVault.getAddress(), TaxVault))
        .to.be.reverted;
    });
  });
});
