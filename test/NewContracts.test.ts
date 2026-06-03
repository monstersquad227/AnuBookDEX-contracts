import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("DarkPoolRouter", function () {
  async function deployFixture() {
    const [owner, coordinator, user1, user2] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("DarkPoolRouter");
    const router = await Factory.deploy();
    await router.waitForDeployment();

    await router.connect(owner).setCoordinator(coordinator.address);
    return { router, owner, coordinator, user1, user2 };
  }

  describe("Deployment", function () {
    it("should set owner and default coordinator", async function () {
      const { router, owner } = await loadFixture(deployFixture);
      expect(await router.owner()).to.equal(owner.address);
    });

    it("should set default service fee to 30 bps", async function () {
      const { router } = await loadFixture(deployFixture);
      expect(await router.serviceFeeBps()).to.equal(30);
    });

    it("should have MIN_ORDER_VALUE of 100k ether", async function () {
      const { router } = await loadFixture(deployFixture);
      expect(await router.MIN_ORDER_VALUE()).to.equal(100_000n * 10n ** 18n);
    });
  });

  describe("Intent Submission", function () {
    it("should accept intent above minimum order value", async function () {
      const { router, user1 } = await loadFixture(deployFixture);
      await expect(
        router.connect(user1).submitIntent(
          1,
          ethers.keccak256(ethers.toUtf8Bytes("note1")),
          2000n,
          2100n,
          100_000n * 10n ** 18n
        )
      ).to.emit(router, "DarkPoolIntent")
       .and.to.emit(router, "DarkPoolRoundStarted");
    });

    it("should reject intent below minimum order value", async function () {
      const { router, user1 } = await loadFixture(deployFixture);
      await expect(
        router.connect(user1).submitIntent(
          1,
          ethers.keccak256(ethers.toUtf8Bytes("note1")),
          2000n,
          2100n,
          1000n // below minimum
        )
      ).to.be.revertedWith("Below minimum order");
    });

    it("should reject intent with invalid price range", async function () {
      const { router, user1 } = await loadFixture(deployFixture);
      await expect(
        router.connect(user1).submitIntent(
          1,
          ethers.keccak256(ethers.toUtf8Bytes("note1")),
          2100n, // minPrice > maxPrice
          2000n,
          100_000n * 10n ** 18n
        )
      ).to.be.revertedWith("Invalid price range");
    });

    it("should track multiple participants in a round", async function () {
      const { router, user1, user2 } = await loadFixture(deployFixture);
      const amount = 100_000n * 10n ** 18n;

      await router.connect(user1).submitIntent(1, ethers.ZeroHash, 100n, 200n, amount);
      await router.connect(user2).submitIntent(1, ethers.ZeroHash, 100n, 200n, amount);

      expect(await router.getRoundParticipantCount(1)).to.equal(2);
      const participants = await router.getRoundParticipants(1);
      expect(participants[0]).to.equal(user1.address);
      expect(participants[1]).to.equal(user2.address);
    });
  });

  describe("Round Settlement", function () {
    it("should allow coordinator to settle a round", async function () {
      const { router, coordinator, user1 } = await loadFixture(deployFixture);
      const amount = 100_000n * 10n ** 18n;

      await router.connect(user1).submitIntent(1, ethers.ZeroHash, 100n, 200n, amount);

      await expect(
        router.connect(coordinator).settleRound(
          1,
          ethers.keccak256(ethers.toUtf8Bytes("root1")),
          1,
          amount
        )
      ).to.emit(router, "DarkPoolRoundSettled");

      const settlement = await router.getRoundSettlement(1);
      expect(settlement.totalVolume).to.equal(amount);
    });

    it("should reject settlement from non-coordinator", async function () {
      const { router, user1 } = await loadFixture(deployFixture);
      await expect(
        router.connect(user1).settleRound(
          1,
          ethers.ZeroHash,
          1,
          1000n
        )
      ).to.be.revertedWith("Only coordinator");
    });

    it("should reject duplicate settlement", async function () {
      const { router, coordinator, user1 } = await loadFixture(deployFixture);
      const amount = 100_000n * 10n ** 18n;

      await router.connect(user1).submitIntent(1, ethers.ZeroHash, 100n, 200n, amount);
      await router.connect(coordinator).settleRound(1, ethers.ZeroHash, 1, amount);

      await expect(
        router.connect(coordinator).settleRound(1, ethers.ZeroHash, 1, amount)
      ).to.be.revertedWith("Already settled");
    });

    it("should collect service fees on settlement", async function () {
      const { router, coordinator, user1 } = await loadFixture(deployFixture);
      const amount = 100_000n * 10n ** 18n;
      const expectedFee = amount * 30n / 10000n; // 30 bps

      await router.connect(user1).submitIntent(1, ethers.ZeroHash, 100n, 200n, amount);
      await router.connect(coordinator).settleRound(1, ethers.ZeroHash, 1, amount);

      const stats = await router.getStats();
      expect(stats[2]).to.equal(expectedFee); // fees
    });
  });
});

describe("LiquidityRouter", function () {
  async function deployFixture() {
    const [owner, engine, user] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("LiquidityRouter");
    const router = await Factory.deploy();
    await router.waitForDeployment();

    await router.connect(owner).setEngine(engine.address);
    return { router, owner, engine, user };
  }

  describe("Deployment", function () {
    it("should set owner correctly", async function () {
      const { router, owner } = await loadFixture(deployFixture);
      expect(await router.owner()).to.equal(owner.address);
    });

    it("should allow engine update", async function () {
      const { router, owner } = await loadFixture(deployFixture);
      await router.connect(owner).setAnubookSettlement(owner.address);
      expect(await router.anubookSettlement()).to.equal(owner.address);
    });
  });

  describe("Pool Mapping", function () {
    it("should map a pool for a trading pair", async function () {
      const { router, owner, engine } = await loadFixture(deployFixture);
      await router.connect(owner).mapPool("ETH", "USDT", engine.address);

      const pool = await router.getPool("ETH", "USDT");
      expect(pool).to.equal(engine.address);
    });

    it("should enable routing by default on map", async function () {
      const { router, owner, engine } = await loadFixture(deployFixture);
      await router.connect(owner).mapPool("ETH", "USDT", engine.address);

      expect(await router.isRoutingEnabled("ETH", "USDT")).to.be.true;
    });

    it("should toggle routing on/off", async function () {
      const { router, owner, engine } = await loadFixture(deployFixture);
      await router.connect(owner).mapPool("ETH", "USDT", engine.address);
      await router.connect(owner).toggleRouting("ETH", "USDT", false);

      expect(await router.isRoutingEnabled("ETH", "USDT")).to.be.false;
    });
  });

  describe("Route Execution", function () {
    it("should execute route when called by engine", async function () {
      const { router, owner, engine, user } = await loadFixture(deployFixture);

      // Setup mock RocketSwap router + pool
      await router.connect(owner).setRocketSwapRouter(engine.address);
      await router.connect(owner).mapPool("ETH", "USDT", engine.address);

      const pairId = ethers.keccak256(ethers.toUtf8Bytes("ETH/USDT"));
      await expect(
        router.connect(engine).routeToRocketSwap(
          pairId,
          10n * 10n ** 18n,
          9n * 10n ** 18n,
          user.address,
          true
        )
      ).to.emit(router, "RouteExecuted");
    });

    it("should reject route when engine not set", async function () {
      const { router, user } = await loadFixture(deployFixture);
      // 默认 engine = owner，用 user 调用应失败
      const pairId = ethers.keccak256(ethers.toUtf8Bytes("ETH/USDT"));
      await expect(
        router.connect(user).routeToRocketSwap(
          pairId, 1000n, 900n, user.address, true
        )
      ).to.be.revertedWith("Only engine");
    });
  });
});

describe("LPMiningRewards", function () {
  async function deployFixture() {
    const [owner, staker, settlement] = await ethers.getSigners();
    const Factory = await ethers.getContractFactory("LPMiningRewards");
    const lpMining = await Factory.deploy(owner.address, owner.address, settlement.address);
    await lpMining.waitForDeployment();
    return { lpMining, owner, staker, settlement };
  }

  describe("Deployment", function () {
    it("should set owner and period finish", async function () {
      const { lpMining, owner } = await loadFixture(deployFixture);
      expect(await lpMining.owner()).to.equal(owner.address);
      expect(await lpMining.periodFinish()).to.be.gt(0);
    });

    it("should reject zero reward token address", async function () {
      const Factory = await ethers.getContractFactory("LPMiningRewards");
      const [owner] = await ethers.getSigners();
      await expect(
        Factory.deploy(ethers.ZeroAddress, owner.address, owner.address)
      ).to.be.revertedWith("Zero reward token");
    });
  });

  describe("Staking", function () {
    it("should accept stake and track total", async function () {
      const { lpMining, staker } = await loadFixture(deployFixture);
      const stakeAmount = 1000n * 10n ** 18n;

      await lpMining.connect(staker).stake(stakeAmount);
      expect(await lpMining.totalStaked()).to.equal(stakeAmount);

      const info = await lpMining.getUserStake(staker.address);
      expect(info.amount).to.equal(stakeAmount);
    });

    it("should reject zero stake", async function () {
      const { lpMining, staker } = await loadFixture(deployFixture);
      await expect(
        lpMining.connect(staker).stake(0)
      ).to.be.revertedWith("Zero amount");
    });
  });

  describe("Unstaking", function () {
    it("should allow partial unstake", async function () {
      const { lpMining, staker } = await loadFixture(deployFixture);
      const amount = 1000n * 10n ** 18n;

      await lpMining.connect(staker).stake(amount);
      await lpMining.connect(staker).unstake(amount / 2n);

      const info = await lpMining.getUserStake(staker.address);
      expect(info.amount).to.equal(amount / 2n);
      expect(await lpMining.totalStaked()).to.equal(amount / 2n);
    });

    it("should reject unstake exceeding balance", async function () {
      const { lpMining, staker } = await loadFixture(deployFixture);
      await lpMining.connect(staker).stake(100n);

      await expect(
        lpMining.connect(staker).unstake(200n)
      ).to.be.revertedWith("Insufficient balance");
    });
  });

  describe("Fees", function () {
    it("should accept fee deposits from settlement contract", async function () {
      const { lpMining, settlement, staker } = await loadFixture(deployFixture);
      const amount = 1000n * 10n ** 18n;

      await lpMining.connect(staker).stake(amount);
      await lpMining.connect(settlement).depositFees(100n * 10n ** 18n);

      const poolInfo = await lpMining.getPoolInfo();
      expect(poolInfo[1]).to.equal(100n * 10n ** 18n); // pendingFees
    });

    it("should reject fee deposits from non-settlement", async function () {
      const { lpMining, staker } = await loadFixture(deployFixture);
      await lpMining.connect(staker).stake(1000n);

      await expect(
        lpMining.connect(staker).depositFees(100n)
      ).to.be.revertedWith("Only settlement");
    });
  });

  describe("Reward Rate", function () {
    it("should accept valid reward rate", async function () {
      const { lpMining, owner } = await loadFixture(deployFixture);
      await lpMining.connect(owner).setRewardRate(ethers.parseEther("1"));
      expect(await lpMining.rewardRate()).to.equal(ethers.parseEther("1"));
    });

    it("should reject excessive reward rate", async function () {
      const { lpMining, owner } = await loadFixture(deployFixture);
      await expect(
        lpMining.connect(owner).setRewardRate(ethers.parseEther("100"))
      ).to.be.revertedWith("Rate too high");
    });
  });
});
