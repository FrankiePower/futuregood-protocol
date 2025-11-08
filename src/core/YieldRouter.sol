// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title YieldRouter
 * @author FutureGood Protocol
 * @notice Routes deposits across Aave (40%), Morpho (30%), and Spark (30%) strategies
 * @dev All three strategies donate 100% of yield to public goods via dragonRouter
 *      Users deposit USDC and receive shares from each strategy
 *      Users can withdraw their principal from all three strategies
 */
contract YieldRouter {
    using SafeERC20 for IERC20;

    /// @notice The underlying asset (USDC)
    IERC20 public immutable asset;

    /// @notice Aave strategy (receives 40% of deposits)
    IERC4626 public immutable aaveStrategy;

    /// @notice Morpho strategy (receives 30% of deposits)
    IERC4626 public immutable morphoStrategy;

    /// @notice Spark strategy (receives 30% of deposits)
    IERC4626 public immutable sparkStrategy;

    /// @notice Allocation percentages (basis points)
    uint256 public constant AAVE_ALLOCATION = 4000; // 40%
    uint256 public constant MORPHO_ALLOCATION = 3000; // 30%
    uint256 public constant SPARK_ALLOCATION = 3000; // 30%
    uint256 public constant BASIS_POINTS = 10000;

    /// @notice Events
    event Deposited(
        address indexed user, uint256 amount, uint256 aaveShares, uint256 morphoShares, uint256 sparkShares
    );
    event Withdrawn(
        address indexed user, uint256 amount, uint256 aaveShares, uint256 morphoShares, uint256 sparkShares
    );

    /**
     * @notice Initialize the YieldRouter
     * @param _asset The underlying asset (USDC)
     * @param _aaveStrategy Address of deployed AaveYieldDonatingStrategy
     * @param _morphoStrategy Address of deployed MorphoYieldDonatingStrategy
     * @param _sparkStrategy Address of deployed SparkYieldDonatingStrategy
     */
    constructor(address _asset, address _aaveStrategy, address _morphoStrategy, address _sparkStrategy) {
        require(_asset != address(0), "YieldRouter: zero asset");
        require(_aaveStrategy != address(0), "YieldRouter: zero aave");
        require(_morphoStrategy != address(0), "YieldRouter: zero morpho");
        require(_sparkStrategy != address(0), "YieldRouter: zero spark");

        asset = IERC20(_asset);
        aaveStrategy = IERC4626(_aaveStrategy);
        morphoStrategy = IERC4626(_morphoStrategy);
        sparkStrategy = IERC4626(_sparkStrategy);

        // Verify all strategies use the same asset
        require(aaveStrategy.asset() == _asset, "YieldRouter: aave asset mismatch");
        require(morphoStrategy.asset() == _asset, "YieldRouter: morpho asset mismatch");
        require(sparkStrategy.asset() == _asset, "YieldRouter: spark asset mismatch");

        // Approve strategies to spend router's assets
        asset.forceApprove(_aaveStrategy, type(uint256).max);
        asset.forceApprove(_morphoStrategy, type(uint256).max);
        asset.forceApprove(_sparkStrategy, type(uint256).max);
    }

    /**
     * @notice Deposit assets and split across all three strategies
     * @param amount Amount of assets to deposit
     * @return aaveShares Shares received from Aave strategy
     * @return morphoShares Shares received from Morpho strategy
     * @return sparkShares Shares received from Spark strategy
     */
    function deposit(uint256 amount) external returns (uint256 aaveShares, uint256 morphoShares, uint256 sparkShares) {
        require(amount > 0, "YieldRouter: zero amount");

        // Transfer assets from user to router
        asset.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate allocations (40/30/30)
        uint256 toAave = (amount * AAVE_ALLOCATION) / BASIS_POINTS;
        uint256 toMorpho = (amount * MORPHO_ALLOCATION) / BASIS_POINTS;
        uint256 toSpark = amount - toAave - toMorpho; // Remaining to avoid rounding issues

        // Deposit to each strategy on behalf of user
        aaveShares = aaveStrategy.deposit(toAave, msg.sender);
        morphoShares = morphoStrategy.deposit(toMorpho, msg.sender);
        sparkShares = sparkStrategy.deposit(toSpark, msg.sender);

        emit Deposited(msg.sender, amount, aaveShares, morphoShares, sparkShares);
    }

    /**
     * @notice Withdraw assets from all three strategies
     * @dev User must approve router to spend their strategy shares before calling
     * @param aaveShares Amount of Aave shares to redeem
     * @param morphoShares Amount of Morpho shares to redeem
     * @param sparkShares Amount of Spark shares to redeem
     * @return totalAssets Total assets withdrawn
     */
    function withdraw(uint256 aaveShares, uint256 morphoShares, uint256 sparkShares)
        external
        returns (uint256 totalAssets)
    {
        uint256 aaveAssets;
        uint256 morphoAssets;
        uint256 sparkAssets;

        // Withdraw from Aave if shares > 0
        if (aaveShares > 0) {
            // Transfer shares from user to router, then redeem
            IERC20(address(aaveStrategy)).transferFrom(msg.sender, address(this), aaveShares);
            aaveAssets = aaveStrategy.redeem(aaveShares, msg.sender, address(this));
        }

        // Withdraw from Morpho if shares > 0
        if (morphoShares > 0) {
            // Transfer shares from user to router, then redeem
            IERC20(address(morphoStrategy)).transferFrom(msg.sender, address(this), morphoShares);
            morphoAssets = morphoStrategy.redeem(morphoShares, msg.sender, address(this));
        }

        // Withdraw from Spark if shares > 0
        if (sparkShares > 0) {
            // Transfer shares from user to router, then redeem
            IERC20(address(sparkStrategy)).transferFrom(msg.sender, address(this), sparkShares);
            sparkAssets = sparkStrategy.redeem(sparkShares, msg.sender, address(this));
        }

        totalAssets = aaveAssets + morphoAssets + sparkAssets;
        require(totalAssets > 0, "YieldRouter: zero withdrawal");

        emit Withdrawn(msg.sender, totalAssets, aaveShares, morphoShares, sparkShares);
    }

    /**
     * @notice Withdraw all user's shares from all strategies
     * @dev Uses maxRedeem to avoid rounding issues. User must approve router to spend shares.
     * @return totalAssets Total assets withdrawn
     */
    function withdrawAll() external returns (uint256 totalAssets) {
        uint256 aaveShares = aaveStrategy.maxRedeem(msg.sender);
        uint256 morphoShares = morphoStrategy.maxRedeem(msg.sender);
        uint256 sparkShares = sparkStrategy.maxRedeem(msg.sender);

        uint256 aaveAssets;
        uint256 morphoAssets;
        uint256 sparkAssets;

        // Withdraw from Aave if shares > 0
        if (aaveShares > 0) {
            // Transfer shares from user to router, then redeem
            IERC20(address(aaveStrategy)).transferFrom(msg.sender, address(this), aaveShares);
            aaveAssets = aaveStrategy.redeem(aaveShares, msg.sender, address(this));
        }

        // Withdraw from Morpho if shares > 0
        if (morphoShares > 0) {
            // Transfer shares from user to router, then redeem
            IERC20(address(morphoStrategy)).transferFrom(msg.sender, address(this), morphoShares);
            morphoAssets = morphoStrategy.redeem(morphoShares, msg.sender, address(this));
        }

        // Withdraw from Spark if shares > 0
        if (sparkShares > 0) {
            // Transfer shares from user to router, then redeem
            IERC20(address(sparkStrategy)).transferFrom(msg.sender, address(this), sparkShares);
            sparkAssets = sparkStrategy.redeem(sparkShares, msg.sender, address(this));
        }

        totalAssets = aaveAssets + morphoAssets + sparkAssets;
        require(totalAssets > 0, "YieldRouter: zero withdrawal");

        emit Withdrawn(msg.sender, totalAssets, aaveShares, morphoShares, sparkShares);
    }

    /**
     * @notice Get user's total balance across all strategies (in assets)
     * @param user User address
     * @return totalAssets Total assets across all three strategies
     */
    function totalBalance(address user) external view returns (uint256 totalAssets) {
        uint256 aaveShares = aaveStrategy.balanceOf(user);
        uint256 morphoShares = morphoStrategy.balanceOf(user);
        uint256 sparkShares = sparkStrategy.balanceOf(user);

        uint256 aaveAssets = aaveStrategy.convertToAssets(aaveShares);
        uint256 morphoAssets = morphoStrategy.convertToAssets(morphoShares);
        uint256 sparkAssets = sparkStrategy.convertToAssets(sparkShares);

        totalAssets = aaveAssets + morphoAssets + sparkAssets;
    }

    /**
     * @notice Get user's share balances in each strategy
     * @param user User address
     * @return aaveShares Shares in Aave strategy
     * @return morphoShares Shares in Morpho strategy
     * @return sparkShares Shares in Spark strategy
     */
    function balances(address user)
        external
        view
        returns (uint256 aaveShares, uint256 morphoShares, uint256 sparkShares)
    {
        aaveShares = aaveStrategy.balanceOf(user);
        morphoShares = morphoStrategy.balanceOf(user);
        sparkShares = sparkStrategy.balanceOf(user);
    }

    /**
     * @notice Get user's asset balances in each strategy (converted from shares)
     * @param user User address
     * @return aaveAssets Assets in Aave strategy
     * @return morphoAssets Assets in Morpho strategy
     * @return sparkAssets Assets in Spark strategy
     */
    function assetBalances(address user)
        external
        view
        returns (uint256 aaveAssets, uint256 morphoAssets, uint256 sparkAssets)
    {
        uint256 aaveShares = aaveStrategy.balanceOf(user);
        uint256 morphoShares = morphoStrategy.balanceOf(user);
        uint256 sparkShares = sparkStrategy.balanceOf(user);

        aaveAssets = aaveStrategy.convertToAssets(aaveShares);
        morphoAssets = morphoStrategy.convertToAssets(morphoShares);
        sparkAssets = sparkStrategy.convertToAssets(sparkShares);
    }

    /**
     * @notice Preview how much would be allocated to each strategy for a given deposit
     * @param amount Amount to deposit
     * @return toAave Amount that would go to Aave (40%)
     * @return toMorpho Amount that would go to Morpho (30%)
     * @return toSpark Amount that would go to Spark (30%)
     */
    function previewDeposit(uint256 amount) external pure returns (uint256 toAave, uint256 toMorpho, uint256 toSpark) {
        toAave = (amount * AAVE_ALLOCATION) / BASIS_POINTS;
        toMorpho = (amount * MORPHO_ALLOCATION) / BASIS_POINTS;
        toSpark = amount - toAave - toMorpho;
    }
}
