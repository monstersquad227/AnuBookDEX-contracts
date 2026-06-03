// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ZKKYC
 * @notice 分级隐私验证 + Merkle 树管理 + 合规审计接口
 * @dev 基于 Anubis ZK-KYC 框架，实现：
 *   - 小额匿名 (Type 101 Transfer, 无需 KYC)
 *   - 中额假名 (Type 103 Contract Call, 加密订单)
 *   - 大额 ZK-KYC (Type 103 + ZK 身份证明)
 *   - 机构级合规披露 (FATF/MiCA/DAC8)
 *
 * 隐私四级模型:
 *   L0: 完全匿名 — < 0.1 ETH 等价物
 *   L1: 假名      — < 1 ETH 等价物
 *   L2: ZK-KYC   — < 100 ETH 等价物
 *   L3: 合规披露  — >= 100 ETH 等价物
 */
contract ZKKYC {
    // ─── 数据结构 ──────────────────────────

    /// @notice KYC 证明
    struct KYCProof {
        bytes32 proofHash;        // ZK 证明哈希
        bytes32 countryCode;      // ISO 3166-1 alpha-2 (bytes32 编码)
        uint64  verifiedAt;       // 验证时间戳
        uint64  expiresAt;        // 过期时间戳
        uint8   verificationLevel; // 验证级别 0-3
        bool    isRevoked;        // 是否已撤销
    }

    /// @notice 分级阈值
    struct PrivacyThresholds {
        uint256 anonymousThreshold;    // L0 → L1 边界 (ETH 最小单位)
        uint256 pseudonymousThreshold; // L1 → L2
        uint256 zkVerifiedThreshold;   // L2 → L3
    }

    /// @notice 审计日志条目（不泄露交易细节）
    struct AuditEntry {
        uint256 timestamp;
        uint256 blockNumber;
        uint8   privacyLevel;    // 0-3
        bytes32 txnHash;         // 交易哈希（不包含价格/数量/交易对）
        bytes32 userId;          // 匿名化用户 ID
    }

    // ─── 事件 ──────────────────────────────

    event KYCVerified(address indexed user, bytes32 proofHash, uint8 level);
    event KYCRevoked(address indexed user, bytes32 proofHash);
    event ThresholdsUpdated(uint256 l0l1, uint256 l1l2, uint256 l2l3);
    event AuditLogged(bytes32 indexed entryHash, uint8 privacyLevel);
    event SanctionListUpdated(address indexed account, bool sanctioned);
    event VerifierAuthorized(address indexed verifier, bool authorized);
    event MerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);

    // ─── 状态 ──────────────────────────────

    address public owner;

    // KYC 状态
    mapping(address => KYCProof) public kycProofs;
    mapping(address => bool) public isKYCVerified;

    // 隐私阈值
    PrivacyThresholds public thresholds;

    // Merkle 树根（KYC 证明的匿名集合）
    bytes32 public merkleRoot;

    // 审计日志
    AuditEntry[] public auditLog;
    mapping(bytes32 => uint256) public auditIndex; // entryHash → index

    // 制裁名单（AML/FATF 合规）
    mapping(address => bool) public sanctionList;

    // 授权验证者
    mapping(address => bool) public authorizedVerifiers;

    // 已使用的 Nullifier（防重复验证）
    mapping(bytes32 => bool) public usedNullifiers;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyVerifier() {
        require(authorizedVerifiers[msg.sender], "Not authorized verifier");
        _;
    }

    constructor() {
        owner = msg.sender;
        // 默认阈值
        thresholds = PrivacyThresholds({
            anonymousThreshold:    0.1 ether,   // <  0.1 ETH  → L0
            pseudonymousThreshold: 1 ether,     // <  1 ETH    → L1
            zkVerifiedThreshold:   100 ether     // <  100 ETH  → L2
        });
    }

    // ─── KYC 验证 ──────────────────────────

    /**
     * @notice 提交 ZK-KYC 身份证明
     * @param user         被验证用户地址
     * @param proofHash    ZK 证明哈希
     * @param countryCode  国家代码
     * @param validityDays 有效期（天）
     * @param level        验证级别
     * @param zkProof      完整的 ZK 证明数据
     * @param nullifier    唯一性标识（防重用）
     */
    function verifyKYC(
        address user,
        bytes32 proofHash,
        bytes32 countryCode,
        uint64 validityDays,
        uint8 level,
        bytes calldata zkProof,
        bytes32 nullifier
    ) external onlyVerifier {
        require(!usedNullifiers[nullifier], "Nullifier used");
        require(!sanctionList[user], "User sanctioned");
        require(level <= 3, "Invalid level");

        // ─── ZK 证明验证（Anubis 0x0100 预编译） ───
        bytes memory inputs = abi.encode(user, proofHash, countryCode, level, nullifier);
        (bool proofOk, ) = VERIFY_PROOF.staticcall(abi.encodePacked(zkProof, inputs));
        require(proofOk, "ZK proof invalid");

        usedNullifiers[nullifier] = true;

        kycProofs[user] = KYCProof({
            proofHash:         proofHash,
            countryCode:       countryCode,
            verifiedAt:        uint64(block.timestamp),
            expiresAt:         uint64(block.timestamp + validityDays * 1 days),
            verificationLevel: level,
            isRevoked:         false
        });
        isKYCVerified[user] = true;

        emit KYCVerified(user, proofHash, level);
    }

    /**
     * @notice 撤销 KYC
     */
    function revokeKYC(address user) external onlyOwner {
        require(isKYCVerified[user], "Not verified");

        KYCProof storage proof = kycProofs[user];
        proof.isRevoked = true;
        isKYCVerified[user] = false;

        emit KYCRevoked(user, proof.proofHash);
    }

    // ─── 隐私等级判定 ──────────────────────

    /**
     * @notice 根据订单金额和用户 KYC 状态判定隐私等级
     * @return level  0-3 (L0=匿名, L1=假名, L2=ZK-KYC, L3=合规)
     * @return needsKYC 是否需要额外 KYC 验证
     */
    function classifyOrder(
        address user,
        uint256 orderValue
    ) external view returns (uint8 level, bool needsKYC) {
        // 制裁检查
        require(!sanctionList[user], "User sanctioned");

        if (orderValue < thresholds.anonymousThreshold) {
            // L0: 完全匿名 — 任何人都可以
            return (0, false);
        }

        if (orderValue < thresholds.pseudonymousThreshold) {
            // L1: 假名 — 需要地址但不需 KYC
            return (1, false);
        }

        // L2/L3: 需要 KYC 验证
        KYCProof storage proof = kycProofs[user];
        require(isKYCVerified[user] && !proof.isRevoked, "KYC required");
        require(block.timestamp <= proof.expiresAt, "KYC expired");

        if (orderValue < thresholds.zkVerifiedThreshold) {
            return (2, true);
        }

        // L3: 合规披露
        return (3, true);
    }

    // ─── 制裁名单 ──────────────────────────

    /**
     * @notice 更新制裁名单（AML/FATF 合规）
     */
    function updateSanctionList(address account, bool sanctioned) external onlyOwner {
        sanctionList[account] = sanctioned;
        emit SanctionListUpdated(account, sanctioned);
    }

    /**
     * @notice 批量更新制裁名单
     */
    function batchUpdateSanctions(address[] calldata accounts, bool sanctioned) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            sanctionList[accounts[i]] = sanctioned;
        }
    }

    // ─── 审计日志 ──────────────────────────

    /**
     * @notice 写入审计日志（仅引擎调用）
     * @param txnHash      交易哈希（不含敏感数据）
     * @param privacyLevel 使用的隐私等级
     * @param userId       匿名化用户 ID
     */
    function logAudit(
        bytes32 txnHash,
        uint8 privacyLevel,
        bytes32 userId
    ) external onlyVerifier {
        bytes32 entryHash = keccak256(abi.encodePacked(txnHash, privacyLevel, userId, block.number));

        auditLog.push(AuditEntry({
            timestamp:    block.timestamp,
            blockNumber:  block.number,
            privacyLevel: privacyLevel,
            txnHash:      txnHash,
            userId:       userId
        }));
        auditIndex[entryHash] = auditLog.length - 1;

        emit AuditLogged(entryHash, privacyLevel);
    }

    /**
     * @notice 查询审计日志（合规审计接口，不泄露交易细节）
     */
    function getAuditEntry(bytes32 entryHash) external view returns (AuditEntry memory) {
        uint256 index = auditIndex[entryHash];
        require(index < auditLog.length || (index == 0 && auditLog.length > 0), "Not found");
        return auditLog[index];
    }

    function getAuditCount() external view returns (uint256) {
        return auditLog.length;
    }

    // ─── 管理 ──────────────────────────────

    function authorizeVerifier(address verifier, bool authorized) external onlyOwner {
        authorizedVerifiers[verifier] = authorized;
        emit VerifierAuthorized(verifier, authorized);
    }

    function setThresholds(uint256 l0l1, uint256 l1l2, uint256 l2l3) external onlyOwner {
        require(l0l1 < l1l2 && l1l2 < l2l3, "Invalid order");
        thresholds = PrivacyThresholds(l0l1, l1l2, l2l3);
        emit ThresholdsUpdated(l0l1, l1l2, l2l3);
    }

    /**
     * @notice 更新 Merkle 树根（KYC 证明集合变更时）
     */
    function updateMerkleRoot(bytes32 newRoot) external onlyOwner {
        emit MerkleRootUpdated(merkleRoot, newRoot);
        merkleRoot = newRoot;
    }

    // ─── Anubis 预编译 ──────────────────────

    address constant VERIFY_PROOF = address(0x0100);
}
