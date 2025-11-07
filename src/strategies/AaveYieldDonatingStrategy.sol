// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseStrategy} from "@octant-core/core/BaseStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title AaveYieldDonatingStrategy
 * @author FutureGood Protocol
 * @notice Deploys assets to Aave's ATokenVault and donates 100% of yield to public goods
 * @dev Uses Aave's ERC-4626 compliant ATokenVault for clean integration
 *      Inherits from Octant's BaseStrategy which handles profit donation to dragonRouter
 */
contract AaveYieldDonatingStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    /// @notice Aave's ERC-4626 vault (wraps aTokens for easier integration)
    IERC4626 public immutable aaveVault;

    /**
     * @notice Initialize the Aave yield-donating strategy
     * @param _aaveVault Address of Aave's ATokenVault for the asset (e.g., aUSDC vault)
     * @param _asset Underlying asset address (e.g., USDC, WETH, wstETH)
     * @param _name Strategy name for identification
     * @param _management Management address (can update strategy parameters)
     * @param _keeper Keeper address (can call report() and tend())
     * @param _emergencyAdmin Emergency admin (can shutdown and emergency withdraw)
     * @param _donationAddress dragonRouter address (receives 100% of yield shares)
     * @param _enableBurning Allow burning dragonRouter shares to cover user losses
     * @param _tokenizedStrategyAddress Octant's TokenizedStrategy implementation
     */
    constructor(
        address _aaveVault,
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
        aaveVault = IERC4626(_aaveVault);

        // Verify vault asset matches strategy asset
        require(aaveVault.asset() == _asset, "AaveStrategy: asset mismatch");

        // Approve Aave vault to spend our assets (gas optimization - do once in constructor)
        ERC20(_asset).forceApprove(_aaveVault, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    REQUIRED STRATEGY IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy assets to Aave vault
     * @dev Called automatically after users deposit into the strategy
     *      Deposits assets into Aave's ERC-4626 vault, receiving aToken shares
     * @param _amount Amount of assets to deploy to Aave
     */
    function _deployFunds(uint256 _amount) internal override {
        // Deposit assets into Aave vault, receive aToken shares in return
        // The vault handles the underlying Aave V3 pool interaction
        aaveVault.deposit(_amount, address(this));
    }

    /**
     * @notice Withdraw assets from Aave vault
     * @dev Called when users withdraw from the strategy or during rebalancing
     *      Burns aToken shares and receives underlying assets
     * @param _amount Amount of assets to withdraw from Aave
     */
    function _freeFunds(uint256 _amount) internal override {
        // Withdraw exact amount of assets from Aave vault
        // This burns the corresponding aToken shares
        // receiver = address(this), owner = address(this)
        aaveVault.withdraw(_amount, address(this), address(this));
    }

    /**
     * @notice Calculate total assets and report profits to mint shares for dragonRouter
     * @dev Called by keeper to trigger profit calculation and donation
     *      This is where the magic happens - profits are automatically minted to dragonRouter
     * @return _totalAssets Total assets under management (deployed in Aave + idle in strategy)
     */
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // 1. Calculate deployed assets in Aave
        //    Get our aToken share balance and convert to underlying asset amount
        uint256 aaveShares = aaveVault.balanceOf(address(this));
        uint256 assetsInAave = aaveVault.convertToAssets(aaveShares);

        // 2. Add any idle assets sitting in the strategy
        //    (assets not yet deployed or from partial withdrawals)
        uint256 idleAssets = ERC20(asset).balanceOf(address(this));

        // 3. Return total
        //    BaseStrategy will compare this to lastReportedAssets
        //    Any increase = profit → minted as shares to donationAddress (dragonRouter)
        //    Any decrease = loss → handled by loss protection mechanism
        _totalAssets = assetsInAave + idleAssets;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdraw funds from Aave during shutdown
     * @dev Only callable by emergency admin when strategy is shutdown
     *      Allows recovering funds even if normal operations fail
     * @param _amount Amount of assets to emergency withdraw
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Attempt to withdraw from Aave even during emergency
        // This may fail if Aave has liquidity issues, but worth trying
        if (_amount > 0) {
            // Get current balance to avoid trying to withdraw more than we have
            uint256 deployedBalance = aaveVault.maxWithdraw(address(this));
            uint256 toWithdraw = _amount > deployedBalance ? deployedBalance : _amount;

            if (toWithdraw > 0) {
                aaveVault.withdraw(toWithdraw, address(this), address(this));
            }
        }
    }

    /**
     * @notice Get available deposit limit (can be overridden to add deposit caps)
     * @dev Default: unlimited deposits
     * @return Maximum amount that can be deposited
     */
    function availableDepositLimit(address /*_owner*/) public pure override returns (uint256) {
        // Optional: Add deposit caps here if needed
        // For example, limit to Aave vault's deposit limit:
        // return aaveVault.maxDeposit(address(this));

        return type(uint256).max; // Unlimited for now
    }

    /**
     * @notice Get available withdrawal limit (can be overridden to add withdrawal restrictions)
     * @dev Default: can withdraw up to what's available in Aave
     * @return Maximum amount that can be withdrawn
     */
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        // Return maximum withdrawable from Aave (respects Aave's liquidity)
        return aaveVault.maxWithdraw(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current deployed balance in Aave
     * @return Amount of assets currently deployed in Aave vault
     */
    function deployedAssets() external view returns (uint256) {
        uint256 shares = aaveVault.balanceOf(address(this));
        return aaveVault.convertToAssets(shares);
    }

    /**
     * @notice Get current aToken share balance
     * @return Amount of aToken shares held by strategy
     */
    function aaveShareBalance() external view returns (uint256) {
        return aaveVault.balanceOf(address(this));
    }
}
