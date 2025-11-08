// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/console2.sol";
import {YieldRouterSetup as Setup, ERC20, IERC4626} from "./YieldRouterSetup.sol";

contract YieldRouterOperationTest is Setup {
    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupRouterOK() public {
        console2.log("address of router", address(router));
        assertTrue(address(0) != address(router));
        assertEq(address(router.asset()), address(asset));
        assertEq(address(router.aaveStrategy()), address(aaveStrategy));
        assertEq(address(router.morphoStrategy()), address(morphoStrategy));
        assertEq(address(router.sparkStrategy()), address(sparkStrategy));

        // Verify allocation constants
        assertEq(router.AAVE_ALLOCATION(), 4000); // 40%
        assertEq(router.MORPHO_ALLOCATION(), 3000); // 30%
        assertEq(router.SPARK_ALLOCATION(), 3000); // 30%
    }

    function test_depositSplits40_30_30(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Preview the deposit to see the split
        (uint256 expectedAave, uint256 expectedMorpho, uint256 expectedSpark) = router.previewDeposit(_amount);

        // Verify 40/30/30 split
        assertEq(expectedAave, (_amount * 4000) / 10000);
        assertEq(expectedMorpho, (_amount * 3000) / 10000);
        assertEq(expectedSpark, _amount - expectedAave - expectedMorpho);

        // Deposit through router
        (uint256 aaveShares, uint256 morphoShares, uint256 sparkShares) = mintAndDepositIntoRouter(user, _amount);

        // User should have received shares from all three strategies
        assertEq(aaveStrategy.balanceOf(user), aaveShares);
        assertEq(morphoStrategy.balanceOf(user), morphoShares);
        assertEq(sparkStrategy.balanceOf(user), sparkShares);

        // Verify shares are approximately equal to the amounts deposited (1:1 ratio initially)
        assertApproxEqAbs(aaveShares, expectedAave, 1e6);
        assertApproxEqAbs(morphoShares, expectedMorpho, 1e6);
        assertApproxEqAbs(sparkShares, expectedSpark, 1e6);

        console2.log("Aave shares:", aaveShares);
        console2.log("Morpho shares:", morphoShares);
        console2.log("Spark shares:", sparkShares);
    }

    function test_totalBalance(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit through router
        mintAndDepositIntoRouter(user, _amount);

        // Check total balance
        uint256 totalBalance = router.totalBalance(user);

        // Should equal the original deposit amount (approximately)
        assertApproxEqAbs(totalBalance, _amount, 1e6);

        console2.log("Total balance:", totalBalance);
        console2.log("Original deposit:", _amount);
    }

    function test_balances(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit through router
        (uint256 expectedAaveShares, uint256 expectedMorphoShares, uint256 expectedSparkShares) =
            mintAndDepositIntoRouter(user, _amount);

        // Check balances function
        (uint256 aaveShares, uint256 morphoShares, uint256 sparkShares) = router.balances(user);

        assertEq(aaveShares, expectedAaveShares);
        assertEq(morphoShares, expectedMorphoShares);
        assertEq(sparkShares, expectedSparkShares);
    }

    function test_assetBalances(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit through router
        mintAndDepositIntoRouter(user, _amount);

        // Check asset balances
        (uint256 aaveAssets, uint256 morphoAssets, uint256 sparkAssets) = router.assetBalances(user);

        // Sum should equal total balance
        uint256 sumAssets = aaveAssets + morphoAssets + sparkAssets;
        uint256 totalBalance = router.totalBalance(user);

        assertEq(sumAssets, totalBalance);

        console2.log("Aave assets:", aaveAssets);
        console2.log("Morpho assets:", morphoAssets);
        console2.log("Spark assets:", sparkAssets);
    }

    function test_withdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit through router
        mintAndDepositIntoRouter(user, _amount);

        uint256 balanceBefore = asset.balanceOf(user);

        // Use maxRedeem to avoid rounding issues
        uint256 aaveShares = aaveStrategy.maxRedeem(user);
        uint256 morphoShares = morphoStrategy.maxRedeem(user);
        uint256 sparkShares = sparkStrategy.maxRedeem(user);

        // Approve router to spend strategy shares
        vm.startPrank(user);
        IERC4626(address(aaveStrategy)).approve(address(router), aaveShares);
        IERC4626(address(morphoStrategy)).approve(address(router), morphoShares);
        IERC4626(address(sparkStrategy)).approve(address(router), sparkShares);

        // Withdraw from all strategies
        uint256 totalWithdrawn = router.withdraw(aaveShares, morphoShares, sparkShares);
        vm.stopPrank();

        // User should have received approximately their original deposit
        assertApproxEqAbs(totalWithdrawn, _amount, 1e6);
        assertApproxEqAbs(asset.balanceOf(user), balanceBefore + _amount, 1e6);

        // User should have minimal dust left (due to rounding)
        assertLt(aaveStrategy.balanceOf(user), 3);
        assertLt(morphoStrategy.balanceOf(user), 3);
        assertLt(sparkStrategy.balanceOf(user), 3);

        console2.log("Total withdrawn:", totalWithdrawn);
    }

    function test_withdrawAll(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit through router
        mintAndDepositIntoRouter(user, _amount);

        uint256 balanceBefore = asset.balanceOf(user);

        // Approve router to spend all strategy shares (use maxRedeem for rounding)
        uint256 aaveShares = aaveStrategy.maxRedeem(user);
        uint256 morphoShares = morphoStrategy.maxRedeem(user);
        uint256 sparkShares = sparkStrategy.maxRedeem(user);

        vm.startPrank(user);
        IERC4626(address(aaveStrategy)).approve(address(router), aaveShares);
        IERC4626(address(morphoStrategy)).approve(address(router), morphoShares);
        IERC4626(address(sparkStrategy)).approve(address(router), sparkShares);

        // Withdraw all using convenience function
        uint256 totalWithdrawn = router.withdrawAll();
        vm.stopPrank();

        // User should have received approximately their original deposit
        assertApproxEqAbs(totalWithdrawn, _amount, 1e6);
        assertApproxEqAbs(asset.balanceOf(user), balanceBefore + _amount, 1e6);

        // User should have minimal dust left (due to rounding)
        assertLt(aaveStrategy.balanceOf(user), 3);
        assertLt(morphoStrategy.balanceOf(user), 3);
        assertLt(sparkStrategy.balanceOf(user), 3);

        console2.log("Total withdrawn via withdrawAll:", totalWithdrawn);
    }

    function test_yieldDonationStillWorksWithRouter(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        uint256 _timeInDays = 30; // Fixed 30 days

        // Deposit through router
        (uint256 aaveShares, uint256 morphoShares, uint256 sparkShares) =
            mintAndDepositIntoRouter(user, _amount);

        // Move forward in time to simulate yield accrual
        uint256 timeElapsed = _timeInDays * 1 days;
        skip(timeElapsed);

        // Report profit on all strategies
        vm.prank(keeper);
        (uint256 aaveProfit, ) = aaveStrategy.report();

        vm.prank(keeper);
        (uint256 morphoProfit, ) = morphoStrategy.report();

        vm.prank(keeper);
        (uint256 sparkProfit, ) = sparkStrategy.report();

        console2.log("Aave profit:", aaveProfit);
        console2.log("Morpho profit:", morphoProfit);
        console2.log("Spark profit:", sparkProfit);

        // Check that dragonRouter received shares from all strategies
        uint256 dragonAaveShares = aaveStrategy.balanceOf(dragonRouter);
        uint256 dragonMorphoShares = morphoStrategy.balanceOf(dragonRouter);
        uint256 dragonSparkShares = sparkStrategy.balanceOf(dragonRouter);

        // At least one strategy should have generated profit for dragonRouter
        assertTrue(
            dragonAaveShares > 0 || dragonMorphoShares > 0 || dragonSparkShares > 0,
            "dragon router should have shares from yield"
        );

        // Approve router to spend shares and withdraw principal
        vm.startPrank(user);
        IERC4626(address(aaveStrategy)).approve(address(router), aaveShares);
        IERC4626(address(morphoStrategy)).approve(address(router), morphoShares);
        IERC4626(address(sparkStrategy)).approve(address(router), sparkShares);

        // User withdraws their principal
        router.withdraw(aaveShares, morphoShares, sparkShares);
        vm.stopPrank();

        // DragonRouter should still have shares (the yield portion)
        uint256 dragonAaveSharesAfter = aaveStrategy.balanceOf(dragonRouter);
        uint256 dragonMorphoSharesAfter = morphoStrategy.balanceOf(dragonRouter);
        uint256 dragonSparkSharesAfter = sparkStrategy.balanceOf(dragonRouter);

        assertEq(dragonAaveSharesAfter, dragonAaveShares, "dragon aave shares should remain");
        assertEq(dragonMorphoSharesAfter, dragonMorphoShares, "dragon morpho shares should remain");
        assertEq(dragonSparkSharesAfter, dragonSparkShares, "dragon spark shares should remain");

        console2.log("YieldRouter successfully maintains yield donation to dragonRouter");
    }

    function test_partialWithdrawal(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit through router
        (uint256 aaveShares, uint256 morphoShares, uint256 sparkShares) =
            mintAndDepositIntoRouter(user, _amount);

        // Withdraw half from each strategy
        uint256 halfAave = aaveShares / 2;
        uint256 halfMorpho = morphoShares / 2;
        uint256 halfSpark = sparkShares / 2;

        // Approve router to spend shares
        vm.startPrank(user);
        IERC4626(address(aaveStrategy)).approve(address(router), halfAave);
        IERC4626(address(morphoStrategy)).approve(address(router), halfMorpho);
        IERC4626(address(sparkStrategy)).approve(address(router), halfSpark);

        uint256 totalWithdrawn = router.withdraw(halfAave, halfMorpho, halfSpark);
        vm.stopPrank();

        // User should have approximately half their shares left
        assertApproxEqAbs(aaveStrategy.balanceOf(user), aaveShares - halfAave, 1);
        assertApproxEqAbs(morphoStrategy.balanceOf(user), morphoShares - halfMorpho, 1);
        assertApproxEqAbs(sparkStrategy.balanceOf(user), sparkShares - halfSpark, 1);

        console2.log("Partial withdrawal successful:", totalWithdrawn);
    }
}
