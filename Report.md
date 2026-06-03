## 本地部署
AnuBookDEX-contracts % npx hardhat run scripts/deploy.ts --network hardhat
 ·------------------------|--------------------------------|--------------------------------·
 |  Solc version: 0.8.24  ·  Optimizer enabled: true       ·  Runs: 1000                    │
 ·························|································|·································
 |  Contract Name         ·  Deployed size (KiB) (change)  ·  Initcode size (KiB) (change)  │
 ·························|································|·································
 |  DarkPoolRouter        ·                 4.213 (0.000)  ·                 4.277 (0.000)  │
 ·························|································|·································
 |  LeverageManager       ·                 8.638 (0.000)  ·                 8.806 (0.000)  │
 ·························|································|·································
 |  LiquidityRouter       ·                 4.059 (0.000)  ·                 4.118 (0.000)  │
 ·························|································|·································
 |  LPMiningRewards       ·                 3.692 (0.000)  ·                 3.993 (0.000)  │
 ·························|································|·································
 |  OrderBookRegistry     ·                 5.080 (0.000)  ·                 5.169 (0.000)  │
 ·························|································|·································
 |  Settlement            ·                 4.668 (0.000)  ·                 4.887 (0.000)  │
 ·························|································|·································
 |  ZKKYC                 ·                 5.604 (0.000)  ·                 5.715 (0.000)  │
 ·------------------------|--------------------------------|--------------------------------·
Deployer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Engine: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Balance: 10000.0 ANUB

OrderBookRegistry: 0x5FbDB2315678afecb367f032d93F642f64180aa3
Settlement: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
LeverageManager: 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
DarkPoolRouter: 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
ZKKYC: 0x0165878A594ca255338adfa4d48449f69242Eb8F
LiquidityRouter: 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6
LPMiningRewards: 0x610178dA211FEF7D417bC0e6FeD39F05609AD788
  Pair: ETH_USDT
  Pair: BTC_USDT

=== All 7 contracts deployed ===

Deployed addresses:
  OrderBookRegistry: 0x5FbDB2315678afecb367f032d93F642f64180aa3
  Settlement:        0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
  LeverageManager:   0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
  DarkPoolRouter:    0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
  ZKKYC:             0x0165878A594ca255338adfa4d48449f69242Eb8F
  LiquidityRouter:   0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6
  LPMiningRewards:   0x610178dA211FEF7D417bC0e6FeD39F05609AD788

## Test
AnuBookDEX-contracts % npx hardhat test
 ·------------------------|--------------------------------|--------------------------------·
 |  Solc version: 0.8.24  ·  Optimizer enabled: true       ·  Runs: 1000                    │
 ·························|································|·································
 |  Contract Name         ·  Deployed size (KiB) (change)  ·  Initcode size (KiB) (change)  │
 ·························|································|·································
 |  DarkPoolRouter        ·                 4.213 (0.000)  ·                 4.277 (0.000)  │
 ·························|································|·································
 |  LeverageManager       ·                 8.638 (0.000)  ·                 8.806 (0.000)  │
 ·························|································|·································
 |  LiquidityRouter       ·                 4.059 (0.000)  ·                 4.118 (0.000)  │
 ·························|································|·································
 |  LPMiningRewards       ·                 3.692 (0.000)  ·                 3.993 (0.000)  │
 ·························|································|·································
 |  OrderBookRegistry     ·                 5.080 (0.000)  ·                 5.169 (0.000)  │
 ·························|································|·································
 |  Settlement            ·                 4.668 (0.000)  ·                 4.887 (0.000)  │
 ·························|································|·································
 |  ZKKYC                 ·                 5.604 (0.000)  ·                 5.715 (0.000)  │
 ·------------------------|--------------------------------|--------------------------------·


  DarkPoolRouter
    Deployment
      ✔ should set owner and default coordinator (234ms)
      ✔ should set default service fee to 30 bps
      ✔ should have MIN_ORDER_VALUE of 100k ether
    Intent Submission
      ✔ should accept intent above minimum order value
      ✔ should reject intent below minimum order value
      ✔ should reject intent with invalid price range
      ✔ should track multiple participants in a round
    Round Settlement
      ✔ should allow coordinator to settle a round
      ✔ should reject settlement from non-coordinator
      ✔ should reject duplicate settlement
      ✔ should collect service fees on settlement

  LiquidityRouter
    Deployment
      ✔ should set owner correctly
      ✔ should allow engine update
    Pool Mapping
      ✔ should map a pool for a trading pair
      ✔ should enable routing by default on map
      ✔ should toggle routing on/off
    Route Execution
      ✔ should execute route when called by engine
      ✔ should reject route when engine not set

  LPMiningRewards
    Deployment
      ✔ should set owner and period finish
      ✔ should reject zero reward token address
    Staking
      ✔ should accept stake and track total
      ✔ should reject zero stake
    Unstaking
      ✔ should allow partial unstake
      ✔ should reject unstake exceeding balance
    Fees
      ✔ should accept fee deposits from settlement contract
      ✔ should reject fee deposits from non-settlement
    Reward Rate
      ✔ should accept valid reward rate
      ✔ should reject excessive reward rate

  OrderBookRegistry
    ✔ should deploy with correct owner
    ✔ should register a pair
    ✔ should revert on duplicate pair
    ✔ should set pair active status
    ✔ should revert pair operations from non-owner

  Settlement
    ✔ should deploy with correct fees
    ✔ should authorize engine
    ✔ should reject unauthorized engine
    ✔ should reject empty batch
    ✔ should update fees
    ✔ should reject fee above max
    ✔ should update max batch size
    ✔ should return zero state root initially

  LeverageManager
    ✔ should deploy with correct params
    ✔ should open position with sufficient margin
    ✔ should reject leverage above max
    ✔ should reject insuffient margin

  ZKKYC
    ✔ should deploy with default thresholds
    ✔ should classify L0 for small orders
    ✔ should add to sanction list
    ✔ should update thresholds
    ✔ should revert threshold order violation


  50 passing (331ms)
