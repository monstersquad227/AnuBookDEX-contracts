import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";

describe("OrderBookRegistry", function () {
  async function deployFixture() {
    const [owner, engine] = await ethers.getSigners();
    const Registry = await ethers.getContractFactory("OrderBookRegistry");
    const registry = await Registry.deploy();
    return { registry, owner, engine };
  }

  it("should deploy with correct owner", async function () {
    const { registry, owner } = await loadFixture(deployFixture);
    expect(await registry.owner()).to.equal(owner.address);
  });

  it("should register a pair", async function () {
    const { registry } = await loadFixture(deployFixture);
    await registry.registerPair("ETH_USDT", "ETH", "USDT", 2, 6, 100, 100_000);

    const pair = await registry.pairs("ETH_USDT");
    expect(pair.baseAsset).to.equal("ETH");
    expect(pair.quoteAsset).to.equal("USDT");
    expect(pair.priceScale).to.equal(2);
    expect(pair.amountScale).to.equal(6);
    expect(pair.active).to.be.true;
  });

  it("should revert on duplicate pair", async function () {
    const { registry } = await loadFixture(deployFixture);
    await registry.registerPair("ETH_USDT", "ETH", "USDT", 2, 6, 100, 100_000);
    await expect(
      registry.registerPair("ETH_USDT", "ETH", "USDT", 2, 6, 100, 100_000)
    ).to.be.revertedWith("Pair exists");
  });

  it("should set pair active status", async function () {
    const { registry } = await loadFixture(deployFixture);
    await registry.registerPair("ETH_USDT", "ETH", "USDT", 2, 6, 100, 100_000);
    await registry.setPairActive("ETH_USDT", false);

    const pair = await registry.pairs("ETH_USDT");
    expect(pair.active).to.be.false;
  });

  it("should revert pair operations from non-owner", async function () {
    const { registry, engine } = await loadFixture(deployFixture);
    await expect(
      registry.connect(engine).registerPair("LINK_USDT", "LINK", "USDT", 2, 6, 100, 100_000)
    ).to.be.revertedWith("Only owner");
  });
});

describe("Settlement", function () {
  async function deployFixture() {
    const [owner, engine, alice] = await ethers.getSigners();
    const Settlement = await ethers.getContractFactory("Settlement");
    const settlement = await Settlement.deploy(5, 15, 30);
    await settlement.authorizeEngine(engine.address, true);
    return { settlement, owner, engine, alice };
  }

  it("should deploy with correct fees", async function () {
    const { settlement } = await loadFixture(deployFixture);
    expect(await settlement.makerFeeBps()).to.equal(5);
    expect(await settlement.takerFeeBps()).to.equal(15);
    expect(await settlement.protocolFeeBps()).to.equal(30);
  });

  it("should authorize engine", async function () {
    const { settlement, engine } = await loadFixture(deployFixture);
    expect(await settlement.authorizedEngines(engine.address)).to.be.true;
  });

  it("should reject unauthorized engine", async function () {
    const { settlement, alice } = await loadFixture(deployFixture);
    await expect(
      settlement.connect(alice).submitBatch([], "0x00", ethers.ZeroHash)
    ).to.be.revertedWith("Not authorized engine");
  });

  it("should reject empty batch", async function () {
    const { settlement, engine } = await loadFixture(deployFixture);
    await expect(
      settlement.connect(engine).submitBatch([], "0x00", ethers.ZeroHash)
    ).to.be.revertedWith("Empty batch");
  });

  it("should update fees", async function () {
    const { settlement } = await loadFixture(deployFixture);
    await settlement.setFees(10, 20, 40);
    expect(await settlement.makerFeeBps()).to.equal(10);
  });

  it("should reject fee above max", async function () {
    const { settlement } = await loadFixture(deployFixture);
    await expect(
      settlement.setFees(600, 20, 40)
    ).to.be.revertedWith("Fee too high");
  });

  it("should update max batch size", async function () {
    const { settlement } = await loadFixture(deployFixture);
    await settlement.setMaxBatchSize(50);
    expect(await settlement.maxBatchSize()).to.equal(50);
  });

  it("should return zero state root initially", async function () {
    const { settlement } = await loadFixture(deployFixture);
    expect(await settlement.getStateRoot()).to.equal(ethers.ZeroHash);
  });
});

describe("LeverageManager", function () {
  async function deployFixture() {
    const [owner, engine, alice] = await ethers.getSigners();

    const Settlement = await ethers.getContractFactory("Settlement");
    const settlement = await Settlement.deploy(5, 15, 30);

    const Leverage = await ethers.getContractFactory("LeverageManager");
    const leverage = await Leverage.deploy(await settlement.getAddress());
    await leverage.authorizeOracle(engine.address, true);

    // 设置初始价格
    await leverage.connect(engine).updateOraclePrice("ETH_USDT", ethers.parseEther("3000"));

    return { leverage, owner, engine, alice };
  }

  it("should deploy with correct params", async function () {
    const { leverage } = await loadFixture(deployFixture);
    expect(await leverage.maintenanceMarginBps()).to.equal(50);
    expect(await leverage.liquidationPenaltyBps()).to.equal(250);
  });

  it("should open position with sufficient margin", async function () {
    const { leverage, alice } = await loadFixture(deployFixture);
    const size = ethers.parseEther("1");    // 1 ETH
    const price = ethers.parseEther("3000");
    const leverageRatio = 5n;
    const margin = (price * size) / (leverageRatio * 10n ** 18n);

    await leverage.connect(alice).openPosition("ETH_USDT", true, size, Number(leverageRatio), {
      value: margin,
    });

    const pos = await leverage.getPosition(alice.address, "ETH_USDT");
    expect(pos.active).to.be.true;
    expect(pos.leverage).to.equal(5);
  });

  it("should reject leverage above max", async function () {
    const { leverage, alice } = await loadFixture(deployFixture);
    await expect(
      leverage.connect(alice).openPosition("ETH_USDT", true, ethers.parseEther("1"), 15, {
        value: ethers.parseEther("1000"),
      })
    ).to.be.revertedWith("Invalid leverage");
  });

  it("should reject insuffient margin", async function () {
    const { leverage, alice } = await loadFixture(deployFixture);
    await expect(
      leverage.connect(alice).openPosition("ETH_USDT", true, ethers.parseEther("1"), 10, {
        value: ethers.parseEther("1"), // way too little
      })
    ).to.be.revertedWith("Insufficient margin");
  });
});

describe("ZKKYC", function () {
  async function deployFixture() {
    const [owner, verifier, alice] = await ethers.getSigners();
    const ZKKYC = await ethers.getContractFactory("ZKKYC");
    const zkkyc = await ZKKYC.deploy();
    await zkkyc.authorizeVerifier(verifier.address, true);
    return { zkkyc, owner, verifier, alice };
  }

  it("should deploy with default thresholds", async function () {
    const { zkkyc } = await loadFixture(deployFixture);
    const t = await zkkyc.thresholds();
    expect(t.anonymousThreshold).to.equal(ethers.parseEther("0.1"));
    expect(t.pseudonymousThreshold).to.equal(ethers.parseEther("1"));
    expect(t.zkVerifiedThreshold).to.equal(ethers.parseEther("100"));
  });

  it("should classify L0 for small orders", async function () {
    const { zkkyc, alice } = await loadFixture(deployFixture);
    const [level, needsKYC] = await zkkyc.classifyOrder(alice.address, ethers.parseEther("0.05"));
    expect(level).to.equal(0);
    expect(needsKYC).to.be.false;
  });

  it("should add to sanction list", async function () {
    const { zkkyc, alice } = await loadFixture(deployFixture);
    await zkkyc.updateSanctionList(alice.address, true);
    expect(await zkkyc.sanctionList(alice.address)).to.be.true;
  });

  it("should update thresholds", async function () {
    const { zkkyc } = await loadFixture(deployFixture);
    await zkkyc.setThresholds(
      ethers.parseEther("0.5"),
      ethers.parseEther("5"),
      ethers.parseEther("500")
    );
    const t = await zkkyc.thresholds();
    expect(t.anonymousThreshold).to.equal(ethers.parseEther("0.5"));
  });

  it("should revert threshold order violation", async function () {
    const { zkkyc } = await loadFixture(deployFixture);
    await expect(
      zkkyc.setThresholds(
        ethers.parseEther("10"),   // L0L1 > L1L2 → invalid
        ethers.parseEther("5"),
        ethers.parseEther("500")
      )
    ).to.be.revertedWith("Invalid order");
  });
});
