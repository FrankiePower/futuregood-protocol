// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {YieldRouter} from "./YieldRouter.sol";
import {YieldSplitter} from "./YieldSplitter.sol";

/**
 * @title PublicGoodsYieldHook
 * @author FutureGood Protocol
 * @notice Uniswap V4 hook that automatically routes YBT proceeds to public goods funding
 * @dev Following official Uniswap V4 hook pattern from docs.uniswap.org
 *
 * HOW IT WORKS:
 * - Users donate YT tokens (future yield) to this hook via YieldSplitter
 * - Hook accumulates YT and can sell them for YBT (yield-bearing tokens like USDC)
 * - When swaps happen in YT/YBT pools, hook checks its YBT balance
 * - afterSwap() automatically routes accumulated YBT to YieldRouter
 * - YieldRouter splits YBT across Aave/Morpho/Spark strategies (40/30/30)
 * - Strategies donate 100% of generated yield to dragonRouter (Octant)
 *
 * Result: YT donations → YBT capital → perpetual yield → public goods funding!
 *
 * NOTE: Hook does NOT provide liquidity itself. External LPs provide liquidity.
 * Hook just receives YT from donors and routes proceeds after selling.
 */
contract PublicGoodsYieldHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @notice YieldRouter that routes funds to Aave/Morpho/Spark
    YieldRouter public immutable yieldRouter;

    /// @notice YieldSplitter for market info
    YieldSplitter public immutable yieldSplitter;

    /// @notice dragonRouter - Octant's public goods distributor
    /// @dev YT sale proceeds are sent directly here for immediate public goods funding
    address public immutable dragonRouter;

    /// @notice Minimum amount to trigger auto-routing (gas optimization)
    uint256 public constant MIN_ROUTE_AMOUNT = 1e18; // 1 token

    /// @notice Mapping from pool ID to market ID
    mapping(PoolId => bytes32) public poolToMarketId;

    /// @notice Mapping from pool ID to whether auto-routing is enabled
    mapping(PoolId => bool) public autoRouteEnabled;

    /// @notice Total amount routed to public goods per pool
    mapping(PoolId => uint256) public totalRoutedPerPool;

    event PoolMarketMapped(PoolId indexed poolId, bytes32 indexed marketId);
    event AutoRouteEnabled(PoolId indexed poolId, bool enabled);
    event YieldAutoRouted(
        PoolId indexed poolId,
        bytes32 indexed marketId,
        address indexed ybt,
        uint256 amount,
        uint256 aaveShares,
        uint256 morphoShares,
        uint256 sparkShares
    );
    event YTProceededRouted(
        PoolId indexed poolId, bytes32 indexed marketId, address indexed ybt, uint256 amount, address dragonRouter
    );

    /**
     * @notice Initialize the hook
     * @param _poolManager Uniswap V4 PoolManager
     * @param _yieldRouter YieldRouter for routing proceeds
     * @param _yieldSplitter YieldSplitter for market data
     * @param _dragonRouter Octant's dragonRouter address (receives YT sale proceeds)
     */
    constructor(IPoolManager _poolManager, address _yieldRouter, address _yieldSplitter, address _dragonRouter)
        BaseHook(_poolManager)
    {
        require(_yieldRouter != address(0), "zero router");
        require(_yieldSplitter != address(0), "zero splitter");
        require(_dragonRouter != address(0), "zero dragonRouter");

        yieldRouter = YieldRouter(_yieldRouter);
        yieldSplitter = YieldSplitter(_yieldSplitter);
        dragonRouter = _dragonRouter;
    }

    /**
     * @notice Returns hook permissions
     * @dev Following official Uniswap V4 pattern
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // Enable auto-routing by default
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true, // THE MAGIC - auto-route proceeds
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Map a pool to yield market
     * @param key Pool key
     * @param marketId Market ID from YieldSplitter
     */
    function setPoolMarketMapping(PoolKey calldata key, bytes32 marketId) external {
        PoolId poolId = key.toId();

        // Verify market exists
        YieldSplitter.YieldMarket memory market = yieldSplitter.getYieldMarket(marketId);
        require(market.yieldBearingToken != address(0), "invalid market");

        poolToMarketId[poolId] = marketId;
        emit PoolMarketMapped(poolId, marketId);
    }

    /**
     * @notice Enable/disable auto-routing for a pool
     * @param key Pool key
     * @param enabled Whether to enable auto-routing
     */
    function setAutoRoute(PoolKey calldata key, bool enabled) external {
        PoolId poolId = key.toId();
        autoRouteEnabled[poolId] = enabled;
        emit AutoRouteEnabled(poolId, enabled);
    }

    /**
     * @notice Hook called after pool initialization
     * @dev Enable auto-routing by default for new pools
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        autoRouteEnabled[poolId] = true;
        return this.afterInitialize.selector;
    }

    /**
     * @notice THE MAGIC: Auto-route YBT proceeds after swaps
     * @dev Called after EVERY swap in the pool
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        // Skip if auto-routing not enabled
        if (!autoRouteEnabled[poolId]) {
            return (this.afterSwap.selector, 0);
        }

        // Skip if no market mapped
        bytes32 marketId = poolToMarketId[poolId];
        if (marketId == bytes32(0)) {
            return (this.afterSwap.selector, 0);
        }

        // Get market info
        YieldSplitter.YieldMarket memory market = yieldSplitter.getYieldMarket(marketId);
        if (market.yieldBearingToken == address(0)) {
            return (this.afterSwap.selector, 0);
        }

        // Check if hook accumulated YBT from the swap
        IERC20 ybt = IERC20(market.yieldBearingToken);
        uint256 ybtBalance = ybt.balanceOf(address(this));

        // If we have enough YBT, route it to yield strategies!
        if (ybtBalance >= MIN_ROUTE_AMOUNT) {
            _routeToYieldStrategies(poolId, marketId, market.yieldBearingToken, ybtBalance);
        }

        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Internal function to route YBT proceeds from YT sales
     * @dev CRITICAL FIX: YT sale proceeds go DIRECTLY to dragonRouter for immediate public goods funding
     *      This is NOT re-invested - it goes straight to Octant for distribution
     * @param poolId Pool ID
     * @param marketId Market ID
     * @param ybt YBT token address
     * @param amount Amount to route
     */
    function _routeToYieldStrategies(PoolId poolId, bytes32 marketId, address ybt, uint256 amount) internal {
        // FIXED: Send YT sale proceeds DIRECTLY to dragonRouter
        // Previously: Deposited to strategies (wrong - that yield goes to dragonRouter, creating circular logic)
        // Now: Direct transfer to dragonRouter for immediate public goods funding
        IERC20(ybt).safeTransfer(dragonRouter, amount);

        // Track total routed
        totalRoutedPerPool[poolId] += amount;

        // Emit event showing proceeds went to dragonRouter
        emit YTProceededRouted(poolId, marketId, ybt, amount, dragonRouter);
    }

    /**
     * @notice Manual trigger for routing (if auto-route disabled)
     * @param key Pool key
     */
    function manualRoute(PoolKey calldata key) external returns (uint256) {
        PoolId poolId = key.toId();
        bytes32 marketId = poolToMarketId[poolId];
        require(marketId != bytes32(0), "no market");

        YieldSplitter.YieldMarket memory market = yieldSplitter.getYieldMarket(marketId);
        require(market.yieldBearingToken != address(0), "invalid market");

        IERC20 ybt = IERC20(market.yieldBearingToken);
        uint256 ybtBalance = ybt.balanceOf(address(this));

        if (ybtBalance > 0) {
            _routeToYieldStrategies(poolId, marketId, market.yieldBearingToken, ybtBalance);
        }

        return ybtBalance;
    }

    /**
     * @notice Get stats for a pool
     * @param key Pool key
     * @return marketId Market ID
     * @return autoRoute Whether auto-routing is enabled
     * @return totalRouted Total amount routed
     * @return currentBalance Current YBT balance
     */
    function getPoolStats(PoolKey calldata key)
        external
        view
        returns (bytes32 marketId, bool autoRoute, uint256 totalRouted, uint256 currentBalance)
    {
        PoolId poolId = key.toId();
        marketId = poolToMarketId[poolId];
        autoRoute = autoRouteEnabled[poolId];
        totalRouted = totalRoutedPerPool[poolId];

        if (marketId != bytes32(0)) {
            YieldSplitter.YieldMarket memory market = yieldSplitter.getYieldMarket(marketId);
            if (market.yieldBearingToken != address(0)) {
                currentBalance = IERC20(market.yieldBearingToken).balanceOf(address(this));
            }
        }
    }
}
