// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_liquidations is CreditPoolTestSuite {
    address internal liquidator = makeAddr("Liquidator");

    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 220e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 220e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 110e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
    }

    function test_cannot_be_liquidated_during_grace_period() public {
        skip(YEAR + 1); priceOracle.touch();
        assertFalse(pool.isLiquidatable(markets[0], borrower_A));

        skip(pool.getLiquidationGracePeriod(markets[0])); priceOracle.touch();
        assertTrue(pool.isLiquidatable(markets[0], borrower_A));
    }

    function test_admin_update_does_not_shorten_grace_period_for_market_already_in_grace() public {
        uint256 gracePeriod = pool.getLiquidationGracePeriod(markets[0]);

        skip(YEAR + 1); priceOracle.touch();
        assertFalse(pool.isLiquidatable(markets[0], borrower_A));

        pool.setLiquidationGracePeriod(0);

        assertEq(pool.getLiquidationGracePeriod(markets[0]), gracePeriod);
        assertFalse(pool.isLiquidatable(markets[0], borrower_A));

        skip(gracePeriod); priceOracle.touch();
        assertTrue(pool.isLiquidatable(markets[0], borrower_A));
    }

    function test_cant_liquidate_no_debt() public {
        vm.prank(liquidator); vm.expectRevert(abi.encodeWithSelector(NotLiquidatable.selector));
        pool.liquidate(markets[0], borrower_B, 1e18, 0, type(uint256).max, "");
    }

    function test_cant_liquidate_healthy_position() public {
        vm.prank(liquidator); vm.expectRevert(abi.encodeWithSelector(NotLiquidatable.selector));
        pool.liquidate(markets[0], borrower_A, 1e18, 0, type(uint256).max, "");
    }

    function test_cant_liquidate_when_price_is_stale() public {
        vm.warp(block.timestamp + pool.getStalePriceWindow() + 1);

        vm.prank(liquidator); vm.expectRevert(abi.encodeWithSelector(StaleOraclePrice.selector, 1));
        pool.liquidate(markets[0], borrower_A, 1e18, 0, type(uint256).max, "");
    }

    function test_health_factor_reverts_for_invalid_oracle_price() public {
        priceOracle.setPrice(0);

        vm.expectRevert(abi.encodeWithSelector(InvalidOraclePrice.selector, 0, 1e18));
        pool.getHealthFactor(markets[0], borrower_A);
    }

    function test_health_factor_reverts_for_zero_oracle_denominator() public {
        priceOracle.setPriceFraction(1, 0);

        vm.expectRevert(abi.encodeWithSelector(InvalidOraclePrice.selector, 1, 0));
        pool.getHealthFactor(markets[0], borrower_A);
    }

    function test_health_factor_reverts_for_unrepresentable_oracle_price() public {
        priceOracle.setPriceFraction(uint256(type(uint128).max) + 1, 1);

        vm.expectRevert(abi.encodeWithSelector(InvalidOraclePrice.selector, uint256(type(uint128).max) + 1, 1));
        pool.getHealthFactor(markets[0], borrower_A);
    }

    function test_simple_full_liquidation() public {
        priceOracle.setPrice(0.9e18);

        _mint(liquidator, 110e18);
        uint128 collateralToSeize = 143790849673202614380;

        vm.expectEmit(true, true, true, true, address(pool));
        emit Liquidated(liquidator, borrower_A, markets[0], 110e18, collateralToSeize);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 110e18, 0, type(uint256).max, "");

        // HF = (220 * 0.9 * 0.5) / 110 = 0.9
        // d = min(max(1 - 0.9, 0) + 0.05, 0.2) = 0.15
        // collateral to seize = 110 / (0.9 * (1 - 0.15)) = 143.79
        assertApproxEqAbs(collateral.balanceOf(liquidator), 143.79e18, 1e16);
        assertApproxEqAbs(pool.collateralOf(markets[0], borrower_A), 220e18 - 143.79e18, 1e16);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
    }

    function test_simple_full_liquidation_with_max_amount() public {
        priceOracle.setPrice(0.9e18);

        _mint(liquidator, 110e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, type(uint128).max, 0, type(uint256).max, "");

        assertApproxEqAbs(collateral.balanceOf(liquidator), 143.79e18, 1e16);
        assertApproxEqAbs(pool.collateralOf(markets[0], borrower_A), 220e18 - 143.79e18, 1e16);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
    }

    function test_partial_liquidation() public {
        priceOracle.setPrice(0.9e18);

        _mint(liquidator, 55e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 55e18, 0, type(uint256).max, "");

        // HF = (220 * 0.9 * 0.5) / 110 = 0.9
        // d = min(max(1 - 0.9, 0) + 0.05, 0.2) = 0.15
        // collateral to seize = 55 / (0.9 * (1 - 0.15)) = 71.89
        assertApproxEqAbs(collateral.balanceOf(liquidator), 71.89e18, 1e16);
        assertApproxEqAbs(pool.collateralOf(markets[0], borrower_A), 220e18 - 71.89e18, 1e16);
        assertEq(pool.debtOf(markets[0], borrower_A), 55e18);
    }

    function test_partial_liquidation_can_reduce_health_factor_due_to_discount() public {
        priceOracle.setPrice(0.5e18);

        assertEq(pool.getHealthFactor(markets[0], borrower_A), 0.5e18);

        _mint(liquidator, 50e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 50e18, 0, type(uint256).max, "");

        // HF before = (220 * 0.5 * 0.5) / 110 = 0.5
        // d = min(max(1 - 0.5, 0) + 0.05, 0.2) = 0.2
        // collateral to seize = 50 / (0.5 * (1 - 0.2)) = 125
        // HF after = (95 * 0.5 * 0.5) / 60 ~= 0.39

        assertApproxEqAbs(pool.getHealthFactor(markets[0], borrower_A), 0.39e18, 1e16);

        assertEq(collateral.balanceOf(liquidator), 125e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 95e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 60e18);
    }

    function test_cant_leave_less_then_minimal_debt() public {
        priceOracle.setPrice(0.9e18);

        _mint(liquidator, 109e18);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidationAmount.selector, 1e18, 69764705882352941175, 10e18));
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 109e18, 0, type(uint256).max, "");
    }

    function test_partial_liquidation_rejects_discounted_collateral_below_minimum() public {
        priceOracle.setPrice(0.5e18);
        _mint(liquidator, 80e18);

        // Remaining debt = 30, but remaining collateral recovers only 20 * 0.5 * 0.8 = 8.
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidationAmount.selector, 30e18, 10e18, 10e18));
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 80e18, 0, type(uint256).max, "");

        assertEq(asset.balanceOf(liquidator), 80e18);
        assertEq(collateral.balanceOf(liquidator), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 220e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
    }

    function test_partial_liquidation_accepts_discounted_collateral_at_minimum() public {
        priceOracle.setPrice(0.5e18);
        _mint(liquidator, 78e18);

        // Remaining collateral recovers exactly 25 * 0.5 * 0.8 = 10.
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 78e18, 0, type(uint256).max, "");

        assertEq(asset.balanceOf(liquidator), 0);
        assertEq(collateral.balanceOf(liquidator), 195e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 25e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 32e18);
    }

    function test_partial_liquidation_rejects_one_raw_unit_above_boundary() public {
        priceOracle.setPrice(0.5e18);
        _mint(liquidator, 78e18 + 1);

        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidationAmount.selector, 32e18 - 1, 12.5e18 - 2, 10e18));
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 78e18 + 1, 0, type(uint256).max, "");
    }

    function test_partial_liquidation_uses_cached_maximum_discount_for_remainder() public {
        pool.setLiquidationDiscountMax(0.1e18);
        priceOracle.setPrice(0.5e18);
        _mint(liquidator, 79e18);

        // The market retains 20%: 22.5 * 0.5 * 0.8 = 9, versus 10.125 at the new 10%.
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidationAmount.selector, 31e18, 11.25e18, 10e18));
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 79e18, 0, type(uint256).max, "");
    }

    function test_partial_liquidation_socializes_sub_minimum_remainder_when_collateral_is_drained() public {
        priceOracle.setPrice(0.58e18);

        // HF = (220 * 0.58 * 0.5) / 110 = 0.58
        // discount = min(1 - 0.58 + 0.05, 0.2) = 0.2
        // repay = 220 * 0.58 * (1 - 0.2) = 102.08
        // bad debt = 110 - 102.08 = 7.92 < min debt remainder of 10
        _mint(liquidator, 102.08e18);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Liquidated(liquidator, borrower_A, markets[0], 102.08e18, 220e18);
        vm.expectEmit(true, true, false, true, address(pool));
        emit BadDebtIncurred(borrower_A, markets[0], 7.92e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 102.08e18, 0, type(uint256).max, "");

        assertEq(collateral.balanceOf(liquidator), 220e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 102.08e18);
    }

    function test_bad_debt_socializes_loss_across_pending_loans() public {
        priceOracle.setPrice(0.1e18);

        // HF = (220 * 0.1 * 0.5) / 110 = 0.1
        // d = min(max(1 - 0.1, 0) + 0.05, 0.2) = 0.2
        // liquidator wants to get whole collateral, so
        // debtAmount = 220 * 0.1 * (1 - 0.2) = 17.6

        _mint(liquidator, 17.6e18);

        vm.expectEmit(true, true, true, true, address(pool));
        emit Liquidated(liquidator, borrower_A, markets[0], 17.6e18, 220e18);
        vm.expectEmit(true, true, false, true, address(pool));
        emit BadDebtIncurred(borrower_A, markets[0], 92.4e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 17.6e18, 0, type(uint256).max, "");

        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(collateral.balanceOf(liquidator), 220e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18 - (110e18 - 17.6e18));
    }

    function test_claim_after_liquidate() public {
        skip(YEAR);

        priceOracle.setPrice(0.9e18);

        _mint(liquidator, 110e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 110e18, 0, type(uint256).max, "");

        vm.prank(provider_A); pool.claim(provider_A, markets[0], type(uint128).max);
        assertEq(pool.balanceOf(provider_A), 110e18);
    }

    function test_liquidate_after_grace_period() public {
        _deposit_collateral(borrower_A, markets[0], 110e18);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), UNIT * 150 / 100);

        skip(YEAR + pool.getLiquidationGracePeriod(markets[0]) + 1); priceOracle.touch();

        _mint(liquidator, 110e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 110e18, 0, type(uint256).max, "");

        // HF = 1.5
        // d = d_min = 0.05
        // C = 110 / (1 * (1 - 0.05)) = 115.79
        assertApproxEqAbs(collateral.balanceOf(liquidator), 115.79e18, 1e16);

        vm.prank(provider_A); pool.claim(provider_A, markets[0], type(uint128).max);
        assertEq(pool.balanceOf(provider_A), 110e18);
    }
}

contract TestCreditPool_collateral is CreditPoolTestSuite {
    function test_can_withdraw_collateral_after_maturity() public {
        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        skip(YEAR + 1); priceOracle.touch();

        vm.expectEmit(true, true, false, true, address(pool));
        emit CollateralWithdrawn(borrower_A, borrower_A, markets[0], 110e18);
        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 110e18);
    }
}
