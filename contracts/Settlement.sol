// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Settlement
 * @notice 批量撮合结果验证 + Token 转账 + 费用分配
 * @dev 链下引擎提交 MatchResult[] + ZK Proof，合约验证后执行结算
 *
 * 核心流程:
 *   1. 链下引擎生成 PLONK 证明（撮合正确性）
 *   2. 调用 submitBatch(mrs, zkProof)
 *   3. 0x0100 预编译验证 ZK 证明
 *   4. 0x0103 预编译校验所有 Nullifier
 *   5. Token 结算（Unshield → EOA）
 *   6. 费用分配（maker/taker fee + protocol fee）
 */
contract Settlement {
    /// @notice 撮合结果（单笔）
    struct MatchResult {
        uint64  id;
        bytes32 orderId;
        address user;
        uint256 price;       // 成交价（最小精度单位）
        uint256 amount;      // 成交数量
        bytes32 nullifier;   // 订单唯一标识
        string  role;        // "maker" | "taker"
    }

    /// @notice 批量结算事件
    event BatchSettled(
        uint64 indexed batchId,
        bytes32 stateRoot,
        uint256 totalVolume,
        uint256 feeCollected
    );

    /// @notice 费用收取事件
    event FeeDistributed(
        address indexed recipient,
        uint256 amount,
        string feeType      // "maker_rebate" | "protocol" | "lp_reward"
    );

    /// @notice 提现事件（Unshield）
    event Unshielded(
        address indexed user,
        uint256 amount,
        bytes32 indexed settlementId
    );

    /// @notice 引擎授权事件
    event EngineAuthorized(address indexed engine, bool authorized);
    event BatchSizeUpdated(uint256 oldSize, uint256 newSize);

    // ─── Anubis 预编译合约 ──────────────────────
    address constant VERIFY_PROOF   = address(0x0100);
    address constant NULLIFIER_CHECK = address(0x0103);

    // ─── 状态 ─────────────────────────────────
    address public owner;
    uint64  public batchSeq;                            // 批次序号
    bytes32 public currentStateRoot;                     // 当前状态根
    mapping(bytes32 => bool) public settledNullifiers;   // 已结算的 Nullifier

    // 费用参数（基点：1 bp = 0.01%）
    uint256 public makerFeeBps;    // maker 费率（通常为负 = 返佣）
    uint256 public takerFeeBps;    // taker 费率
    uint256 public protocolFeeBps; // 协议费用率

    // 授权引擎地址（可多引擎并行）
    mapping(address => bool) public authorizedEngines;

    // 每个引擎的批次数
    mapping(address => uint256) public engineBatchCount;

    // 安全限制
    uint256 public maxBatchSize = 200;
    uint256 public constant MAX_FEE_BPS = 500; // 最大费率 5%

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyEngine() {
        require(authorizedEngines[msg.sender], "Not authorized engine");
        _;
    }

    constructor(uint256 _makerFeeBps, uint256 _takerFeeBps, uint256 _protocolFeeBps) {
        require(_makerFeeBps <= MAX_FEE_BPS && _takerFeeBps <= MAX_FEE_BPS, "Fee too high");
        owner = msg.sender;
        makerFeeBps = _makerFeeBps;
        takerFeeBps = _takerFeeBps;
        protocolFeeBps = _protocolFeeBps;
    }

    // ─── 引擎管理 ────────────────────────────

    function authorizeEngine(address engine, bool authorized) external onlyOwner {
        authorizedEngines[engine] = authorized;
        emit EngineAuthorized(engine, authorized);
    }

    function setMaxBatchSize(uint256 size) external onlyOwner {
        require(size >= 10 && size <= 500, "Invalid batch size");
        emit BatchSizeUpdated(maxBatchSize, size);
        maxBatchSize = size;
    }

    function setFees(uint256 _makerBps, uint256 _takerBps, uint256 _protocolBps) external onlyOwner {
        require(_makerBps <= MAX_FEE_BPS && _takerBps <= MAX_FEE_BPS, "Fee too high");
        makerFeeBps = _makerBps;
        takerFeeBps = _takerBps;
        protocolFeeBps = _protocolBps;
    }

    // ─── 批量结算（核心） ──────────────────────

    /**
     * @notice 提交批量撮合结果
     * @param results    撮合结果数组
     * @param zkProof    PLONK 证明（匹配正确性）
     * @param newRoot    撮合后新状态根
     */
    function submitBatch(
        MatchResult[] calldata results,
        bytes calldata zkProof,
        bytes32 newRoot
    )
        external
        onlyEngine
        returns (bytes32)
    {
        require(results.length > 0, "Empty batch");
        require(results.length <= maxBatchSize, "Batch too large");

        // ─── 1. ZK 证明验证（Anubis 0x0100 预编译） ───
        require(_verifyZKProof(zkProof, results, newRoot), "ZK proof failed");

        // ─── 2. Nullifier 防双花 ──────────────────
        for (uint256 i = 0; i < results.length; i++) {
            require(!settledNullifiers[results[i].nullifier], "Duplicate nullifier");

            // 调用 Anubis 0x0103 预编译
            (bool nullifierOk, ) = NULLIFIER_CHECK.staticcall(
                abi.encode(results[i].nullifier)
            );
            require(nullifierOk, "Nullifier check failed");

            settledNullifiers[results[i].nullifier] = true;
        }

        // ─── 3. Token 结算 ──────────────────────
        uint256 totalVolume;
        uint256 feeCollected;

        for (uint256 i = 0; i < results.length; i++) {
            MatchResult calldata mr = results[i];
            uint256 settlementValue = mr.price * mr.amount / 1e18;

            // Maker 收款（扣除 maker fee / 加上 maker rebate）
            if (_isMaker(mr.role)) {
                uint256 makerFee = settlementValue * makerFeeBps / 10000;
                uint256 receiveAmount = settlementValue > makerFee
                    ? settlementValue - makerFee
                    : 0;

                if (receiveAmount > 0) {
                    _unshield(mr.user, receiveAmount, mr.orderId);
                }
                if (makerFee > 0) {
                    feeCollected += makerFee;
                }
            }

            // Taker 不在此收款（taker 的 token 在撮合时已扣除）
            if (_isTaker(mr.role)) {
                uint256 takerFee = settlementValue * takerFeeBps / 10000;
                if (takerFee > 0) {
                    feeCollected += takerFee;
                }
            }

            totalVolume += settlementValue;
        }

        // ─── 4. 费用分配 ──────────────────────
        if (feeCollected > 0) {
            uint256 protocolShare = feeCollected * protocolFeeBps / 10000;
            uint256 lpShare = feeCollected - protocolShare;

            if (protocolShare > 0) {
                emit FeeDistributed(address(this), protocolShare, "protocol");
            }
            if (lpShare > 0) {
                emit FeeDistributed(address(this), lpShare, "lp_reward");
            }
        }

        // ─── 5. 更新状态根 ─────────────────────
        currentStateRoot = newRoot;
        batchSeq++;
        engineBatchCount[msg.sender]++;

        emit BatchSettled(batchSeq, newRoot, totalVolume, feeCollected);

        return newRoot;
    }

    // ─── 内部函数 ────────────────────────────

    /**
     * @dev 验证 PLONK 证明（调用 Anubis 0x0100 预编译）
     */
    function _verifyZKProof(
        bytes calldata zkProof,
        MatchResult[] calldata results,
        bytes32 newRoot
    ) internal view returns (bool) {
        // 构造公开输入：newRoot || resultsHash
        bytes32 resultsHash = keccak256(abi.encode(results));
        bytes memory publicInputs = abi.encode(newRoot, resultsHash, currentStateRoot);

        // 调用 Anubis 0x0100 VERIFY_PROOF
        // 输入 = proof || public_inputs
        bytes memory data = abi.encodePacked(zkProof, publicInputs);
        (bool success, bytes memory returnData) = VERIFY_PROOF.staticcall(data);

        if (!success || returnData.length < 32) {
            return false;
        }
        return abi.decode(returnData, (bool));
    }

    /**
     * @dev Unshield 代币（私有层 → 公开层 = Type 102 等价物）
     */
    function _unshield(address user, uint256 amount, bytes32 settlementId) internal {
        // 实际代币转账逻辑（ERC-20）
        // 如果是 Anubis 原生代币，使用 Type 102 (Unshield)
        emit Unshielded(user, amount, settlementId);
    }

    function _isMaker(string memory role) internal pure returns (bool) {
        return keccak256(bytes(role)) == keccak256(bytes("maker"));
    }

    function _isTaker(string memory role) internal pure returns (bool) {
        return keccak256(bytes(role)) == keccak256(bytes("taker"));
    }

    // ─── 查询 ───────────────────────────────

    /**
     * @notice 查询 Nullifier 是否已结算
     */
    function isSettled(bytes32 nullifier) external view returns (bool) {
        return settledNullifiers[nullifier];
    }

    /**
     * @notice 获取当前状态根（链下引擎恢复用）
     */
    function getStateRoot() external view returns (bytes32) {
        return currentStateRoot;
    }
}
