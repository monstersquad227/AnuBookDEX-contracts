// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LeverageManager
 * @notice 杠杆交易 — 保证金管理 / 持仓跟踪 / 强平执行
 * @dev 内聚完整风控逻辑，链下 ai.RiskEngine 并行监控
 *
 * 杠杆: 1-10x
 * 维持保证金率: 0.5% (50 bps)
 * 强平罚金: 2.5% (250 bps)
 * 强平奖励: 1.25% (125 bps，给清算人)
 */
contract LeverageManager {
    // ─── 数据结构 ──────────────────────────

    struct Position {
        address account;
        string  symbol;
        bool    isLong;        // true=long, false=short
        uint256 size;          // 持仓数量
        uint256 entryPrice;    // 开仓均价
        uint256 markPrice;     // 标记价格
        uint8   leverage;      // 1-10x
        uint256 margin;        // 保证金
        uint256 openBlock;     // 开仓区块
        bool    active;
    }

    struct LiquidationRecord {
        address account;
        string  symbol;
        uint256 size;
        uint256 price;
        uint256 loss;
        uint256 penalty;
        uint256 timestamp;
    }

    // ─── 事件 ──────────────────────────────

    event PositionOpened(
        address indexed account,
        string symbol,
        bool isLong,
        uint256 size,
        uint256 entryPrice,
        uint8 leverage
    );

    event PositionClosed(
        address indexed account,
        string symbol,
        uint256 pnl,
        bool isLiquidation
    );

    event MarginAdded(address indexed account, string symbol, uint256 amount);
    event MarginCalled(address indexed account, string symbol, uint256 required);
    event Liquidated(
        address indexed account,
        string symbol,
        uint256 size,
        uint256 price,
        uint256 loss,
        uint256 penalty
    );

    event OracleUpdated(string indexed symbol, uint256 price);
    event LeverageParamsUpdated(uint256 maintenanceBps, uint256 penaltyBps, uint256 rewardBps);

    // ─── 状态 ──────────────────────────────

    address public owner;
    address public settlementContract; // Settlement SC 地址（费用扣取）

    // 全局风控参数
    uint256 public maintenanceMarginBps = 50;   // 0.5%
    uint256 public liquidationPenaltyBps = 250;  // 2.5%
    uint256 public liquidatorRewardBps  = 125;   // 1.25%
    uint8   public constant MAX_LEVERAGE = 10;
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant PRECISION = 1e18;

    // 持仓（account → symbol → Position）
    mapping(address => mapping(string => Position)) public positions;

    // 标记价格（由预言机更新）
    mapping(string => uint256) public oraclePrices;

    // 授权预言机
    mapping(address => bool) public authorizedOracles;

    // 强平历史
    LiquidationRecord[] public liquidationHistory;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyOracle() {
        require(authorizedOracles[msg.sender], "Not authorized oracle");
        _;
    }

    constructor(address _settlementContract) {
        owner = msg.sender;
        settlementContract = _settlementContract;
    }

    // ─── 预言机管理 ────────────────────────

    function authorizeOracle(address oracle, bool authorized) external onlyOwner {
        authorizedOracles[oracle] = authorized;
    }

    /**
     * @notice 更新标记价格（由链下引擎推送上链）
     */
    function updateOraclePrice(string calldata symbol, uint256 price) external onlyOracle {
        require(price > 0, "Invalid price");
        oraclePrices[symbol] = price;
        emit OracleUpdated(symbol, price);

        // 更新所有该交易对的活跃仓位标记价格并检查风险
        // 注：链上遍历所有持仓不现实，由链下 ai.RiskEngine 做批量监控
    }

    // ─── 开仓 ──────────────────────────────

    /**
     * @notice 开立杠杆仓位
     * @param symbol    交易对
     * @param isLong    true=做多, false=做空
     * @param size      仓位大小
     * @param leverage  杠杆倍数 (1-10)
     */
    function openPosition(
        string calldata symbol,
        bool isLong,
        uint256 size,
        uint8 leverage
    ) external payable {
        require(leverage >= 1 && leverage <= MAX_LEVERAGE, "Invalid leverage");
        require(size > 0, "Size zero");
        require(!positions[msg.sender][symbol].active, "Position exists");

        uint256 entryPrice = oraclePrices[symbol];
        require(entryPrice > 0, "No oracle price");

        // 计算所需保证金 = price * size / 1e18 / leverage
        uint256 requiredMargin = entryPrice * size / PRECISION / uint256(leverage);
        require(msg.value >= requiredMargin, "Insufficient margin");

        // 退还多余保证金
        if (msg.value > requiredMargin) {
            payable(msg.sender).transfer(msg.value - requiredMargin);
        }

        positions[msg.sender][symbol] = Position({
            account:    msg.sender,
            symbol:     symbol,
            isLong:     isLong,
            size:       size,
            entryPrice: entryPrice,
            markPrice:  entryPrice,
            leverage:   leverage,
            margin:     requiredMargin,
            openBlock:  block.number,
            active:     true
        });

        emit PositionOpened(msg.sender, symbol, isLong, size, entryPrice, leverage);
    }

    // ─── 追加保证金 ────────────────────────

    function addMargin(string calldata symbol) external payable {
        Position storage pos = positions[msg.sender][symbol];
        require(pos.active, "No position");
        pos.margin += msg.value;
        emit MarginAdded(msg.sender, symbol, msg.value);
    }

    // ─── 平仓 ──────────────────────────────

    /**
     * @notice 平仓（用户主动）
     */
    function closePosition(string calldata symbol) external {
        Position storage pos = positions[msg.sender][symbol];
        require(pos.active, "No position");

        uint256 currentPrice = oraclePrices[symbol];
        require(currentPrice > 0, "No oracle price");

        int256 pnl = _calcPnL(pos, currentPrice);
        uint256 returnAmount = _settlePosition(pos, currentPrice, false);

        delete positions[msg.sender][symbol];

        emit PositionClosed(msg.sender, symbol, uint256(pnl >= 0 ? int256(0) : -pnl), false);
    }

    // ─── 强平 ──────────────────────────────

    /**
     * @notice 清算水下仓位（任何人可调用，清算人获取奖励）
     */
    function liquidate(address account, string calldata symbol) external {
        Position storage pos = positions[account][symbol];
        require(pos.active, "No position");

        uint256 currentPrice = oraclePrices[symbol];
        require(currentPrice > 0, "No oracle price");

        // 检查是否达到强平条件
        require(_isLiquidatable(pos, currentPrice), "Not liquidatable");

        uint256 loss = _calcLiquidationLoss(pos, currentPrice);
        uint256 penalty = pos.size * currentPrice * liquidationPenaltyBps / BPS_DENOMINATOR / PRECISION;
        uint256 reward = penalty * liquidatorRewardBps / BPS_DENOMINATOR;

        // 清算人获得罚金中的奖励部分
        if (reward > 0) {
            payable(msg.sender).transfer(reward);
        }

        _settlePosition(pos, currentPrice, true);
        delete positions[account][symbol];

        liquidationHistory.push(LiquidationRecord({
            account:   account,
            symbol:    symbol,
            size:      pos.size,
            price:     currentPrice,
            loss:      loss,
            penalty:   penalty,
            timestamp: block.timestamp
        }));

        emit Liquidated(account, symbol, pos.size, currentPrice, loss, penalty);
        emit PositionClosed(account, symbol, loss, true);
    }

    // ─── 内部函数 ──────────────────────────

    /**
     * @dev 计算盈亏
     */
    function _calcPnL(Position storage pos, uint256 currentPrice) internal view returns (int256) {
        if (pos.isLong) {
            // long: PnL = (currentPrice - entryPrice) * size / 1e18
            if (currentPrice >= pos.entryPrice) {
                return int256((currentPrice - pos.entryPrice) * pos.size / PRECISION);
            } else {
                return -int256((pos.entryPrice - currentPrice) * pos.size / PRECISION);
            }
        } else {
            // short: PnL = (entryPrice - currentPrice) * size / 1e18
            if (pos.entryPrice >= currentPrice) {
                return int256((pos.entryPrice - currentPrice) * pos.size / PRECISION);
            } else {
                return -int256((currentPrice - pos.entryPrice) * pos.size / PRECISION);
            }
        }
    }

    /**
     * @dev 结算仓位，返回返还金额
     */
    function _settlePosition(
        Position storage pos,
        uint256 currentPrice,
        bool isLiquidation
    ) internal returns (uint256 returnAmount) {
        int256 pnl = _calcPnL(pos, currentPrice);
        uint256 margin = pos.margin;

        if (pnl >= 0) {
            // 盈利 = margin + profit
            returnAmount = margin + uint256(pnl);
        } else {
            uint256 loss = uint256(-pnl);
            if (loss >= margin) {
                // 亏损超过保证金 → 全损
                returnAmount = 0;
            } else {
                // 部分亏损
                returnAmount = margin - loss;
            }
        }

        // 强平罚金从返还中扣除
        if (isLiquidation && returnAmount > 0) {
            uint256 penalty = pos.size * currentPrice * liquidationPenaltyBps / BPS_DENOMINATOR / PRECISION;
            if (returnAmount > penalty) {
                returnAmount -= penalty;
            } else {
                returnAmount = 0;
            }
        }

        if (returnAmount > 0) {
            payable(pos.account).transfer(returnAmount);
        }
    }

    /**
     * @dev 判断是否达到强平条件
     * maintenanceMargin = positionValue * maintenanceMarginBps / BPS_DENOMINATOR
     * 强平条件: unrealizedLoss + maintenanceMargin > margin
     */
    function _isLiquidatable(Position storage pos, uint256 currentPrice) internal view returns (bool) {
        int256 pnl = _calcPnL(pos, currentPrice);
        if (pnl >= 0) return false; // 盈利不平仓

        uint256 loss = uint256(-pnl);
        uint256 positionValue = pos.size * currentPrice / PRECISION;
        uint256 maintenanceMargin = positionValue * maintenanceMarginBps / BPS_DENOMINATOR;

        // 亏损 + 维持保证金 > 当前保证金 → 强平
        return loss + maintenanceMargin > pos.margin;
    }

    /**
     * @dev 计算强平损失
     */
    function _calcLiquidationLoss(Position storage pos, uint256 currentPrice) internal view returns (uint256) {
        int256 pnl = _calcPnL(pos, currentPrice);
        if (pnl >= 0) return 0;
        return uint256(-pnl);
    }

    // ─── 管理函数 ──────────────────────────

    function setLeverageParams(uint256 _maintenanceBps, uint256 _penaltyBps, uint256 _rewardBps) external onlyOwner {
        require(_maintenanceBps <= 1000, "Maint. margin too high"); // max 10%
        require(_penaltyBps <= 1000, "Penalty too high");
        maintenanceMarginBps = _maintenanceBps;
        liquidationPenaltyBps = _penaltyBps;
        liquidatorRewardBps = _rewardBps;
        emit LeverageParamsUpdated(_maintenanceBps, _penaltyBps, _rewardBps);
    }

    // ─── 查询 ──────────────────────────────

    function getPosition(address account, string calldata symbol) external view returns (Position memory) {
        return positions[account][symbol];
    }

    function getLiquidationCount() external view returns (uint256) {
        return liquidationHistory.length;
    }

    /**
     * @notice 检查仓位是否面临强平风险
     */
    function checkLiquidationRisk(address account, string calldata symbol) external view returns (
        bool liquidatable,
        int256 unrealizedPnL,
        uint256 liquidationPrice
    ) {
        Position storage pos = positions[account][symbol];
        if (!pos.active) return (false, 0, 0);

        uint256 currentPrice = oraclePrices[symbol];
        unrealizedPnL = _calcPnL(pos, currentPrice);

        // 强平价格计算
        // long: liqPrice = entryPrice * (1 - 1/leverage + maintenanceMarginBps/BPS)
        // short: liqPrice = entryPrice * (1 + 1/leverage - maintenanceMarginBps/BPS)
        uint256 maintenanceRatio = maintenanceMarginBps * 1e18 / BPS_DENOMINATOR;
        if (pos.isLong) {
            uint256 buffer = (1e18 / uint256(pos.leverage)) + maintenanceRatio;
            liquidationPrice = pos.entryPrice * (1e18 - buffer) / 1e18;
        } else {
            uint256 buffer = (1e18 / uint256(pos.leverage)) - maintenanceRatio;
            liquidationPrice = pos.entryPrice * (1e18 + buffer) / 1e18;
        }

        liquidatable = _isLiquidatable(pos, currentPrice);
    }
}
