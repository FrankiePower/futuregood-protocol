// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {AaveYieldDonatingStrategy as Strategy, ERC20} from "../../src/strategies/AaveYieldDonatingStrategy.sol";
import {IStrategyInterface} from "../../src/interfaces/IStrategyInterface.sol";
import {ITokenizedStrategy} from "@octant-core/core/interfaces/ITokenizedStrategy.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";
import {YieldDonatingTokenizedStrategy} from "@octant-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract AaveYieldDonatingSetup is Test, IEvents {
    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public dragonRouter = address(3); // This is the donation address
    address public emergencyAdmin = address(5);

    // Aave specific variables
    bool public enableBurning = true;
    address public tokenizedStrategyAddress;
    address public aaveVault;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1,000,000 of the asset
    uint256 public maxFuzzAmount;
    uint256 public minFuzzAmount = 10_000;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        // Create mainnet fork
        string memory rpcUrl = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpcUrl);

        // Read asset address from environment
        address testAssetAddress = vm.envAddress("TEST_ASSET_ADDRESS");
        require(testAssetAddress != address(0), "TEST_ASSET_ADDRESS not set in .env");

        // Set asset
        asset = ERC20(testAssetAddress);

        // Set decimals
        decimals = asset.decimals();

        // Set max fuzz amount to 1,000,000 of the asset
        maxFuzzAmount = 1_000_000 * 10 ** decimals;

        // Read Aave vault from environment
        aaveVault = vm.envAddress("TEST_YIELD_SOURCE");
        require(aaveVault != address(0), "TEST_YIELD_SOURCE not set in .env");

        // Deploy YieldDonatingTokenizedStrategy implementation
        tokenizedStrategyAddress = address(new YieldDonatingTokenizedStrategy());

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(dragonRouter, "dragonRouter");
    }

    function setUpStrategy() public returns (address) {
        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new Strategy(
                    aaveVault,
                    address(asset),
                    "Aave YieldDonating Strategy",
                    management,
                    keeper,
                    emergencyAdmin,
                    dragonRouter, // Use dragonRouter as the donation address
                    enableBurning,
                    tokenizedStrategyAddress
                )
            )
        );

        return address(_strategy);
    }

    function depositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        deal(address(_asset), _to, _amount);
    }
}
