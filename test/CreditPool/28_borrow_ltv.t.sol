// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_borrow_ltv is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.borrowLTV = 0.4e18;
    }

    function beforeEach() public override {
        _deposit(provider_A, 1000e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 500e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[1], 0, 500e18);
        _deposit_collateral(borrower_A, markets[0], 100e18);
    }

    function test_borrow_at_limit_succeeds_but_liquidation_limit_is_not_available() public {
        assertEq(pool.getBorrowLTV(), 0.4e18);
        assertEq(pool.getLiquidationLTV(), 0.5e18);
        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 0.8e18));
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 50e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 40e18);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), 1.25e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 40e18);
    }

    function test_collateral_withdrawal_and_move_use_borrow_limit() public {
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 32e18, 32e18);
        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 0.875e18));
        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 30e18);
        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 0.875e18));
        vm.prank(borrower_A); pool.moveCollateral(borrower_A, markets[0], markets[1], 30e18);
        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 10e18);
        vm.prank(borrower_A); pool.moveCollateral(borrower_A, markets[0], markets[1], 10e18);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), 1.25e18);
    }

    function test_liquidation_uses_its_own_limit_and_discount() public {
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 40e18);
        priceOracle.setPrice(0.8e18);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), 1e18);
        assertEq(pool.isLiquidatable(markets[0], borrower_A), false);
        vm.expectRevert(NotLiquidatable.selector);
        pool.liquidate(markets[0], borrower_A, 10e18, 0, type(uint256).max, "");
        priceOracle.setPrice(0.75e18);
        assertEq(pool.isLiquidatable(markets[0], borrower_A), true);
        _mint(provider_B, 10.65e18);
        vm.prank(provider_B); pool.liquidate(markets[0], borrower_A, 10.65e18, 0, type(uint256).max, "");
        // Liquidation HF = 0.9375; discount = 0.05 + 0.0625; repaid = 16 * 0.75 * 0.8875.
        assertEq(pool.debtOf(markets[0], borrower_A), 29.35e18);
        assertEq(collateral.balanceOf(provider_B), 16e18);
    }

    function test_provide_and_preview_cap_orders_at_borrow_limit() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, 40e18);
        priceOracle.setPrice(0.8e18);
        _deposit(provider_B, 40e18);
        (uint128 loan, uint128 assets,) = pool.previewProvideExactIn(markets[0], 40e18, 0, 10, provider_B);
        assertEq(loan, 32e18);
        assertEq(assets, 32e18);
        vm.expectRevert(abi.encodeWithSelector(ProvideNotFulfilled.selector, 32e18, 40e18));
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 40e18, 0, 10);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 40e18, 32e18, 10);
        assertEq(pool.debtOf(markets[0], borrower_A), 32e18);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), 1.25e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_A), 0);
    }

    function test_provide_at_borrow_limit_succeeds() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, 40e18);
        _deposit(provider_B, 40e18);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 40e18, 40e18, 10);
        assertEq(pool.debtOf(markets[0], borrower_A), 40e18);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), 1.25e18);
    }

    function test_collateral_reduction_cleans_orders_using_borrow_limit() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, 40e18);
        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 20e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_A), 0);
    }

    function test_partial_refinance_rejects_unhealthy_remaining_source_debt() public {
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 40e18);
        vm.warp(markets[0]);
        priceOracle.setPrice(0.9e18);
        // Keep the target healthy independently, so only the source can reject this refinance.
        _deposit_collateral(borrower_A, markets[1], 100e18);
        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](1);
        refinances[0] = RefinanceDebtParams(markets[1], 20e18, 20e18);
        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 0.9e18));
        vm.prank(borrower_A); pool.refinanceDebts(borrower_A, markets[0], 1e18, refinances);
        assertEq(pool.debtOf(markets[0], borrower_A), 40e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 0);
    }

    function test_refinance_rejects_target_between_limits_and_rolls_back() public {
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 40e18);
        vm.warp(markets[0]);
        priceOracle.touch();
        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](1);
        refinances[0] = RefinanceDebtParams(markets[1], 40e18, 50e18);
        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 0.8e18));
        vm.prank(borrower_A); pool.refinanceDebts(borrower_A, markets[0], 1e18, refinances);
        assertEq(pool.debtOf(markets[0], borrower_A), 40e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 0);
        refinances[0].assetsToBorrow = 40e18;
        vm.prank(borrower_A); pool.refinanceDebts(borrower_A, markets[0], 1e18, refinances);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.getHealthFactor(markets[1], borrower_A), 1.25e18);
    }
}
