// test/Manager.test.ts
import { ethers } from "hardhat";
import { expect, loadFixture, deployFixture, createToken, DexType } from "./setup";
import type { TestContext } from "./setup";

describe("Manager", function () {
  let context: TestContext;

  beforeEach(async function () {
    context = await loadFixture(deployFixture);
  });

  describe("Initialization", function () {
    it("should set correct initial values", async function () {
      const { manager, factory, assetToken } = context;

      expect(await manager.factory()).to.equal(await factory.getAddress());
      expect(await manager.assetToken()).to.equal(await assetToken.getAddress());
      expect(await manager.gradSlippage()).to.equal(1_000n); // 1%
      expect(await manager.gradThreshold()).to.equal(20_000n); // 20%
    });

    it("should grant ADMIN_ROLE to deployer", async function () {
      const { manager, owner } = context;
      const ADMIN_ROLE = await manager.ADMIN_ROLE();
      expect(await manager.hasRole(ADMIN_ROLE, await owner.getAddress())).to.be.true;
    });
  });

  describe("Agent Registration", function () {

    it("should revert registration from non-factory address", async function () {
      const { manager, alice } = context;
      const dexConfigs = [{
        router: await context.uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: DexType.UniswapV2
      }];

      await expect(
        manager.connect(alice).registerAgent(
          ethers.ZeroAddress,
          ethers.ZeroAddress,
          "https://test.com",
          "Test intention",
          dexConfigs
        )
      ).to.be.revertedWith("Only factory");
    });

    it("should validate DEX configurations", async function () {
      const { alice, uniswapV2Router } = context;

      // Test invalid total weight
      const invalidConfigs = [{
        router: await uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 50_000, // Only 50%
        dexType: DexType.UniswapV2
      }];

      await expect(
        createToken(context, alice, invalidConfigs)
      ).to.be.revertedWith("Invalid weights");
    });
  });

  describe("Graduation Checks", function () {
    it("should correctly identify graduation conditions", async function () {
      const { alice } = context;
      const token = await createToken(context, alice);
      
      const [shouldGraduate, ratio] = await context.manager.checkGraduation(
        await token.getAddress()
      );

      // Initially shouldn't graduate due to high reserve ratio
      expect(shouldGraduate).to.be.false;
      expect(ratio).to.be.gt(20_000n); // > 20%
    });
  });

  describe("Graduation Process", function () {
    it("should deploy liquidity to Uniswap V2 correctly", async function () {
      const { alice, router, owner, manager, assetToken } = context;
      const dexConfigs = [{
        router: await context.uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: DexType.UniswapV2
      }];

      const token = await createToken(context, alice, dexConfigs);
      
      // max hold to 100%
      await router.connect(owner).setMaxHold(100_000);
      
      // Buy tokens to reduce reserve ratio
      const buyAmount = ethers.parseEther("1000");
      await assetToken.connect(alice).approve(
        await router.getAddress(),
        buyAmount
      );
      
      await router.connect(alice).swapExactTokensForTokens(
        buyAmount,
        0,
        [await assetToken.getAddress(), await token.getAddress()],
        await alice.getAddress(),
        ethers.MaxUint256
      );

      // check isGraduated
      const [shouldGraduate] = await manager.checkGraduation(await token.getAddress());
      expect(shouldGraduate).to.be.false;

      // Verify graduation
      const info = await manager.agentProfile(await token.getAddress());
      const pool = info.mainPool;

      // ensure not zero address
      expect(pool).to.not.equal(ethers.ZeroAddress);

      // Verify V2 pool
      const pair = await ethers.getContractAt("IUniswapV2Pair", pool);
      
      // Check pool has liquidity
      const [reserve0, reserve1] = await pair.getReserves();
      expect(reserve0).to.be.gt(0);
      expect(reserve1).to.be.gt(0);
    });

    it("should deploy liquidity to Uniswap V3 correctly", async function () {
      const { alice, router, owner, manager, assetToken, nftPositionManager } = context;
      const dexConfigs = [{
        router: await nftPositionManager.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: DexType.UniswapV3
      }];
    
      const token = await createToken(context, alice, dexConfigs);
      
      // Set max hold to 100%
      await router.connect(owner).setMaxHold(100_000);
      
      // Buy tokens to reduce reserve ratio
      const buyAmount = ethers.parseEther("1000");
      await assetToken.connect(alice).approve(
        await router.getAddress(),
        buyAmount
      );
      
      await router.connect(alice).swapExactTokensForTokens(
        buyAmount,
        0,
        [await assetToken.getAddress(), await token.getAddress()],
        await alice.getAddress(),
        ethers.MaxUint256
      );
    
      // Check graduation conditions
      const [shouldGraduate] = await manager.checkGraduation(await token.getAddress());
      expect(shouldGraduate).to.be.false;
    
      // Verify graduation
      const info = await manager.agentProfile(await token.getAddress());
      const pool = info.mainPool;
      
      // Ensure not zero address
      expect(pool).to.not.equal(ethers.ZeroAddress);
    
      // Verify V3 pool
      const v3Pool = await ethers.getContractAt("IUniswapV3Pool", pool);
      
      // Check pool has liquidity
      const slot0 = await v3Pool.slot0();
      expect(slot0.sqrtPriceX96).to.be.gt(0);
      
      // check pool liquidity
      const liquidity = await v3Pool.liquidity();
      expect(liquidity).to.be.gt(0);
    });

    it("should handle multiple DEX deployments with correct weights", async function () {
      const { alice } = context;
      const dexConfigs = [
        {
          router: await context.uniswapV2Router.getAddress(),
          fee: 3000,
          weight: 50_000,
          dexType: DexType.UniswapV2
        },
        {
          router: await context.nftPositionManager.getAddress(),
          fee: 3000,
          weight: 50_000,
          dexType: DexType.UniswapV3
        }
      ];

      const token = await createToken(context, alice, dexConfigs);
      
      // TODO: Add trading to reach graduation threshold
      // TODO: Trigger graduation
      // TODO: Verify proportional liquidity deployment
    });
  });

  describe("Admin Functions", function () {
    it("should update graduation parameters correctly", async function () {
      const { manager } = context;
      
      await manager.setGradSlippage(500); // 0.5%
      expect(await manager.gradSlippage()).to.equal(500n);

      await manager.setGradThreshold(15_000); // 15%
      expect(await manager.gradThreshold()).to.equal(15_000n);
    });

    it("should revert invalid parameter updates", async function () {
      const { manager } = context;

      await expect(
        manager.setGradSlippage(0)
      ).to.be.revertedWith("Invalid slippage");

      await expect(
        manager.setGradSlippage(100_001)
      ).to.be.revertedWith("Invalid slippage");
    });
  });
});