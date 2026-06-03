# AnuBookDEX Contracts

Solidity 合约套件（Hardhat + TypeScript），部署于 Anubis Chain (EVM)。

## 合约清单

| 合约 | 职责 | Anubis 特性 | 状态 |
|------|------|------------|------|
| `OrderBookRegistry` | 交易对注册 + 接收 Type 103 隐私订单 | `0x0103` NULLIFIER_CHECK | ✅ |
| `Settlement` | 批量撮合结算 + ZK 证明验证 | `0x0100` VERIFY_PROOF + `0x0103` | ✅ |
| `LeverageManager` | 杠杆交易 (1-10x) / 保证金 / 强平 | 预言机价格更新 | ✅ |
| `DarkPoolRouter` | MPC 暗池轮次协调大额匿名撮合 | Type 101 Transfer | ✅ |
| `ZKKYC` | 4 级隐私模型 (匿名/假名/ZK-KYC/合规) | `0x0100` VERIFY_PROOF | ✅ |
| `LiquidityRouter` | AnuBook ↔ RocketSwap AMM 智能路由 | 跨协议流动性 | ✅ |
| `LPMiningRewards` | LP Token 质押 + 手续费分红 + ANUB 挖矿 | 双累积器防双领 | ✅ |

## 开发

```bash
npm install
npx hardhat compile
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat size-contracts
```

## 部署

```bash
# Anubis 测试网
ANUBIS_TESTNET_RPC=<rpc-url> PRIVATE_KEY=<key> npm run deploy:testnet

# Anubis 主网
ANUBIS_MAINNET_RPC=<rpc-url> PRIVATE_KEY=<key> npm run deploy:mainnet
```

部署顺序: 基础设施 (Registry + Settlement) → 交易 (Leverage + DarkPool) → 合规 (ZKKYC) → 生态 (Router + LP Mining)

## ABI 导出 → Go Bindings

```bash
npm run export-abi
```

编译后的 ABI JSON 自动复制到 `../AnuBookDEX/contracts/abi/`，Go 端运行:

```bash
cd ../AnuBookDEX
abigen --abi=contracts/abi/OrderBookRegistry.json --pkg=bindings --out=contracts/bindings/order_book_registry.go
abigen --abi=contracts/abi/Settlement.json --pkg=bindings --out=contracts/bindings/settlement.go
abigen --abi=contracts/abi/LeverageManager.json --pkg=bindings --out=contracts/bindings/leverage_manager.go
abigen --abi=contracts/abi/DarkPoolRouter.json --pkg=bindings --out=contracts/bindings/dark_pool_router.go
abigen --abi=contracts/abi/ZKKYC.json --pkg=bindings --out=contracts/bindings/zkkyc.go
abigen --abi=contracts/abi/LiquidityRouter.json --pkg=bindings --out=contracts/bindings/liquidity_router.go
abigen --abi=contracts/abi/LPMiningRewards.json --pkg=bindings --out=contracts/bindings/lp_mining_rewards.go
```

## 项目结构

```
├── contracts/
│   ├── OrderBookRegistry.sol   # 交易对 + Type 103 隐私订单
│   ├── Settlement.sol          # 批量撮合结算 + 0x0100 ZK 验证
│   ├── LeverageManager.sol     # 杠杆 1-10x + 强平
│   ├── DarkPoolRouter.sol      # MPC 暗池轮次协调
│   ├── ZKKYC.sol               # 4 级隐私 + 合规审计
│   ├── LiquidityRouter.sol     # AnuBook ↔ RocketSwap 路由
│   └── LPMiningRewards.sol     # LP 质押 + 手续费分红 + 挖矿
├── scripts/
│   ├── deploy.ts               # 一键部署 7 合约
│   └── export-abi.ts           # ABI → Go 项目 (7 合约)
├── test/
│   ├── Settlement.test.ts      # 原有 4 合约测试 (22 cases)
│   └── NewContracts.test.ts    # 新 3 合约测试 (19 cases)
├── hardhat.config.ts
├── package.json
└── .gitignore
```

## Anubis 预编译合约

| 地址 | 功能 | 使用位置 |
|------|------|---------|
| `0x0100` | PLONK 证明验证 (双线性配对) | Settlement, ZKKYC |
| `0x0103` | Nullifier 防双花检查 | OrderBookRegistry, Settlement |

## 隐私交易类型

| Type | 说明 | 使用场景 |
|------|------|---------|
| Type 103 (Contract Call) | 花隐私币调用 EVM 合约 | 提交加密订单到 Registry |
| Type 102 (Unshield) | 私有→公开提现 | Settlement 结算 |
| Type 101 (Transfer) | 完全隐私转账 | DarkPoolRouter 暗池 |
| Type 100 (Shield) | 公开→隐私铸造 | 充值后隐私化资产 |

## Go 引擎集成

链下 Go 引擎通过事件订阅 + 合约调用交互:

- `OrderBookRegistry.OrderSubmitted` → `chain/subscriber.go` → 解密 Note → 撮合
- `Settlement.submitBatch` ← `chain/settlement.go` → ZK 结算上链
- `LeverageManager.openPosition` ← `chain/leverage.go` → 杠杆风控联动
- `LiquidityRouter.routeToRocketSwap` ← `ai/engine.go` → AI 路由决策
