// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LPMiningRewards
 * @notice LP Token 质押 & 手续费分红 & 生态代币奖励
 * @dev 为订单簿提供流动性的 LP 获得:
 *   - 平台交易手续费分红 (按质押占比)
 *   - ANUB 生态代币奖励 (按区块释放速率)
 *
 * 奖励机制:
 *   - 手续费分红: 按用户质押占全局质押比例分配
 *   - 代币奖励: 按 rewardRate 每区块释放，按质押权重分配
 *   - 双累积器防双领
 *
 * 链下 AI (ai/engine.go) 辅助测算最优做市配比
 */
contract LPMiningRewards {
    // ─── 常量 ──────────────────────────────

    uint256 public constant PRECISION = 1e18;
    uint256 public constant REWARD_PERIOD = 7 days;     // 每奖励周期 7 天
    uint256 public constant MAX_REWARD_RATE = 10 ether;  // 最大 10 ANUB/s

    // ─── 数据结构 ──────────────────────────

    struct StakeInfo {
        uint256 amount;       // 质押 LP Token 数量
        uint256 startTime;    // 质押开始时间戳
        uint256 rewardDebt;   // 已结算代币奖励债务
        uint256 feeDebt;      // 已结算手续费债务
    }

    // ─── 事件 ──────────────────────────────

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);
    event FeeClaimed(address indexed user, uint256 fee);
    event FeesDeposited(uint256 amount, address indexed from);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);
    event RewardTokensDeposited(uint256 amount);

    // ─── 状态 ──────────────────────────────

    address public owner;
    address public rewardToken;        // ANUB 代币
    address public feeToken;           // 手续费代币 (USDT)
    address public settlementContract; // Settlement SC (只能从此接收手续费)

    /// @notice 全局 LP Token 质押总量
    uint256 public totalStaked;

    /// @notice 当前奖励周期开始时间
    uint256 public periodFinish;

    /// @notice 代币奖励释放速率 (per second)
    uint256 public rewardRate;

    /// @notice 每份额累积奖励 (rewardPerShare)
    uint256 public accRewardPerShare;

    /// @notice 每份额累积手续费
    uint256 public accFeePerShare;

    /// @notice 用户质押数据
    mapping(address => StakeInfo) public stakes;

    /// @notice 未分配手续费池
    uint256 public pendingFeePool;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /**
     * @dev 更新累积器 + 用户待领收益
     */
    modifier updateRewards(address user) {
        _updateAccumulators();
        StakeInfo storage s = stakes[user];
        if (s.amount > 0) {
            // 累积用户待领取
            // (收益在 claimReward/claimFee 时提取)
        }
        _;
    }

    constructor(address _rewardToken, address _feeToken, address _settlement) {
        require(_rewardToken != address(0), "Zero reward token");
        owner = msg.sender;
        rewardToken = _rewardToken;
        feeToken = _feeToken;
        settlementContract = _settlement;
        periodFinish = block.timestamp;
    }

    // ─── 管理 ──────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    /**
     * @notice 设置奖励速率 + 充值 ANUB 代币池
     * @param rate 每秒释放数量
     */
    function setRewardRate(uint256 rate) external onlyOwner {
        require(rate <= MAX_REWARD_RATE, "Rate too high");
        _updateAccumulators();
        emit RewardRateUpdated(rewardRate, rate);
        rewardRate = rate;
    }

    /**
     * @notice 向奖励池充值 (需要 approve 此合约)
     * @param amount 充值的 ANUB 数量
     */
    function depositRewardTokens(uint256 amount) external onlyOwner {
        require(amount > 0, "Zero amount");
        // 生产环境: IERC20(rewardToken).transferFrom(msg.sender, address(this), amount);
        periodFinish = block.timestamp + REWARD_PERIOD;
        emit RewardTokensDeposited(amount);
    }

    /**
     * @notice 从 Settlement 合约接收手续费
     * @dev 仅 Settlement SC 可调用
     */
    function depositFees(uint256 amount) external {
        require(msg.sender == settlementContract, "Only settlement");
        require(amount > 0, "Zero amount");
        if (totalStaked > 0) {
            pendingFeePool += amount;
            accFeePerShare += amount * PRECISION / totalStaked;
        }
        emit FeesDeposited(amount, msg.sender);
    }

    // ─── 质押 ──────────────────────────────

    /**
     * @notice 质押 LP Token
     * @param amount 质押数量
     */
    function stake(uint256 amount) external updateRewards(msg.sender) {
        require(amount > 0, "Zero amount");
        // 生产环境: IERC20(lpToken).transferFrom(msg.sender, address(this), amount);

        StakeInfo storage s = stakes[msg.sender];
        if (s.amount == 0) {
            s.startTime = block.timestamp;
        }
        s.amount += amount;
        totalStaked += amount;

        // 更新用户债务 (防双领)
        s.rewardDebt = s.amount * accRewardPerShare / PRECISION;
        s.feeDebt = s.amount * accFeePerShare / PRECISION;

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice 赎回 LP Token
     * @param amount 赎回数量
     */
    function unstake(uint256 amount) external updateRewards(msg.sender) {
        require(amount > 0, "Zero amount");
        StakeInfo storage s = stakes[msg.sender];
        require(amount <= s.amount, "Insufficient balance");

        s.amount -= amount;
        totalStaked -= amount;

        // 生产环境: IERC20(lpToken).transfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    // ─── 领取收益 ──────────────────────────

    /**
     * @notice 提取 ANUB 代币奖励
     */
    function claimReward() external updateRewards(msg.sender) returns (uint256 reward) {
        StakeInfo storage s = stakes[msg.sender];
        reward = _pendingReward(msg.sender);
        require(reward > 0, "No reward");

        s.rewardDebt = s.amount * accRewardPerShare / PRECISION;

        // 生产环境: IERC20(rewardToken).transfer(msg.sender, reward);
        emit RewardClaimed(msg.sender, reward);
    }

    /**
     * @notice 提取手续费分红
     */
    function claimFee() external updateRewards(msg.sender) returns (uint256 fee) {
        StakeInfo storage s = stakes[msg.sender];
        fee = pendingFee(msg.sender);
        require(fee > 0, "No fee");

        s.feeDebt = s.amount * accFeePerShare / PRECISION;

        // 生产环境: IERC20(feeToken).transfer(msg.sender, fee);
        emit FeeClaimed(msg.sender, fee);
    }

    /**
     * @notice 一键提取所有收益
     */
    function claimAll() external {
        claimReward();
        claimFee();
    }

    // ─── 查询 ──────────────────────────────

    /**
     * @notice 查询待领取的 ANUB 奖励
     */
    function pendingReward(address user) public view returns (uint256) {
        return _pendingReward(user);
    }

    /**
     * @notice 查询待领取的手续费分红
     */
    function pendingFee(address user) public view returns (uint256) {
        StakeInfo storage s = stakes[user];
        if (s.amount == 0) return 0;
        uint256 acc = accFeePerShare;
        return s.amount * acc / PRECISION - s.feeDebt;
    }

    function getUserStake(address user) external view returns (StakeInfo memory) {
        return stakes[user];
    }

    function getPoolInfo() external view returns (
        uint256 staked,
        uint256 pendingFees,
        uint256 rate,
        uint256 finish
    ) {
        return (totalStaked, pendingFeePool, rewardRate, periodFinish);
    }

    // ─── 内部 ──────────────────────────────

    function _pendingReward(address user) internal view returns (uint256) {
        StakeInfo storage s = stakes[user];
        if (s.amount == 0) return 0;
        uint256 acc = accRewardPerShare;
        if (block.timestamp > periodFinish && totalStaked > 0 && rewardRate > 0) {
            uint256 elapsed = block.timestamp - periodFinish;
            // periodFinish 之后的额外时间
            uint256 extraReward = elapsed * rewardRate;
            acc += extraReward * PRECISION / totalStaked;
        }
        return s.amount * acc / PRECISION - s.rewardDebt;
    }

    /**
     * @dev 更新累积奖励/费率指标
     */
    function _updateAccumulators() internal {
        if (block.timestamp <= periodFinish || totalStaked == 0 || rewardRate == 0) {
            return;
        }
        uint256 elapsed = block.timestamp - periodFinish;
        uint256 newReward = elapsed * rewardRate;
        accRewardPerShare += newReward * PRECISION / totalStaked;
    }
}
