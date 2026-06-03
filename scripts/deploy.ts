import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  const engineAddress = process.env.ENGINE_ADDRESS || deployer.address;

  console.log("Deployer:", deployer.address);
  console.log("Engine:", engineAddress);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ANUB\n");

  // ═══ Level 1: 基础设施 ═══════════════════════════════

  // ─── 1. OrderBookRegistry ─────────────────────
  const Registry = await ethers.getContractFactory("OrderBookRegistry");
  const registry = await Registry.deploy();
  await registry.waitForDeployment();
  const registryAddr = await registry.getAddress();
  console.log("OrderBookRegistry:", registryAddr);

  // ─── 2. Settlement ───────────────────────────
  const makerFeeBps = 5;   // 0.05% maker rebate
  const takerFeeBps = 15;  // 0.15% taker fee
  const protocolBps  = 30; // 30% of fees → protocol

  const Settlement = await ethers.getContractFactory("Settlement");
  const settlement = await Settlement.deploy(makerFeeBps, takerFeeBps, protocolBps);
  await settlement.waitForDeployment();
  const settlementAddr = await settlement.getAddress();
  console.log("Settlement:", settlementAddr);
  await settlement.authorizeEngine(engineAddress, true);

  // ═══ Level 2: 交易 ═══════════════════════════════════

  // ─── 3. LeverageManager ──────────────────────
  const Leverage = await ethers.getContractFactory("LeverageManager");
  const leverage = await Leverage.deploy(settlementAddr);
  await leverage.waitForDeployment();
  const leverageAddr = await leverage.getAddress();
  console.log("LeverageManager:", leverageAddr);
  await leverage.authorizeOracle(engineAddress, true);

  // ─── 4. DarkPoolRouter ───────────────────────
  const DarkPool = await ethers.getContractFactory("DarkPoolRouter");
  const darkPool = await DarkPool.deploy();
  await darkPool.waitForDeployment();
  const darkPoolAddr = await darkPool.getAddress();
  console.log("DarkPoolRouter:", darkPoolAddr);

  // ═══ Level 3: 合规 ═══════════════════════════════════

  // ─── 5. ZKKYC ────────────────────────────────
  const ZKKYC = await ethers.getContractFactory("ZKKYC");
  const zkkyc = await ZKKYC.deploy();
  await zkkyc.waitForDeployment();
  const zkkycAddr = await zkkyc.getAddress();
  console.log("ZKKYC:", zkkycAddr);
  await zkkyc.authorizeVerifier(engineAddress, true);

  // ═══ Level 4: 生态 ═══════════════════════════════════

  // ─── 6. LiquidityRouter ──────────────────────
  const Liquidity = await ethers.getContractFactory("LiquidityRouter");
  const liquidity = await Liquidity.deploy();
  await liquidity.waitForDeployment();
  const liquidityAddr = await liquidity.getAddress();
  console.log("LiquidityRouter:", liquidityAddr);
  await liquidity.setAnubookSettlement(settlementAddr);

  // ─── 7. LPMiningRewards ──────────────────────
  // rewardToken + feeToken 使用环境变量或占位地址
  const rewardToken = process.env.REWARD_TOKEN || deployer.address;
  const feeToken    = process.env.FEE_TOKEN    || deployer.address;

  const LPMining = await ethers.getContractFactory("LPMiningRewards");
  const lpMining = await LPMining.deploy(rewardToken, feeToken, settlementAddr);
  await lpMining.waitForDeployment();
  const lpMiningAddr = await lpMining.getAddress();
  console.log("LPMiningRewards:", lpMiningAddr);

  // ═══ 注册初始交易对 ═══════════════════════════════════

  await registry.registerPair("ETH_USDT", "ETH", "USDT", 2, 6, 100, 100_000n);
  console.log("  Pair: ETH_USDT");
  await registry.registerPair("BTC_USDT", "BTC", "USDT", 1, 8, 10, 10_000n);
  console.log("  Pair: BTC_USDT");

  console.log("\n=== All 7 contracts deployed ===");
  console.log("\nDeployed addresses:");
  console.log(`  OrderBookRegistry: ${registryAddr}`);
  console.log(`  Settlement:        ${settlementAddr}`);
  console.log(`  LeverageManager:   ${leverageAddr}`);
  console.log(`  DarkPoolRouter:    ${darkPoolAddr}`);
  console.log(`  ZKKYC:             ${zkkycAddr}`);
  console.log(`  LiquidityRouter:   ${liquidityAddr}`);
  console.log(`  LPMiningRewards:   ${lpMiningAddr}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
