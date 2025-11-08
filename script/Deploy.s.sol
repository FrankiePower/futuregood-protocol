// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {YieldSplitter} from "../src/core/YieldSplitter.sol";
import {YieldRouter} from "../src/core/YieldRouter.sol";
import {PublicGoodsYieldHook} from "../src/core/PublicGoodsYieldHook.sol";
import {AaveYieldDonatingStrategy} from "../src/strategies/AaveYieldDonatingStrategy.sol";
import {MorphoYieldDonatingStrategy} from "../src/strategies/MorphoYieldDonatingStrategy.sol";
import {SparkYieldDonatingStrategy} from "../src/strategies/SparkYieldDonatingStrategy.sol";
import {YieldDonatingTokenizedStrategy} from "@octant-core/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title Deploy
 * @notice Deployment script for FutureGood Protocol - Perpetual Public Goods Funding
 * @dev Run with: forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --broadcast --verify
 */
contract Deploy is Script {
    // ============ CONFIGURATION - MAINNET ADDRESSES ============

    // Mainnet USDC
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Yield-bearing vaults (from .env)
    address constant AAVE_USDC_VAULT = 0x73edDFa87C71ADdC275c2b9890f5c3a8480bC9E6; // Aave USDC ATokenVault
    address constant MORPHO_USDC_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB; // Morpho USDC Vault
    address constant SPARK_USDC_VAULT = 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d; // Spark spUSDC

    // Uniswap V4 (update when V4 is deployed on mainnet)
    address constant POOL_MANAGER = address(0); // TODO: Update when V4 launches

    // Octant dragonRouter (update with actual Octant address)
    address constant DRAGON_ROUTER = 0x0000000000000000000000000000000000000001; // PLACEHOLDER - Update for production

    // Roles (set to deployer by default, update for production)
    address public management;
    address public keeper;
    address public emergencyAdmin;

    // ============ DEPLOYED CONTRACTS ============

    YieldDonatingTokenizedStrategy public tokenizedStrategyImpl;
    YieldSplitter public yieldSplitter;
    YieldRouter public yieldRouter;
    PublicGoodsYieldHook public hook;
    AaveYieldDonatingStrategy public aaveStrategy;
    MorphoYieldDonatingStrategy public morphoStrategy;
    SparkYieldDonatingStrategy public sparkStrategy;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Set roles (change these in production!)
        management = deployer;
        keeper = deployer;
        emergencyAdmin = deployer;

        console2.log("===========================================");
        console2.log("FutureGood Protocol Deployment");
        console2.log("PERPETUAL PUBLIC GOODS FUNDING");
        console2.log("===========================================");
        console2.log("Deployer:", deployer);
        console2.log("Network:", block.chainid);
        console2.log("");

        // Validate configuration
        _validateConfiguration();

        vm.startBroadcast(deployerPrivateKey);

        // 0. Deploy TokenizedStrategy implementation
        console2.log("0. Deploying YieldDonatingTokenizedStrategy implementation...");
        tokenizedStrategyImpl = new YieldDonatingTokenizedStrategy();
        console2.log("   TokenizedStrategy:", address(tokenizedStrategyImpl));

        // 1. Deploy YieldSplitter
        console2.log("\n1. Deploying YieldSplitter...");
        yieldSplitter = new YieldSplitter();
        console2.log("   YieldSplitter:", address(yieldSplitter));

        // 2. Deploy Strategies
        console2.log("\n2. Deploying Yield-Donating Strategies...");

        // 2a. Aave Strategy
        console2.log("   2a. Deploying AaveYieldDonatingStrategy...");
        aaveStrategy = new AaveYieldDonatingStrategy(
            AAVE_USDC_VAULT,
            USDC,
            "FutureGood Aave USDC",
            management,
            keeper,
            emergencyAdmin,
            DRAGON_ROUTER,
            false, // enableBurning
            address(tokenizedStrategyImpl)
        );
        console2.log("      AaveStrategy:", address(aaveStrategy));

        // 2b. Morpho Strategy
        console2.log("   2b. Deploying MorphoYieldDonatingStrategy...");
        morphoStrategy = new MorphoYieldDonatingStrategy(
            MORPHO_USDC_VAULT,
            USDC,
            "FutureGood Morpho USDC",
            management,
            keeper,
            emergencyAdmin,
            DRAGON_ROUTER,
            false, // enableBurning
            address(tokenizedStrategyImpl)
        );
        console2.log("      MorphoStrategy:", address(morphoStrategy));

        // 2c. Spark Strategy
        console2.log("   2c. Deploying SparkYieldDonatingStrategy...");
        sparkStrategy = new SparkYieldDonatingStrategy(
            SPARK_USDC_VAULT,
            USDC,
            "FutureGood Spark USDC",
            management,
            keeper,
            emergencyAdmin,
            DRAGON_ROUTER,
            false, // enableBurning
            address(tokenizedStrategyImpl)
        );
        console2.log("      SparkStrategy:", address(sparkStrategy));

        // 3. Deploy YieldRouter
        console2.log("\n3. Deploying YieldRouter (40/30/30 split)...");
        yieldRouter = new YieldRouter(USDC, address(aaveStrategy), address(morphoStrategy), address(sparkStrategy));
        console2.log("   YieldRouter:", address(yieldRouter));

        // 4. Wire YieldSplitter to YieldRouter (CRITICAL for perpetual funding)
        console2.log("\n4. Connecting YieldSplitter to YieldRouter...");
        yieldSplitter.setYieldRouter(address(yieldRouter));
        console2.log("   YieldSplitter -> YieldRouter connected");
        console2.log("   This enables PT-as-collateral for maximum yield generation");

        // 5. Deploy Hook (Note: For production with real Uniswap V4, use CREATE2)
        if (POOL_MANAGER != address(0)) {
            console2.log("\n5. Deploying PublicGoodsYieldHook...");
            console2.log("   NOTE: For production, deploy using CREATE2 with proper flags");
            hook = new PublicGoodsYieldHook(IPoolManager(POOL_MANAGER), address(yieldRouter), address(yieldSplitter));
            console2.log("   PublicGoodsYieldHook:", address(hook));

            // Set hook as YT seller
            yieldSplitter.setYTSeller(address(hook));
            console2.log("   YieldSplitter.ytSeller set to Hook");
        } else {
            console2.log("\n5. Skipping Hook deployment (POOL_MANAGER not set)");
            console2.log("   For demo: Deploy hook later when Uniswap V4 is available");
        }

        vm.stopBroadcast();

        // 6. Print deployment summary
        _printSummary();
    }

    function _validateConfiguration() internal pure {
        require(USDC != address(0), "USDC not set");
        require(AAVE_USDC_VAULT != address(0), "Aave vault not set");
        require(MORPHO_USDC_VAULT != address(0), "Morpho vault not set");
        require(SPARK_USDC_VAULT != address(0), "Spark vault not set");
        // POOL_MANAGER is optional (for demo without Uniswap V4)
        // DRAGON_ROUTER is placeholder for demo
    }

    function _printSummary() internal view {
        console2.log("\n===========================================");
        console2.log("DEPLOYMENT COMPLETE - PERPETUAL FUNDING!");
        console2.log("===========================================");
        console2.log("");
        console2.log("Core Contracts:");
        console2.log("  TokenizedStrategy:   ", address(tokenizedStrategyImpl));
        console2.log("  YieldSplitter:       ", address(yieldSplitter));
        console2.log("  YieldRouter:         ", address(yieldRouter));
        if (address(hook) != address(0)) {
            console2.log("  PublicGoodsYieldHook:", address(hook));
        }
        console2.log("");
        console2.log("Strategies (40/30/30 split):");
        console2.log("  AaveStrategy (40%):  ", address(aaveStrategy));
        console2.log("  MorphoStrategy (30%):", address(morphoStrategy));
        console2.log("  SparkStrategy (30%): ", address(sparkStrategy));
        console2.log("");
        console2.log("Configuration:");
        console2.log("  Asset (USDC):        ", USDC);
        console2.log("  Aave Vault:          ", AAVE_USDC_VAULT);
        console2.log("  Morpho Vault:        ", MORPHO_USDC_VAULT);
        console2.log("  Spark Vault:         ", SPARK_USDC_VAULT);
        console2.log("  dragonRouter:        ", DRAGON_ROUTER);
        console2.log("  Management:          ", management);
        console2.log("  Keeper:              ", keeper);
        console2.log("");
        console2.log("How Perpetual Funding Works:");
        console2.log("1. User deposits 100 USDC -> gets 100 PT");
        console2.log("2. User's 100 USDC deployed IMMEDIATELY to strategies");
        console2.log("3. YT minted to hook, sold for ~5 USDC");
        console2.log("4. YT proceeds (5 USDC) stay in protocol FOREVER");
        console2.log("5. After user redeems PT: 5 USDC generates yield perpetually");
        console2.log("");
        console2.log("Next Steps:");
        console2.log("1. Create YT/USDC market: yieldSplitter.createYieldMarket()");
        console2.log("2. Test deposit: yieldSplitter.mintPtAndYtForPublicGoods()");
        console2.log("3. When Uniswap V4 launches: Deploy hook with CREATE2");
        console2.log("4. Create YT/USDC pool with hook on Uniswap V4");
        console2.log("5. Verify contracts on Etherscan");
        console2.log("");
        console2.log("===========================================");
        console2.log("READY TO BUILD PERPETUAL ENDOWMENTS!");
        console2.log("===========================================");
    }
}
