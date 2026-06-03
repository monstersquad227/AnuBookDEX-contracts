// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LiquidityRouter
 * @notice AnuBook 订单簿 ↔ RocketSwap AMM 智能路由
 * @dev 链下 AI (internal/dex/ai/engine.go) 分析双端深度后决策路由方向，
 *      链上合约执行 swap 并记录统计
 *
 * 工作流 (PRD 4.7.1):
 *   1. 链下 AI Router 分析订单簿深度 vs AMM 流动性
 *   2. 订单簿充裕 → AnuBook 直接撮合 (Settlement SC)
 *   3. 订单簿不足 → 路由至 RocketSwap AMM (此合约)
 *   4. 跨协议交易统一记账、统一手续费统计
 *
 * 依赖:
 *   - RocketSwap Router SC (管理端配置)
 *   - AI Engine (链下，ai/engine.go)
 */
contract LiquidityRouter {
    // ─── 事件 ──────────────────────────────

    event RouteExecuted(
        bytes32 indexed pairId,
        address indexed user,
        uint256 amount,
        address pool,
        uint256 returnAmount,
        bool isBuy
    );

    event PoolMapped(bytes32 indexed pairId, address pool, string baseAsset, string quoteAsset);
    event RoutingToggled(bytes32 indexed pairId, bool enabled);
    event AnubookSettlementUpdated(address previous, address updated);
    event RocketSwapRouterUpdated(address previous, address updated);
    event EngineUpdated(address previous, address updated);

    // ─── 状态 ──────────────────────────────

    address public owner;
    address public engine;             // 授权引擎 (AI 路由决策)
    address public anubookSettlement;   // AnuBook Settlement SC
    address public rocketSwapRouter;    // RocketSwap Router SC

    /// @notice 累计路由至 RocketSwap 的成交量
    uint256 public totalRoutedVolume;

    /// @notice 累计路由手续费
    uint256 public totalRoutedFee;

    /// @notice AnuBook 交易对 → RocketSwap Pool 映射
    mapping(bytes32 => address) public pairToPool;

    /// @notice 交易对是否启用路由 (关闭 = 仅 AnuBook 订单簿)
    mapping(bytes32 => bool) public routingEnabled;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyEngine() {
        require(msg.sender == engine, "Only engine");
        _;
    }

    constructor() {
        owner = msg.sender;
        engine = msg.sender;
    }

    // ─── 管理 ──────────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    /**
     * @notice 设置授权引擎地址
     */
    function setEngine(address e) external onlyOwner {
        require(e != address(0), "Zero address");
        emit EngineUpdated(engine, e);
        engine = e;
    }

    /**
     * @notice 关联 AnuBook Settlement 合约
     */
    function setAnubookSettlement(address settlement) external onlyOwner {
        require(settlement != address(0), "Zero address");
        emit AnubookSettlementUpdated(anubookSettlement, settlement);
        anubookSettlement = settlement;
    }

    /**
     * @notice 关联 RocketSwap Router 合约
     */
    function setRocketSwapRouter(address router) external onlyOwner {
        require(router != address(0), "Zero address");
        emit RocketSwapRouterUpdated(rocketSwapRouter, router);
        rocketSwapRouter = router;
    }

    /**
     * @notice 注册 AnuBook 交易对 → RocketSwap Pool 映射
     * @param baseAsset   基础资产符号 (e.g. "ETH")
     * @param quoteAsset  计价资产符号 (e.g. "USDT")
     * @param pool        RocketSwap 对应 Pool 地址
     */
    function mapPool(
        string calldata baseAsset,
        string calldata quoteAsset,
        address pool
    ) external onlyOwner {
        require(pool != address(0), "Zero pool address");
        bytes32 pairId = _computePairId(baseAsset, quoteAsset);
        pairToPool[pairId] = pool;
        routingEnabled[pairId] = true;
        emit PoolMapped(pairId, pool, baseAsset, quoteAsset);
    }

    /**
     * @notice 启停某交易对外部路由
     */
    function toggleRouting(
        string calldata baseAsset,
        string calldata quoteAsset,
        bool enabled
    ) external onlyOwner {
        bytes32 pairId = _computePairId(baseAsset, quoteAsset);
        routingEnabled[pairId] = enabled;
        emit RoutingToggled(pairId, enabled);
    }

    // ─── 核心接口 (引擎调用) ────────────────

    /**
     * @notice 路由至 RocketSwap AMM 执行交易
     * @dev 链下 AI 已决策: 订单簿深度不足 → 走此函数
     * @param pairId     交易对 ID (keccak256("ETH/USDT"))
     * @param amount     交易金额
     * @param minReturn  最小预期回款 (滑点保护)
     * @param user       用户地址 (收益接收方)
     * @param isBuy      true=买入, false=卖出
     * @return returnAmount 实际到账金额
     */
    function routeToRocketSwap(
        bytes32 pairId,
        uint256 amount,
        uint256 minReturn,
        address user,
        bool isBuy
    ) external onlyEngine returns (uint256 returnAmount) {
        require(routingEnabled[pairId], "Routing disabled");
        require(user != address(0), "Zero user address");
        require(rocketSwapRouter != address(0), "Router not set");

        address pool = pairToPool[pairId];
        require(pool != address(0), "Pool not mapped");

        // MVP: 记录路由事件 + 统计
        // 生产环境通过 RocketSwap Router 接口执行 swap:
        //
        // address[] memory path = new address[](2);
        // path[0] = tokenIn;
        // path[1] = tokenOut;
        //
        // (bool success, bytes memory data) = rocketSwapRouter.call(
        //     abi.encodeWithSignature(
        //         "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
        //         amount, minReturn, path, user, block.timestamp + 300
        //     )
        // );
        // require(success, "Swap failed");
        // returnAmount = abi.decode(data, (uint256));

        returnAmount = amount; // MVP: 1:1 占位

        totalRoutedVolume += amount;
        emit RouteExecuted(pairId, user, amount, pool, returnAmount, isBuy);
    }

    // ─── 查询 ──────────────────────────────

    function getPool(
        string calldata baseAsset,
        string calldata quoteAsset
    ) external view returns (address) {
        return pairToPool[_computePairId(baseAsset, quoteAsset)];
    }

    function isRoutingEnabled(
        string calldata baseAsset,
        string calldata quoteAsset
    ) external view returns (bool) {
        return routingEnabled[_computePairId(baseAsset, quoteAsset)];
    }

    function getStats() external view returns (
        uint256 volume,
        uint256 fees,
        address router
    ) {
        return (totalRoutedVolume, totalRoutedFee, rocketSwapRouter);
    }

    // ─── 内部 ──────────────────────────────

    function _computePairId(
        string memory baseAsset,
        string memory quoteAsset
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseAsset, "/", quoteAsset));
    }
}
