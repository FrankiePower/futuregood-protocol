// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseStrategy} from "@octant-core/core/BaseStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title SparkYieldDonatingStrategy
 * @author FutureGood Protocol
 * @notice Deploys assets to Spark Savings Vaults V2 and donates 100% of yield to public goods
 * @dev Uses Spark's ERC-4626 compliant Savings Vaults V2 (spUSDC, spUSDT, spETH)
 *      Inherits from Octant's BaseStrategy which handles profit donation to dragonRouter
 *
 *      Spark Vaults V2 features:
 *      - Continuous rate accumulation via Vault Savings Rate (VSR)
 *      - Liquidity deployment through Spark Liquidity Layer
 *      - Fork of sUSDS with role-based access control
 *      - Managed by Spark Governance
 *
 *      Available Spark Vaults on Ethereum:
 *      - spUSDC: 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d
 *      - spUSDT: 0xe2e7a17dFf93280dec073C995595155283e3C372
 *      - spETH: 0xfE6eb3b609a7C8352A241f7F3A21CEA4e9209B8f
 */
contract SparkYieldDonatingStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    /// @notice Spark's ERC-4626 Savings Vault V2 (e.g., spUSDC, spUSDT, spETH)
    IERC4626 public immutable sparkVault;

    /**
     * @notice Initialize the Spark yield-donating strategy
     * @param _sparkVault Address of Spark Vault V2 for the asset
     *                    spUSDC: 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d
     *                    spUSDT: 0xe2e7a17dFf93280dec073C995595155283e3C372
     *                    spETH:  0xfE6eb3b609a7C8352A241f7F3A21CEA4e9209B8f
     * @param _asset Underlying asset address (USDC, USDT, or WETH)
     * @param _name Strategy name for identification
     * @param _management Management address (can update strategy parameters)
     * @param _keeper Keeper address (can call report() and tend())
     * @param _emergencyAdmin Emergency admin (can shutdown and emergency withdraw)
     * @param _donationAddress dragonRouter address (receives 100% of yield shares)
     * @param _enableBurning Allow burning dragonRouter shares to cover user losses
     * @param _tokenizedStrategyAddress Octant's TokenizedStrategy implementation
     */
    constructor(
        address _sparkVault,
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    )
        BaseStrategy(
            _asset,
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {
        sparkVault = IERC4626(_sparkVault);

        // Verify vault asset matches strategy asset
        require(sparkVault.asset() == _asset, "SparkStrategy: asset mismatch");

        // Approve Spark vault to spend our assets (gas optimization - do once in constructor)
        ERC20(_asset).forceApprove(_sparkVault, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    REQUIRED STRATEGY IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy assets to Spark vault
     * @dev Called automatically after users deposit into the strategy
     *      Deposits assets into Spark's ERC-4626 vault, receiving spToken shares
     *      Spark's Liquidity Layer may deploy these to yield strategies
     *      Yield accrues continuously via the Vault Savings Rate (VSR)
     * @param _amount Amount of assets to deploy to Spark
     */
    function _deployFunds(uint256 _amount) internal override {
        // Deposit assets into Spark vault, receive spToken shares in return
        // Spark uses continuous rate accumulation (chi) to track yields
        // The Liquidity Layer (TAKER_ROLE) may deploy funds to optimize yield
        sparkVault.deposit(_amount, address(this));
    }

    /**
     * @notice Withdraw assets from Spark vault
     * @dev Called when users withdraw from the strategy or during rebalancing
     *      Burns spToken shares and receives underlying assets
     *      Limited by available liquidity (some may be deployed by Liquidity Layer)
     * @param _amount Amount of assets to withdraw from Spark
     */
    function _freeFunds(uint256 _amount) internal override {
        // Withdraw exact amount of assets from Spark vault
        // This burns the corresponding spToken shares
        // Note: May be limited by available liquidity if funds are deployed
        // receiver = address(this), owner = address(this)
        sparkVault.withdraw(_amount, address(this), address(this));
    }

    /**
     * @notice Calculate total assets and report profits to mint shares for dragonRouter
     * @dev Called by keeper to trigger profit calculation and donation
     *      This is where the magic happens - profits are automatically minted to dragonRouter
     *      Spark vaults accrue yield continuously via VSR (Vault Savings Rate)
     * @return _totalAssets Total assets under management (deployed in Spark + idle in strategy)
     */
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // 1. Calculate deployed assets in Spark
        //    Get our spToken share balance and convert to underlying asset amount
        //    Spark uses chi accumulator for continuous compounding
        uint256 sparkShares = sparkVault.balanceOf(address(this));
        uint256 assetsInSpark = sparkVault.convertToAssets(sparkShares);

        // 2. Add any idle assets sitting in the strategy
        //    (assets not yet deployed or from partial withdrawals)
        uint256 idleAssets = ERC20(asset).balanceOf(address(this));

        // 3. Return total
        //    BaseStrategy will compare this to lastReportedAssets
        //    Any increase = profit → minted as shares to donationAddress (dragonRouter)
        //    Any decrease = loss → handled by loss protection mechanism
        _totalAssets = assetsInSpark + idleAssets;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdraw funds from Spark during shutdown
     * @dev Only callable by emergency admin when strategy is shutdown
     *      Allows recovering funds even if normal operations fail
     * @param _amount Amount of assets to emergency withdraw
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Attempt to withdraw from Spark even during emergency
        // Note: May be limited by available liquidity in the vault
        if (_amount > 0) {
            // Get current balance to avoid trying to withdraw more than we have
            // maxWithdraw accounts for available liquidity limitations
            uint256 deployedBalance = sparkVault.maxWithdraw(address(this));
            uint256 toWithdraw = _amount > deployedBalance ? deployedBalance : _amount;

            if (toWithdraw > 0) {
                sparkVault.withdraw(toWithdraw, address(this), address(this));
            }
        }
    }

    /**
     * @notice Get available deposit limit (respects Spark's deposit cap)
     * @dev Spark vaults have a depositCap enforced by governance
     * @return Maximum amount that can be deposited
     */
    function availableDepositLimit(
        address /*_owner*/
    )
        public
        view
        override
        returns (uint256)
    {
        // Respect Spark vault's deposit cap
        // The cap is set by Spark governance via DEFAULT_ADMIN_ROLE
        uint256 sparkLimit = sparkVault.maxDeposit(address(this));
        return sparkLimit;
    }

    /**
     * @notice Get available withdrawal limit (limited by Spark's available liquidity)
     * @dev Withdrawals are limited by actual liquidity in the vault
     *      totalAssets() may exceed balance if Liquidity Layer deployed funds
     * @return Maximum amount that can be withdrawn
     */
    function availableWithdrawLimit(
        address /*_owner*/
    )
        public
        view
        override
        returns (uint256)
    {
        // Return maximum withdrawable from Spark
        // This respects available liquidity (some may be deployed by TAKER_ROLE)
        // assetsOutstanding = totalAssets - vault.balance
        return sparkVault.maxWithdraw(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current deployed balance in Spark
     * @return Amount of assets currently deployed in Spark vault (based on continuous yield accrual)
     */
    function deployedAssets() external view returns (uint256) {
        uint256 shares = sparkVault.balanceOf(address(this));
        return sparkVault.convertToAssets(shares);
    }

    /**
     * @notice Get current Spark vault share balance (spToken balance)
     * @return Amount of spToken shares held by strategy
     */
    function sparkShareBalance() external view returns (uint256) {
        return sparkVault.balanceOf(address(this));
    }

    /**
     * @notice Get the current Vault Savings Rate (VSR) from Spark
     * @dev VSR is the rate at which yields accrue, set by Spark governance
     *      Returns value in RAY precision (1e27)
     *      Can be called if SparkVault exposes vsr() function
     * @return Current VSR in RAY precision
     */
    function getVaultSavingsRate() external view returns (uint256) {
        // Note: This assumes SparkVault has a public vsr() function
        // If not available, this function can be removed
        (bool success, bytes memory data) = address(sparkVault).staticcall(abi.encodeWithSignature("vsr()"));
        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return 0;
    }
}
