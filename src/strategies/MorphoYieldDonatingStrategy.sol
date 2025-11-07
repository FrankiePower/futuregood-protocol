// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseStrategy} from "@octant-core/core/BaseStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title MorphoYieldDonatingStrategy
 * @author FutureGood Protocol
 * @notice Deploys assets to Morpho Vault V2 and donates 100% of yield to public goods
 * @dev Uses Morpho's ERC-4626 compliant Vault V2 for clean integration
 *      Inherits from Octant's BaseStrategy which handles profit donation to dragonRouter
 *      Morpho Vaults use advanced risk management with allocators, curators, and caps
 */
contract MorphoYieldDonatingStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    /// @notice Morpho's ERC-4626 Vault V2 (manages allocations across multiple Morpho markets)
    IERC4626 public immutable morphoVault;

    /**
     * @notice Initialize the Morpho yield-donating strategy
     * @param _morphoVault Address of Morpho Vault V2 for the asset (e.g., USDC Steakhouse vault)
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
        address _morphoVault,
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
        morphoVault = IERC4626(_morphoVault);

        // Verify vault asset matches strategy asset
        require(morphoVault.asset() == _asset, "MorphoStrategy: asset mismatch");

        // Approve Morpho vault to spend our assets (gas optimization - do once in constructor)
        ERC20(_asset).forceApprove(_morphoVault, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                    REQUIRED STRATEGY IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy assets to Morpho vault
     * @dev Called automatically after users deposit into the strategy
     *      Deposits assets into Morpho's ERC-4626 vault, receiving vault shares
     *      The vault's allocator manages deployment across multiple Morpho markets
     * @param _amount Amount of assets to deploy to Morpho
     */
    function _deployFunds(uint256 _amount) internal override {
        // Deposit assets into Morpho vault, receive vault shares in return
        // Morpho's allocator will distribute these funds across various markets
        // based on curator-configured caps and risk parameters
        morphoVault.deposit(_amount, address(this));
    }

    /**
     * @notice Withdraw assets from Morpho vault
     * @dev Called when users withdraw from the strategy or during rebalancing
     *      Burns vault shares and receives underlying assets
     *      Morpho will automatically deallocate from markets as needed
     * @param _amount Amount of assets to withdraw from Morpho
     */
    function _freeFunds(uint256 _amount) internal override {
        // Withdraw exact amount of assets from Morpho vault
        // This burns the corresponding vault shares
        // Morpho handles deallocation from underlying markets automatically
        // receiver = address(this), owner = address(this)
        morphoVault.withdraw(_amount, address(this), address(this));
    }

    /**
     * @notice Calculate total assets and report profits to mint shares for dragonRouter
     * @dev Called by keeper to trigger profit calculation and donation
     *      This is where the magic happens - profits are automatically minted to dragonRouter
     *      Morpho vaults accrue interest from multiple markets
     * @return _totalAssets Total assets under management (deployed in Morpho + idle in strategy)
     */
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // 1. Calculate deployed assets in Morpho
        //    Get our vault share balance and convert to underlying asset amount
        //    Morpho vaults aggregate yields from multiple underlying markets
        uint256 morphoShares = morphoVault.balanceOf(address(this));
        uint256 assetsInMorpho = morphoVault.convertToAssets(morphoShares);

        // 2. Add any idle assets sitting in the strategy
        //    (assets not yet deployed or from partial withdrawals)
        uint256 idleAssets = ERC20(asset).balanceOf(address(this));

        // 3. Return total
        //    BaseStrategy will compare this to lastReportedAssets
        //    Any increase = profit → minted as shares to donationAddress (dragonRouter)
        //    Any decrease = loss → handled by loss protection mechanism
        _totalAssets = assetsInMorpho + idleAssets;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdraw funds from Morpho during shutdown
     * @dev Only callable by emergency admin when strategy is shutdown
     *      Allows recovering funds even if normal operations fail
     * @param _amount Amount of assets to emergency withdraw
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Attempt to withdraw from Morpho even during emergency
        // This may fail if Morpho markets have liquidity issues, but worth trying
        if (_amount > 0) {
            // Get current balance to avoid trying to withdraw more than we have
            uint256 deployedBalance = morphoVault.maxWithdraw(address(this));
            uint256 toWithdraw = _amount > deployedBalance ? deployedBalance : _amount;

            if (toWithdraw > 0) {
                morphoVault.withdraw(toWithdraw, address(this), address(this));
            }
        }
    }

    /**
     * @notice Get available deposit limit (can be overridden to add deposit caps)
     * @dev Default: respects Morpho vault's deposit limits
     * @return Maximum amount that can be deposited
     */
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // Respect Morpho vault's deposit limit (based on caps and allocations)
        uint256 morphoLimit = morphoVault.maxDeposit(address(this));
        return morphoLimit;
    }

    /**
     * @notice Get available withdrawal limit (can be overridden to add withdrawal restrictions)
     * @dev Default: can withdraw up to what's available in Morpho
     * @return Maximum amount that can be withdrawn
     */
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        // Return maximum withdrawable from Morpho (respects liquidity across markets)
        return morphoVault.maxWithdraw(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current deployed balance in Morpho
     * @return Amount of assets currently deployed in Morpho vault
     */
    function deployedAssets() external view returns (uint256) {
        uint256 shares = morphoVault.balanceOf(address(this));
        return morphoVault.convertToAssets(shares);
    }

    /**
     * @notice Get current Morpho vault share balance
     * @return Amount of Morpho vault shares held by strategy
     */
    function morphoShareBalance() external view returns (uint256) {
        return morphoVault.balanceOf(address(this));
    }
}
