// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DarkPoolRouter
 * @notice MPC 暗池匿名撮合 — 轮次协调 & 结算记录
 * @dev 大额交易通过 MPC (SPDZ/Shamir) 链下匿名撮合，结果提交链上结算
 *
 * 工作流 (PRD 4.5):
 *   1. 用户提交暗池意向 (加密 Note + 价格区间)
 *   2. MPC 网络链下执行安全多方计算匹配
 *   3. MPC 协调节点提交结算结果 → 扣除服务费
 *
 * Anubis 特性利用:
 *   - Type 101 (Transfer): 完全隐私转账完成暗池结算
 *   - Type 100 (Shield): 结算后资产重新隐私化
 */
contract DarkPoolRouter {
    // ─── 常量 ──────────────────────────────

    /// @notice 暗池最低交易额 (10 万 USDT 等价)
    uint256 public constant MIN_ORDER_VALUE = 100_000 ether;

    /// @notice 费率分母 (基点)
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice 最大服务费率 5%
    uint256 public constant MAX_FEE_BPS = 500;

    /// @notice 单轮最大参与者
    uint256 public constant MAX_PARTICIPANTS = 100;

    // ─── 事件 ──────────────────────────────

    event DarkPoolIntent(
        uint256 indexed roundId,
        address indexed participant,
        bytes32 noteCommitment,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 amount
    );

    event DarkPoolRoundStarted(uint256 indexed roundId, uint256 timestamp, address coordinator);
    event DarkPoolRoundSettled(
        uint256 indexed roundId,
        bytes32 stateRoot,
        uint256 matchCount,
        uint256 totalVolume,
        uint256 feeCollected
    );
    event DarkPoolFeeWithdrawn(address indexed to, uint256 amount);
    event CoordinatorUpdated(address indexed previousCoordinator, address indexed newCoordinator);
    event ServiceFeeUpdated(uint256 oldBps, uint256 newBps);

    // ─── 状态 ──────────────────────────────

    address public owner;
    address public mpcCoordinator;

    /// @notice 暗池服务费率 (bps, 默认 30 = 0.3%)
    uint256 public serviceFeeBps = 30;

    /// @notice MPC 轮次计数
    uint256 public roundCount;

    /// @notice 累计暗池成交量
    uint256 public totalDarkVolume;

    /// @notice 累计暗池服务费
    uint256 public totalDarkFees;

    struct RoundSettlement {
        uint64  roundId;
        bytes32 stateRoot;
        uint256 totalVolume;
        uint256 feeCollected;
        uint256 timestamp;
        uint256 participantCount;
    }
    mapping(uint256 => RoundSettlement) public roundSettlements;

    /// @notice 轮次参与者
    mapping(uint256 => address[]) public roundParticipants;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyCoordinator() {
        require(msg.sender == mpcCoordinator, "Only coordinator");
        _;
    }

    constructor() {
        owner = msg.sender;
        mpcCoordinator = msg.sender;
    }

    // ─── 管理 ──────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    /**
     * @notice 设置 MPC 协调节点
     */
    function setCoordinator(address coordinator) external onlyOwner {
        require(coordinator != address(0), "Zero address");
        emit CoordinatorUpdated(mpcCoordinator, coordinator);
        mpcCoordinator = coordinator;
    }

    /**
     * @notice 设置暗池服务费率
     * @param bps 基点 (e.g. 30 = 0.3%)
     */
    function setServiceFee(uint256 bps) external onlyOwner {
        require(bps <= MAX_FEE_BPS, "Fee too high");
        emit ServiceFeeUpdated(serviceFeeBps, bps);
        serviceFeeBps = bps;
    }

    /**
     * @notice 提取累计服务费
     */
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero address");
        require(amount <= totalDarkFees, "Insufficient fees");
        totalDarkFees -= amount;
        payable(to).transfer(amount);
        emit DarkPoolFeeWithdrawn(to, amount);
    }

    // ─── 用户接口 ──────────────────────────

    /**
     * @notice 提交暗池交易意向
     * @dev 用户通过 Type 103 Call 提交加密意向
     * @param roundId        MPC 轮次 ID
     * @param noteCommitment 加密意向的 Note 承诺
     * @param minPrice       可接受最低成交价
     * @param maxPrice       可接受最高成交价
     * @param amount         交易金额
     */
    function submitIntent(
        uint256 roundId,
        bytes32 noteCommitment,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 amount
    ) external {
        require(amount >= MIN_ORDER_VALUE, "Below minimum order");
        require(minPrice > 0 && maxPrice >= minPrice, "Invalid price range");
        require(roundParticipants[roundId].length < MAX_PARTICIPANTS, "Round full");

        if (roundParticipants[roundId].length == 0) {
            emit DarkPoolRoundStarted(roundId, block.timestamp, msg.sender);
        }
        roundParticipants[roundId].push(msg.sender);

        emit DarkPoolIntent(roundId, msg.sender, noteCommitment, minPrice, maxPrice, amount);
    }

    // ─── 协调接口 (MPC 协调节点调用) ────────

    /**
     * @notice 提交 MPC 撮合结算结果
     * @dev MPC 链下计算完成后，协调节点调用上链
     * @param roundId   MPC 轮次 ID
     * @param stateRoot MPC 结算后状态根
     * @param matchCount 撮合成功笔数
     * @param totalVolume 本轮总成交量
     */
    function settleRound(
        uint256 roundId,
        bytes32 stateRoot,
        uint256 matchCount,
        uint256 totalVolume
    ) external onlyCoordinator {
        require(matchCount > 0, "No matches");
        require(roundParticipants[roundId].length > 0, "Round not started");
        require(roundSettlements[roundId].timestamp == 0, "Already settled");

        uint256 feeCollected = totalVolume * serviceFeeBps / BPS_DENOMINATOR;

        roundSettlements[roundId] = RoundSettlement({
            roundId:          uint64(roundId),
            stateRoot:        stateRoot,
            totalVolume:      totalVolume,
            feeCollected:     feeCollected,
            timestamp:        block.timestamp,
            participantCount: roundParticipants[roundId].length
        });

        roundCount++;
        totalDarkVolume += totalVolume;
        totalDarkFees += feeCollected;

        emit DarkPoolRoundSettled(roundId, stateRoot, matchCount, totalVolume, feeCollected);
    }

    // ─── 查询 ──────────────────────────────

    function getRoundSettlement(uint256 roundId) external view returns (RoundSettlement memory) {
        return roundSettlements[roundId];
    }

    function getRoundParticipants(uint256 roundId) external view returns (address[] memory) {
        return roundParticipants[roundId];
    }

    function getRoundParticipantCount(uint256 roundId) external view returns (uint256) {
        return roundParticipants[roundId].length;
    }

    function getStats() external view returns (
        uint256 rounds,
        uint256 volume,
        uint256 fees,
        uint256 feeRate
    ) {
        return (roundCount, totalDarkVolume, totalDarkFees, serviceFeeBps);
    }

    receive() external payable {}
}
