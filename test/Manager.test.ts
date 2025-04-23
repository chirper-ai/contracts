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
      expect(await manager.gradReserve()).to.equal(ethers.parseEther('1000000')); // 1m asset required
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
        dexType: DexType.UniswapV2,
        slippage: 10_000, // 10%
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
        dexType: DexType.UniswapV2,
        slippage: 10_000, // 10%
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
      
      const shouldGraduate = await context.manager.checkGraduation(
        await token.getAddress()
      );

      // Initially shouldn't graduate due to high reserve ratio
      expect(shouldGraduate).to.be.false;
    });
  });

  describe("Graduation Process", function () {
    it("should deploy liquidity to Uniswap V2 correctly", async function () {
      const { alice, router, owner, manager, assetToken } = context;
      const dexConfigs = [{
        router: await context.uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: DexType.UniswapV2,
        slippage: 10_000, // 10%
      }];

      const token = await createToken(context, alice, dexConfigs);
      
      // max hold to 100%
      await router.connect(owner).setMaxHold(100_000);
      
      // Buy tokens to reduce reserve ratio
      const buyAmount = ethers.parseEther(`${1_000_000}`);
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
      const shouldGraduate = await manager.checkGraduation(await token.getAddress());
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
        dexType: DexType.UniswapV3,
        slippage: 10_000, // 10%
      }];
    
      const token = await createToken(context, alice, dexConfigs);
      
      // Set max hold to 100%
      await router.connect(owner).setMaxHold(100_000);
      
      // Buy tokens to reduce reserve ratio
      const buyAmount = ethers.parseEther(`${1_000_000}`);
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
      const shouldGraduate = await manager.checkGraduation(await token.getAddress());
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
          dexType: DexType.UniswapV2,
          slippage: 10_000, // 10%
        },
        {
          router: await context.nftPositionManager.getAddress(),
          fee: 3000,
          weight: 50_000,
          dexType: DexType.UniswapV3,
          slippage: 10_000, // 10%
        }
      ];

      const token = await createToken(context, alice, dexConfigs);
      
      // TODO: Add trading to reach graduation threshold
      // TODO: Trigger graduation
      // TODO: Verify proportional liquidity deployment
    });
  });

  describe("Input Validation", function () {
    it("should revert if token has not graduated", async function () {
      const { manager, alice } = context;
      const token = await createToken(context, alice);

      await expect(
        manager.collectFees(await token.getAddress())
      ).to.be.revertedWith("Not graduated");
    });

    it("should revert if there are no fees to collect", async function () {
      const { manager, alice, router, owner } = context;
      
      // Create token with V2 pool
      const dexConfigs = [{
        router: await context.uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: DexType.UniswapV2,
        slippage: 10_000, // 10%
      }];
      
      const token = await createToken(context, alice, dexConfigs);
      await router.connect(owner).setMaxHold(100_000);
      
      // Graduate token by buying enough to reach threshold
      const buyAmount = ethers.parseEther("1000000");
      await context.assetToken.connect(alice).approve(
        await router.getAddress(),
        buyAmount
      );
      
      await router.connect(alice).swapExactTokensForTokens(
        buyAmount,
        0,
        [await context.assetToken.getAddress(), await token.getAddress()],
        await alice.getAddress(),
        ethers.MaxUint256
      );

      await expect(
        manager.collectFees(await token.getAddress())
      ).to.be.revertedWith("No fees to collect");
    });
  });

  describe("Admin Functions", function () {
    it("should allow admin to update dex configs", async function () {
      const { manager, alice, owner, uniswapV2Router, nftPositionManager } = context;
      
      // Create initial token with V2 config
      const initialConfigs = [{
        router: await uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: DexType.UniswapV2,
        slippage: 10_000
      }];
      
      const token = await createToken(context, alice, initialConfigs);
      
      // New config splitting between V2 and V3
      const newConfigs = [
        {
          router: await uniswapV2Router.getAddress(),
          fee: 3000,
          weight: 60_000,
          dexType: DexType.UniswapV2,
          slippage: 10_000
        },
        {
          router: await nftPositionManager.getAddress(),
          fee: 3000,
          weight: 40_000,
          dexType: DexType.UniswapV3,
          slippage: 10_000
        }
      ];
      
      // Update configs
      await manager.connect(owner).setTokenDexConfigs(
        await token.getAddress(),
        newConfigs
      );
    });

    it("should revert if called by non-admin", async function () {
      const { manager, alice, uniswapV2Router } = context;
      
      const token = await createToken(context, alice);
      const newConfigs = [{
        router: await uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: DexType.UniswapV2,
        slippage: 10_000
      }];

      // let error
      let error;
      try {
        await manager.connect(alice).setTokenDexConfigs(
          await token.getAddress(),
          newConfigs
        );
      } catch (e) {
        error = `${e}`;
      }

      // expect error
      expect(error).to.include("AccessControl");
    });

    it("should revert if token is not registered", async function () {
      const { manager, owner, uniswapV2Router } = context;
      
      const newConfigs = [{
        router: await uniswapV2Router.getAddress(),
        fee: 3000,
        weight: 100_000,
        dexType: DexType.UniswapV2,
        slippage: 10_000
      }];

      await expect(
        manager.connect(owner).setTokenDexConfigs(
          ethers.ZeroAddress,
          newConfigs
        )
      ).to.be.revertedWith("Token not registered");
    });

    it("should revert if weights don't sum to 100%", async function () {
      const { manager, alice, owner, uniswapV2Router, nftPositionManager } = context;
      
      const token = await createToken(context, alice);
      
      const invalidConfigs = [
        {
          router: await uniswapV2Router.getAddress(),
          fee: 3000,
          weight: 50_000,
          dexType: DexType.UniswapV2,
          slippage: 10_000
        },
        {
          router: await nftPositionManager.getAddress(),
          fee: 3000,
          weight: 40_000, // Only adds up to 90%
          dexType: DexType.UniswapV3,
          slippage: 10_000
        }
      ];

      await expect(
        manager.connect(owner).setTokenDexConfigs(
          await token.getAddress(),
          invalidConfigs
        )
      ).to.be.revertedWith("Invalid weights");
    });
  });
});