// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

using Math for uint256;

contract TestCreditPool_place_porders is CreditPoolTestSuite {
    uint256 MAX_ACTIVE_PORDERS;

    function reconfigure(InitializationParams memory params) internal pure override {
        params.marketsConfig.durations[0] = uint64(YEAR * 1e6);
        params.marketsConfig.durations[1] = uint64(YEAR * 1e6);
        params.marketsConfig.durations[2] = uint64(YEAR * 1e6);
    }

    function beforeEach() public override {
        MAX_ACTIVE_PORDERS = pool.getMaxActiveProvideOrders();
    }

    function test_cant_place_order_more_than_balance() public {
        _deposit(provider_A, 100e18);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 200e18, 1, 100e18));
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 200e18);
    }

    function test_cant_place_order_with_invalid_apr() public {
        _deposit(provider_A, 1e18);

        vm.expectRevert(abi.encodeWithSelector(InvalidAPR.selector, MAX_APR + 1, APR_TICK_SPACING, MAX_APR));
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], MAX_APR + 1, 1e18);
    }

    function test_active_provide_orders_cap_and_reuse() public {
        _deposit(provider_A, (MAX_ACTIVE_PORDERS + 1) * 1e18);

        for (uint256 i = 0; i < MAX_ACTIVE_PORDERS; ++i) {
            vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], i * APR_TICK_SPACING, 1e18);
        }

        vm.expectRevert(abi.encodeWithSelector(TooManyProvideOrders.selector, MAX_ACTIVE_PORDERS));
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], MAX_ACTIVE_PORDERS * APR_TICK_SPACING, 1e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, type(uint128).max);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], MAX_ACTIVE_PORDERS * APR_TICK_SPACING, 1e18);

        assertEq(pool.getProvideOrderBalance(markets[0], MAX_ACTIVE_PORDERS * APR_TICK_SPACING, provider_A), 1e18);
    }

    function test_order_yielding() public {
        _deposit(provider_A, 100e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 100e18);

        skip(YEAR);

        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 110e18);
    }

    function test_second_order_after_first_yield() public {
        _deposit(provider_A, 200e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 100e18);

        skip(YEAR);

        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 110e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 210e18);

        skip(YEAR);

        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 231e18);
    }

    function test_orders_in_different_time() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 200e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        skip(YEAR);

        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 200e18);
        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 110e18);
        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_B), 200e18);

        skip(YEAR);

        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 121e18);
        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_B), 220e18);
    }

    function test_independence_of_orders() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 200e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        skip(10000 * YEAR);

        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 200e18);

        skip(YEAR);

        assertApproxEqAbs(pool.getProvideOrderBalance(markets[0], 0, provider_B), 220e18, 1);
    }

    function test_position_balance_can_decrease() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        _deposit(provider_B, 300e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 200e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[1], 0, 100e18);

        pool.transferConfiguredReceiptTokenTo(address(this), 200e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 50e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_B), 100e18);
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_B), 50e18);

        _deposit_collateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 150e18);

        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 50e18 - uint256(50e18).mulDiv(50e18, 150e18));
        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_B), 100e18 - uint256(50e18).mulDiv(100e18, 150e18));
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_B), 50e18);

        assertEq(pool.loanOf(markets[0], provider_A), uint256(50e18).mulDiv(50e18, 150e18));
        assertEq(pool.loanOf(markets[0], provider_B), uint256(50e18).mulDiv(100e18, 150e18));
        assertEq(pool.loanOf(markets[1], provider_B), 0);
    }

    function test_full_position_loss_does_not_revive_old_orders() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        aaveToken.rebase(address(pool), -100e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[1], 0, 100e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_B), 100e18);

        aaveToken.rebase(address(pool), 50e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        assertEq_(pool.getProvideOrderBalance(markets[1], 0, provider_B), 150e18);
    }

    function test_full_idle_loss_preserves_existing_loan_and_debt() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        _deposit_collateral(borrower_A, markets[0], 100e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 40e18);

        aaveToken.rebase(address(pool), -60e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 40e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 40e18);

        _deposit(provider_B, 80e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[1], 0, 80e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_B), 80e18);
        assertEq(pool.loanOf(markets[0], provider_A), 40e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 40e18);
        assertEq(pool.balanceOf(borrower_A), 40e18);
    }
}

contract TestCreditPool_porder_limits is CreditPoolTestSuite {
    uint128 constant PORDER_MIN = 1e18;

    function reconfigure(InitializationParams memory params) internal pure override {
        params.provideOrderMinAmount = PORDER_MIN;

        params.marketsConfig.durations[0] = uint64(YEAR * 5);
        params.marketsConfig.durations[1] = uint64(YEAR * 5);
        params.marketsConfig.durations[2] = uint64(YEAR * 5);
    }

    function beforeEach() public override {
         _deposit(provider_A, 100e18);
    }

    function test_cant_place_order_below_min() public {
        vm.expectRevert(abi.encodeWithSelector(ProvideOrderMinAmountNotReached.selector, PORDER_MIN - 1, PORDER_MIN));
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, PORDER_MIN - 1);
    }

    function test_cant_cancel_order_below_min() public {
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, PORDER_MIN * 2);

        vm.expectRevert(abi.encodeWithSelector(ProvideOrderMinAmountNotReached.selector, PORDER_MIN - 1, PORDER_MIN));
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, PORDER_MIN + 1);
    }

    function _setupOrderBelowMin() internal {
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, PORDER_MIN * 2);
        _borrow(markets[0], borrower_A, PORDER_MIN * 101 / 100);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), PORDER_MIN * 99 / 100);
    }

    function test_cant_partial_cancel_order_when_below_min() public {
        _setupOrderBelowMin();

        vm.expectRevert(abi.encodeWithSelector(ProvideOrderMinAmountNotReached.selector, PORDER_MIN * 89 / 100, PORDER_MIN));
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 0.1e18);
    }

    function test_can_cancel_entire_order_below_min() public {
        _setupOrderBelowMin();

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, PORDER_MIN * 99 / 100);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
    }

    function test_can_cancel_order_when_yielded_over_min() public {
        _setupOrderBelowMin();

        skip(YEAR * 2);

        assertTrue(pool.getProvideOrderBalance(markets[0], 0, provider_A) > PORDER_MIN + 0.1e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 0.1e18);
    }

    function test_cant_increase_order_when_below_min() public {
        _setupOrderBelowMin();

        vm.expectRevert(abi.encodeWithSelector(ProvideOrderMinAmountNotReached.selector, PORDER_MIN * 991 / 1000, PORDER_MIN));
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 0.001e18);

        // but can increase over min
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 0.01e18);
    }
}
