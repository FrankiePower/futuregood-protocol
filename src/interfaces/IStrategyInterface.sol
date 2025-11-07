// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

/**
 * @title IStrategyInterface
 * @author FutureGood Protocol (adapted from Octant V2)
 * @notice Interface for yield-donating strategies used in FutureGood Protocol
 * @dev Extends Yearn's IStrategy (ERC-4626 tokenized strategy interface)
 *      This interface is used by YieldDonatingStrategyFactory and all strategy implementations.
 *      Currently a direct passthrough to IStrategy - can be extended with FutureGood-specific
 *      methods in the future (e.g., getDragonRouter(), setDonationPercentage(), etc.)
 */
interface IStrategyInterface is IStrategy {
    // Currently inherits all methods from IStrategy:
    // - asset() - Get underlying asset address
    // - totalAssets() - Total assets under management
    // - deposit(uint256, address) - Deposit assets and mint shares
    // - withdraw(uint256, address, address) - Burn shares and withdraw assets
    // - balanceOf(address) - Get share balance
    // - etc. (Full ERC-4626 interface)

    // Future: Add FutureGood-specific strategy methods here
}
