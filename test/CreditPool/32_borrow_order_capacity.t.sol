// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";

contract TestCreditPool_borrow_order_capacity is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = 0.2e18;
    }

    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);
        _deposit_collateral(borrower_A, markets[0], 300e18);
        _deposit_collateral(borrower_B, markets[0], 1000e18);
    }

    function _place_orders_before_direct_borrow() private {
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 0, 100e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 100e18);
    }

    function test_large_provider_fills_capacity_before_cancelling_remainder() public {
        _place_orders_before_direct_borrow();
        (uint128 loan, uint128 assets, uint16 crossed) =
            pool.previewProvideExactIn(markets[0], 100e18, 0, 2, provider_B);
        assertEq(loan, 100e18);
        assertEq(assets, 100e18);
        assertEq(crossed, 2);

        OrderFill[] memory fills = new OrderFill[](2);
        fills[0] = OrderFill(borrower_A, 0, 50e18, 50e18, false);
        fills[1] = OrderFill(borrower_B, 0, 50e18, 50e18, false);
        InvalidatedBorrowOrder[] memory invalidated = new InvalidatedBorrowOrder[](1);
        invalidated[0] = InvalidatedBorrowOrder(borrower_A, 0, 50e18);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Provided(provider_B, markets[0], 100e18, 100e18, fills, invalidated, new ReconciledReloanOrder[](0));
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 0, 2);

        assertEq(pool.debtOf(markets[0], borrower_A), 150e18);
        assertEq(pool.balanceOf(borrower_A), 150e18);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), UNIT);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_A), 0);
        assertEq(pool.viewBorrowOrderNodeId(markets[0], 0, borrower_A), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_B), 50e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 50e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 1);
    }

    function test_smaller_provider_preserves_remainder_until_capacity_is_used() public {
        _place_orders_before_direct_borrow();
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 40e18, 0, 1);
        assertEq(pool.debtOf(markets[0], borrower_A), 140e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_A), 60e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 160e18);

        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 60e18, 0, 2);
        assertEq(pool.debtOf(markets[0], borrower_A), 150e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_A), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_B), 50e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 50e18);
    }

    function test_price_drop_caps_interest_bearing_fill_and_exact_out_fee() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        priceOracle.setPrice(0.5e18);
        // Maximum principal = floor(75 / 1.1); fee = floor((75 - principal) * 0.2).
        (uint128 loan, uint128 assets, uint16 crossed) =
            pool.previewProvideExactOut(markets[0], 100e18, 73_636_363_636_363_636_364, 1, provider_B);
        assertEq(loan, 73_636_363_636_363_636_364);
        assertEq(assets, 68_181_818_181_818_181_818);
        assertEq(crossed, 1);

        vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 100e18, 73_636_363_636_363_636_364, 1);
        assertEq(pool.debtOf(markets[0], borrower_A), 75e18);
        assertEq(pool.balanceOf(borrower_A), 68_181_818_181_818_181_818);
        assertEq(pool.loanOf(markets[0], provider_B), 73_636_363_636_363_636_364);
        assertEq(pool.loanOf(markets[0], address(this)), 1_363_636_363_636_363_636);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), UNIT);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].count, 0);
    }

    function test_exact_out_target_below_capacity_keeps_order() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        priceOracle.setPrice(0.5e18);
        (uint128 loan, uint128 assets,) = pool.previewProvideExactOut(markets[0], 100e18, 54e18, 1, provider_B);
        assertEq(loan, 54e18);
        assertEq(assets, 50e18);
        vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 100e18, 54e18, 1);
        assertEq(pool.debtOf(markets[0], borrower_A), 55e18);
        assertEq(pool.balanceOf(borrower_A), 50e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 50e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 50e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].count, 1);
    }

    function test_exact_out_keeps_rounding_remainder_that_can_still_borrow() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        priceOracle.setPriceFraction(2, 25e18);
        // Capacity = 12; maximum principal = 10, but ExactOut books only 10 debt.
        vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 100e18, 10, 1);
        assertEq(pool.debtOf(markets[0], borrower_A), 10);
        assertEq(pool.balanceOf(borrower_A), 10);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 100e18 - 10);

        (uint128 loan, uint128 assets,) = pool.previewProvideExactOut(markets[0], 100e18, 2, 1, provider_B);
        assertEq(loan, 2);
        assertEq(assets, 1);
        vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 100e18, 2, 1);
        assertEq(pool.debtOf(markets[0], borrower_A), 12);
        assertEq(pool.balanceOf(borrower_A), 11);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), UNIT);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
    }

    function test_no_capacity_cancels_order_and_continues() public {
        _place_orders_before_direct_borrow();
        priceOracle.setPrice(0.5e18);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 0, 2);
        assertEq(pool.debtOf(markets[0], borrower_A), 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_B), 100e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 0);
    }

    function test_capacity_below_one_asset_unit_cancels_without_increasing_debt() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 0, 100e18);
        priceOracle.setPriceFraction(1, 150e18);
        // A can take 1 unit of debt, but 1 unit of principal at 10% creates 2 units of debt.
        (uint128 loan, uint128 assets, uint16 crossed) = pool.previewProvideExactIn(markets[0], 100e18, 0, 2, provider_B);
        assertEq(loan, 3);
        assertEq(assets, 3);
        assertEq(crossed, 2);
        vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 100e18, 3, 2);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_B), 3);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_B), 0);
    }

    function test_matching_across_ticks_reads_oracle_once() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 0, 100e18);
        priceOracle.setPrice(0.5e18);
        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 1);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 0, 2);
        assertEq(pool.debtOf(markets[0], borrower_A), 75e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 31_818_181_818_181_818_182);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
    }

    function test_collateral_capacity_above_uint128_does_not_wrap() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        priceOracle.setPrice(uint256(type(uint128).max) + 1);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 0, 1);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.balanceOf(borrower_A), 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
    }

    function test_fuzz_exact_out_cancels_only_when_remaining_capacity_is_unusable(uint16 rawAPR, uint16 rawCapacity, uint16 rawTarget) public {
        uint256 APR = bound(rawAPR, 0, MAX_APR / APR_TICK_SPACING) * APR_TICK_SPACING;
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], APR, 100e18);
        uint256 capacity = bound(rawCapacity, 2, 400);
        priceOracle.setPriceFraction(capacity, 150e18);
        uint256 principal = capacity * HUNDRED_PERCENT / (HUNDRED_PERCENT + APR);
        uint256 fullDebt = (principal * (HUNDRED_PERCENT + APR) + HUNDRED_PERCENT - 1) / HUNDRED_PERCENT;
        uint128 target = uint128(bound(rawTarget, 1, fullDebt - (fullDebt - principal) / 5));

        (uint128 loan, uint128 assets,) = pool.previewProvideExactOut(markets[0], 100e18, target, 1, provider_B);
        assertEq(loan, target);
        vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 100e18, target, 1);
        uint128 debt = pool.debtOf(markets[0], borrower_A);
        assertLe(debt, capacity);
        assertGe(pool.getHealthFactor(markets[0], borrower_A), UNIT);
        assertEq(pool.balanceOf(borrower_A), assets);
        // At a one-year rate <= 20%, one principal unit costs 1 debt unit at 0%, otherwise 2.
        bool canBorrowMore = capacity - debt >= (APR == 0 ? 1 : 2);
        assertEq(pool.getBorrowOrderBalance(markets[0], APR, borrower_A), canBorrowMore ? 100e18 - assets : 0);
    }

    function test_fuzz_capacity_is_maximal_and_health_is_preserved(uint256 rawAPR, uint256 rawDuration, uint128 rawDebt, uint64 rawPrice, bool exactOut) public {
        uint256 APR = bound(rawAPR, 0, MAX_APR / APR_TICK_SPACING) * APR_TICK_SPACING;
        uint128 currentDebt = uint128(bound(rawDebt, MIN_AMOUNT, 70e18));
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], APR, 100e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], currentDebt, currentDebt);
        uint256 duration = bound(rawDuration, 1, YEAR);
        vm.warp(markets[0] - duration);
        uint256 price = bound(rawPrice, 0.5e18, 0.6e18);
        priceOracle.setPrice(price);

        uint256 capacity = (300e18 * price / UNIT) / 2 - currentDebt;
        uint256 denominator = HUNDRED_PERCENT * YEAR;
        uint256 rate = denominator + APR * duration;
        uint128 principal = uint128(capacity * denominator / rate);
        uint128 debt = uint128((principal * rate + denominator - 1) / denominator);
        uint128 netLoan = debt - (debt - principal) / 5;
        assertGt(((uint256(principal) + 1) * rate + denominator - 1) / denominator, capacity);

        (uint128 loan, uint128 assets,) = exactOut
            ? pool.previewProvideExactOut(markets[0], 100e18, netLoan, 1, provider_B)
            : pool.previewProvideExactIn(markets[0], 100e18, 0, 1, provider_B);
        assertEq(assets, principal);
        assertEq(loan, netLoan);
        if (exactOut) {
            vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 100e18, netLoan, 1);
        } else {
            vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], principal, 0, 1);
        }
        assertEq(pool.debtOf(markets[0], borrower_A), currentDebt + debt);
        assertEq(pool.balanceOf(borrower_A), currentDebt + principal);
        assertGe(pool.getHealthFactor(markets[0], borrower_A), UNIT);
        assertEq(pool.getBorrowOrderBalance(markets[0], APR, borrower_A), 0);
    }
}
