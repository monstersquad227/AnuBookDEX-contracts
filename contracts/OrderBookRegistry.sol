// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title OrderBookRegistry
 * @notice 交易对注册 + 订单提交事件发射
 * @dev 部署在 Anubis Chain 公开状态层 (EVM)
 *
 * 用户通过 Type 103 (Contract Call) 提交加密订单，
 * 链下引擎监听 OrderSubmitted 事件 → 解密 Note → 撮合
 */
contract OrderBookRegistry {
    /// @notice 交易对参数
    struct PairConfig {
        string baseAsset;        // 基础资产 (e.g. "ETH")
        string quoteAsset;       // 计价资产 (e.g. "USDT")
        uint8 priceScale;        // 价格精度位数
        uint8 amountScale;       // 数量精度位数
        uint256 minOrderSize;    // 最小订单量
        uint256 maxOrderSize;    // 最大订单量
        bool active;             // 是否启用
    }

    /// @notice 订单提交事件（链下引擎监听）
    /// @param noteCommitment  Anubis Note 承诺 (Pedersen)
    /// @param viewTag         视图标签 (前 4 字节，加速客户端 Note 扫描)
    /// @param nullifier       防双花标识
    /// @param deadline        订单过期区块号
    event OrderSubmitted(
        bytes32 indexed noteCommitment,
        bytes4 indexed viewTag,
        bytes32 nullifier,
        uint64 deadline,
        address indexed submitter
    );

    /// @notice 交易对注册事件
    event PairRegistered(string indexed symbol, string baseAsset, string quoteAsset);

    /// @notice 交易对状态变更
    event PairStatusChanged(string indexed symbol, bool active);

    /// @notice 管理员变更
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // 状态
    address public owner;
    mapping(string => PairConfig) public pairs;
    string[] public pairList;

    // 每个地址的日订单上限（防滥用）
    mapping(address => uint256) public dailyOrderCount;
    mapping(address => uint256) public lastOrderDay;
    uint256 public constant MAX_DAILY_ORDERS = 1000;

    // 最小 deadline（当前区块 + N），防立即过期
    uint256 public constant MIN_DEADLINE_BLOCKS = 5;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ─── 交易对管理 ─────────────────────────────────

    /**
     * @notice 注册交易对
     * @param symbol      交易对代码 (e.g. "ETH_USDT")
     * @param baseAsset   基础资产
     * @param quoteAsset  计价资产
     * @param priceScale  价格精度
     * @param amountScale 数量精度
     */
    function registerPair(
        string calldata symbol,
        string calldata baseAsset,
        string calldata quoteAsset,
        uint8 priceScale,
        uint8 amountScale,
        uint256 minOrderSize,
        uint256 maxOrderSize
    ) external onlyOwner {
        require(bytes(pairs[symbol].baseAsset).length == 0, "Pair exists");
        require(priceScale > 0 && priceScale <= 18, "Invalid price scale");
        require(amountScale > 0 && amountScale <= 18, "Invalid amount scale");
        require(maxOrderSize >= minOrderSize, "Invalid range");

        pairs[symbol] = PairConfig({
            baseAsset:   baseAsset,
            quoteAsset:  quoteAsset,
            priceScale:  priceScale,
            amountScale: amountScale,
            minOrderSize: minOrderSize,
            maxOrderSize: maxOrderSize,
            active:      true
        });
        pairList.push(symbol);

        emit PairRegistered(symbol, baseAsset, quoteAsset);
    }

    function setPairActive(string calldata symbol, bool active) external onlyOwner {
        require(bytes(pairs[symbol].baseAsset).length > 0, "Pair not found");
        pairs[symbol].active = active;
        emit PairStatusChanged(symbol, active);
    }

    function getPairCount() external view returns (uint256) {
        return pairList.length;
    }

    function getAllPairs() external view returns (string[] memory) {
        return pairList;
    }

    // ─── 订单提交 ──────────────────────────────────

    /**
     * @notice 通过 Type 103 (Contract Call) 提交隐私订单
     * @dev 调用方应在 Anubis 私有层构建 Note，然后通过 Type 103 调用此方法。
     *      订单数据加密在 Note 中，链上仅存储 nullifier 和 deadline。
     *
     * @param nullifier  唯一性标识（通过 0x0103 预编译校验）
     * @param deadline   订单过期区块号
     */
    function submitOrder(bytes32 nullifier, uint64 deadline) external {
        require(deadline >= block.number + MIN_DEADLINE_BLOCKS, "Deadline too soon");

        // ─── Nullifier 防双花检查（Anubis 0x0103 预编译）───
        (bool nullifierOk, ) = NULLIFIER_CHECK.staticcall(abi.encode(nullifier));
        require(nullifierOk, "Duplicate nullifier");

        // ─── 频率限制 ───
        uint256 today = block.timestamp / 86400;
        if (lastOrderDay[msg.sender] != today) {
            dailyOrderCount[msg.sender] = 0;
            lastOrderDay[msg.sender] = today;
        }
        require(dailyOrderCount[msg.sender] < MAX_DAILY_ORDERS, "Daily limit reached");
        dailyOrderCount[msg.sender]++;

        // 从 calldata 中提取 Note 信息（Type 103 附带隐私数据）
        // Note commitment 和 view tag 由 Anubis 节点在执行前注入
        bytes32 noteCommitment = _extractNoteCommitment();
        bytes4 viewTag = _extractViewTag();

        emit OrderSubmitted(noteCommitment, viewTag, nullifier, deadline, msg.sender);
    }

    // ─── Anubis 预编译接口 ────────────────────────

    /// @dev Anubis Chain 0x0100 — PLONK 证明验证
    address constant VERIFY_PROOF = address(0x0100);

    /// @dev Anubis Chain 0x0103 — Nullifier 防双花
    address constant NULLIFIER_CHECK = address(0x0103);

    // ─── 内部函数 ─────────────────────────────────

    /// @dev 从 Anubis Type 103 交易的附加数据中提取 Note 承诺
    function _extractNoteCommitment() internal pure returns (bytes32) {
        // Anubis 节点在执行 Type 103 交易时，
        // 将 Note commitment 注入到 calldata 的前 32 字节
        bytes32 commitment;
        assembly {
            commitment := calldataload(0)
        }
        return commitment;
    }

    /// @dev 提取 View Tag（Note 承诺之后 4 字节）
    function _extractViewTag() internal pure returns (bytes4) {
        bytes4 tag;
        assembly {
            tag := bytes4(calldataload(32))
        }
        return tag;
    }
}
