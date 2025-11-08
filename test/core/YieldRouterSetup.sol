// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AaveYieldDonatingStrategy as AaveStrategy} from "../../src/strategies/AaveYieldDonatingStrategy.sol";
import {MorphoYieldDonatingStrategy as MorphoStrategy} from "../../src/strategies/MorphoYieldDonatingStrategy.sol";
import {SparkYieldDonatingStrategy as SparkStrategy} from "../../src/strategies/SparkYieldDonatingStrategy.sol";
import {YieldRouter} from "../../src/core/YieldRouter.sol";

import {IStrategyInterface} from "../../src/interfaces/IStrategyInterface.sol";
import {ITokenizedStrategy} from "@octant-core/core/interfaces/ITokenizedStrategy.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";
import {YieldDonatingTokenizedStrategy} from "@octant-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

contract YieldRouterSetup is Test, IEvents {
    // Contract instances
    ERC20 public asset;
    IStrategyInterface public aaveStrategy;
    IStrategyInterface public morphoStrategy;
    IStrategyInterface public sparkStrategy;
    YieldRouter public router;

    // Addresses for different roles
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public dragonRouter = address(3); // This is the donation address
    address public emergencyAdmin = address(5);

    // YieldDonating specific variables
    bool public enableBurning = true;
    address public tokenizedStrategyAddress;

    // Vault addresses
    address public aaveVault;
    address public morphoVault;
    address public sparkVault;

    // Integer variables
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

        // Read vault addresses from environment
        aaveVault = vm.envAddress("AAVE_VAULT");
        require(aaveVault != address(0), "AAVE_VAULT not set in .env");

        morphoVault = vm.envAddress("MORPHO_VAULT");
        require(morphoVault != address(0), "MORPHO_VAULT not set in .env");

        sparkVault = vm.envAddress("SPARK_VAULT");
        require(sparkVault != address(0), "SPARK_VAULT not set in .env");

        // Deploy YieldDonatingTokenizedStrategy implementation
        tokenizedStrategyAddress = address(new YieldDonatingTokenizedStrategy());

        // Deploy all three strategies
        aaveStrategy = IStrategyInterface(setUpAaveStrategy());
        morphoStrategy = IStrategyInterface(setUpMorphoStrategy());
        sparkStrategy = IStrategyInterface(setUpSparkStrategy());

        // Deploy the YieldRouter
        router = new YieldRouter(
            address(asset),
            address(aaveStrategy),
            address(morphoStrategy),
            address(sparkStrategy)
        );

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(aaveStrategy), "aaveStrategy");
        vm.label(address(morphoStrategy), "morphoStrategy");
        vm.label(address(sparkStrategy), "sparkStrategy");
        vm.label(address(router), "router");
        vm.label(dragonRouter, "dragonRouter");
    }

    function setUpAaveStrategy() public returns (address) {
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new AaveStrategy(
                    aaveVault,
                    address(asset),
                    "Aave YieldDonating Strategy",
                    management,
                    keeper,
                    emergencyAdmin,
                    dragonRouter,
                    enableBurning,
                    tokenizedStrategyAddress
                )
            )
        );

        return address(_strategy);
    }

    function setUpMorphoStrategy() public returns (address) {
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new MorphoStrategy(
                    morphoVault,
                    address(asset),
                    "Morpho YieldDonating Strategy",
                    management,
                    keeper,
                    emergencyAdmin,
                    dragonRouter,
                    enableBurning,
                    tokenizedStrategyAddress
                )
            )
        );

        return address(_strategy);
    }

    function setUpSparkStrategy() public returns (address) {
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                new SparkStrategy(
                    sparkVault,
                    address(asset),
                    "Spark YieldDonating Strategy",
                    management,
                    keeper,
                    emergencyAdmin,
                    dragonRouter,
                    enableBurning,
                    tokenizedStrategyAddress
                )
            )
        );

        return address(_strategy);
    }

    function depositIntoRouter(address _user, uint256 _amount) public returns (uint256, uint256, uint256) {
        vm.prank(_user);
        asset.approve(address(router), _amount);

        vm.prank(_user);
        return router.deposit(_amount);
    }

    function mintAndDepositIntoRouter(address _user, uint256 _amount) public returns (uint256, uint256, uint256) {
        airdrop(asset, _user, _amount);
        return depositIntoRouter(_user, _amount);
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }
}
