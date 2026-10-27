// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Vm } from "lib/forge-std/src/Vm.sol";

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { CreditPool } from "src/CreditPool.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { CreditPoolTestSuite, MockCreditPool } from "./0_base.t.sol";

contract TestCreditPool_borders_helpers is CreditPoolTestSuite {
    struct I { address borrower; uint256 amount; }

    function assertQueueEq(uint64 market, uint256 APR) internal view {
        assertQueueEq(market, APR, new I[](0));
    }

    function assertQueueEq(uint64 market, uint256 APR, I[1] memory expected) internal view {
        I[] memory b = new I[](expected.length);
        for (uint256 i = 0; i < expected.length; i++) b[i] = expected[i];
        assertQueueEq(market, APR, b);
    }

    function assertQueueEq(uint64 market, uint256 APR, I[2] memory expected) internal view {
        I[] memory b = new I[](expected.length);
        for (uint256 i = 0; i < expected.length; i++) b[i] = expected[i];
        assertQueueEq(market, APR, b);
    }

    function assertQueueEq(uint64 market, uint256 APR, I[3] memory expected) internal view {
        I[] memory b = new I[](expected.length);
        for (uint256 i = 0; i < expected.length; i++) b[i] = expected[i];
        assertQueueEq(market, APR, b);
    }

    function assertQueueEq(uint64 market, uint256 APR, I[] memory expected) internal view {
        MockCreditPool.TickBorrowOrderView[] memory actual = pool.viewBorrowOrderbookForTick(market, APR);

        assertEq(actual.length, expected.length, "queue length");

        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(actual[i].borrower, expected[i].borrower, "borrower at index");
            assertEq(actual[i].amount, expected[i].amount, "amount at index");
        }
    }
}

contract TestCreditPool_pool_balance is CreditPoolTestSuite {
    function test_deposit_credits_recipient_and_emits() public {
        _mint(provider_A, 42e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit AssetsDeposited(provider_A, borrower_A, 42e18);
        vm.prank(provider_A); pool.deposit(borrower_A, 42e18);

        assertEq(pool.balanceOf(borrower_A), 42e18);
        assertEq(asset.balanceOf(provider_A), 0);
    }

    function test_withdraw_debits_sender_and_emits() public {
        _deposit(provider_A, 100e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit AssetsWithdrawn(provider_A, borrower_A, 40e18);
        vm.prank(provider_A); pool.withdraw(provider_A, borrower_A, 40e18);

        assertEq(pool.balanceOf(provider_A), 60e18);
        assertEq(asset.balanceOf(borrower_A), 40e18);
    }
}

contract TestCreditPool_address_queue is CreditPoolTestSuite {
    function assert_queue_node(uint48 id, address expected_value, uint48 expected_next, uint48 expected_prev) internal view {
        (address value, uint48 next, uint48 prev) = pool.addressQueueNode(id);

        assertEq(value, expected_value);
        assertEq(uint256(next), uint256(expected_next));
        assertEq(uint256(prev), uint256(expected_prev));
    }

    function test_address_queue_remove_middle_keeps_links_consistent() public {
        uint48 id_1 = pool.addressQueuePush(borrower_A);
        uint48 id_2 = pool.addressQueuePush(borrower_B);
        uint48 id_3 = pool.addressQueuePush(borrower_C);

        pool.addressQueueRemove(id_2);

        assertEq(uint256(pool.addressQueueHead()), uint256(id_1));
        assertEq(uint256(pool.addressQueueTail()), uint256(id_3));

        assert_queue_node(id_1, borrower_A, id_3, 0);
        assert_queue_node(id_2, address(0), 0, 0);
        assert_queue_node(id_3, borrower_C, 0, id_1);
    }

    function test_address_queue_remove_is_stable_on_repeated_removal() public {
        uint48 id_1 = pool.addressQueuePush(borrower_A);
        uint48 id_2 = pool.addressQueuePush(borrower_B);
        uint48 id_3 = pool.addressQueuePush(borrower_C);
        uint48 id_4 = pool.addressQueuePush(borrower_D);

        pool.addressQueueRemove(id_2);
        pool.addressQueueRemove(id_3);
        pool.addressQueueRemove(id_2);

        assertEq(uint256(pool.addressQueueHead()), uint256(id_1));
        assertEq(uint256(pool.addressQueueTail()), uint256(id_4));

        assert_queue_node(id_1, borrower_A, id_4, 0);
        assert_queue_node(id_2, address(0), 0, 0);
        assert_queue_node(id_3, address(0), 0, 0);
        assert_queue_node(id_4, borrower_D, 0, id_1);
    }

    function test_address_queue_remove_updates_head_and_tail() public {
        uint48 id_1 = pool.addressQueuePush(borrower_A);
        uint48 id_2 = pool.addressQueuePush(borrower_B);
        uint48 id_3 = pool.addressQueuePush(borrower_C);

        pool.addressQueueRemove(id_1);

        assertEq(uint256(pool.addressQueueHead()), uint256(id_2));
        assertEq(uint256(pool.addressQueueTail()), uint256(id_3));

        assert_queue_node(id_2, borrower_B, id_3, 0);

        pool.addressQueueRemove(id_3);

        assertEq(uint256(pool.addressQueueHead()), uint256(id_2));
        assertEq(uint256(pool.addressQueueTail()), uint256(id_2));

        assert_queue_node(id_2, borrower_B, 0, 0);

        pool.addressQueueRemove(id_2);

        assertEq(uint256(pool.addressQueueHead()), 0);
        assertEq(uint256(pool.addressQueueTail()), 0);

        assert_queue_node(id_2, address(0), 0, 0);
    }
}

contract TestCreditPool_borders is TestCreditPool_borders_helpers {
    function test_empty_borrow_order_by_default() public view {
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
    }

    function test_active_borrow_orders_cap_and_reuse() public {
        uint256 MAX_ACTIVE_BORDERS = pool.getMaxActiveBorrowOrders();

        _deposit_collateral(borrower_A, markets[0], 1000e18);

        for (uint256 i = 0; i < MAX_ACTIVE_BORDERS; ++i) {
            vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], i * APR_TICK_SPACING, 1e18);
        }

        vm.expectRevert(abi.encodeWithSelector(TooManyBorrowOrders.selector, MAX_ACTIVE_BORDERS));
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], MAX_ACTIVE_BORDERS * APR_TICK_SPACING, 1e18);

        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 0, type(uint128).max);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], MAX_ACTIVE_BORDERS * APR_TICK_SPACING, 1e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], MAX_ACTIVE_BORDERS * APR_TICK_SPACING, borrower_A), 1e18);
    }

    function test_can_create_borrow_order_even_when_max_active_orders_reached_on_another_market() public {
        uint256 MAX_ACTIVE_BORDERS = pool.getMaxActiveBorrowOrders();

        uint64 MARKET_A = markets[0];
        uint64 MARKET_B = markets[1];

        _deposit_collateral(borrower_A, MARKET_A, 1000e18);
        _deposit_collateral(borrower_A, MARKET_B, 1000e18);

        for (uint256 i = 0; i < MAX_ACTIVE_BORDERS; ++i) {
            vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, MARKET_A, i * APR_TICK_SPACING, 1e18);
        }

        vm.expectRevert(abi.encodeWithSelector(TooManyBorrowOrders.selector, MAX_ACTIVE_BORDERS));
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, MARKET_A, MAX_ACTIVE_BORDERS * APR_TICK_SPACING, 1e18);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, MARKET_B, MAX_ACTIVE_BORDERS * APR_TICK_SPACING, 1e18);

        assertEq(pool.getBorrowOrderBalance(MARKET_B, MAX_ACTIVE_BORDERS * APR_TICK_SPACING, borrower_A), 1e18);
    }

    function test_cant_place_order_without_collateral() public {
        _deposit_collateral(borrower_A, markets[0], 50e18);

        // hf = 50% * (50 / 100) = 25%
        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 25e16));
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0 * APR_PERCENT, 100e18);
    }

    function test_can_cancel_borrow_order() public {
        _deposit_collateral(borrower_A, markets[0], 250e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 100e18);

        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 60e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 40e18);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 100e18, 1, 40e18));
        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
    }

    function test_cancel_borrow_order_all_with_max() public {
        _deposit_collateral(borrower_A, markets[0], 250e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, type(uint128).max);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
        assertQueueEq(markets[0], 10 * APR_PERCENT);
    }


    function test_cant_provide_with_worse_rate() public {
        _deposit_collateral(borrower_A, markets[0], 250e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        _deposit(provider_A, 100e18);
        vm.expectRevert(abi.encodeWithSelector(ProvideMinLoanNotReached.selector, 55e18, 60e18));
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 50e18, 60e18, 10);
    }

    function test_single_borrow_order_and_provide() public {
        _deposit_collateral(borrower_A, markets[0], 250e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 100e18);

        _deposit(provider_A, 50e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 50e18, 51e18, 10);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 50e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 55e18);
        assertEq(pool.loanOf(markets[0], provider_A), 55e18);
        assertEq(pool.balanceOf(borrower_A), 50e18);

        _deposit(provider_B, 50e18);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 50e18, 51e18, 10);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.loanOf(markets[0], provider_B), 55e18);
        assertEq(pool.balanceOf(borrower_A), 100e18);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 200e18, 1, 100e18));
        vm.prank(borrower_A); pool.withdraw(borrower_A, borrower_A, 200e18);

        vm.prank(borrower_A); pool.withdraw(borrower_A, borrower_A, 100e18);
        assertEq(pool.balanceOf(borrower_A), 0);
        assertEq(asset.balanceOf(borrower_A), 100e18);
    }

    function test_withdraw_assets_all_with_max() public {
        _deposit_collateral(borrower_A, markets[0], 250e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 100e18, 101e18, 10);

        vm.prank(borrower_A); pool.withdraw(borrower_A, borrower_A, type(uint128).max);

        assertEq(pool.balanceOf(borrower_A), 0);
        assertEq(asset.balanceOf(borrower_A), 100e18);
    }

    function test_apr_priority() public {
        _deposit(provider_A, 100e18);

        _deposit_collateral(borrower_A, markets[0], 300e18);
        _deposit_collateral(borrower_B, markets[0], 300e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 20 * APR_PERCENT, 100e18);

        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 50e18, 51e18, 10);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 20 * APR_PERCENT, borrower_B), 50e18);
        assertEq(pool.loanOf(markets[0], provider_A), 60e18);
    }

    function test_dodep() public {
        _deposit_collateral(borrower_A, markets[0], 220e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 100e18);

        _deposit_collateral(borrower_A, markets[0], 110e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 50e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 150e18);
    }

    function test_fifo_and_generations() public {
        _deposit_collateral(borrower_A, markets[0], 250e18);
        _deposit_collateral(borrower_B, markets[0], 250e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 100e18);

        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_B, 100e18)]);

        _deposit(provider_A, 150e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 150e18, 151e18, 10);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_B), 50e18);

        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_B, 50e18)]);
        assertEq(pool.loanOf(markets[0], provider_A), 165e18);

        _deposit_collateral(borrower_A, markets[0], 150e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 50e18);

        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_B, 50e18), I(borrower_A, 50e18)]);

        _deposit(provider_B, 70e18);
        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 1);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 70e18, 71e18, 10);

        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 30e18)]);
        assertEq(pool.loanOf(markets[0], provider_B), 77e18);
    }

    function test_lazily_filled_borrow_order_syncs_on_next_place_same_apr() public {
        _deposit_collateral(borrower_A, markets[0], 500e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 100e18, 0, 10);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
        assertQueueEq(markets[0], 10 * APR_PERCENT);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 50e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 50e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 50e18)]);
    }

    function test_lazily_filled_borrow_order_does_not_block_active_order_limit() public {
        uint256 MAX_ACTIVE_BORDERS = pool.getMaxActiveBorrowOrders();

        _deposit_collateral(borrower_A, markets[0], 1000e18);

        for (uint256 i = 0; i < MAX_ACTIVE_BORDERS; ++i) {
            vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], i * APR_TICK_SPACING, 1e18);
        }

        _deposit(provider_A, 1e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 1e18, 0, 10);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], MAX_ACTIVE_BORDERS * APR_TICK_SPACING, 1e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], MAX_ACTIVE_BORDERS * APR_TICK_SPACING, borrower_A), 1e18);
    }

    function test_cancel_lazily_filled_borrow_order_is_noop() public {
        _deposit_collateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 100e18, 0, 10);

        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, type(uint128).max);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
        assertQueueEq(markets[0], 10 * APR_PERCENT);
    }

    function test_borrow_orders_removal_on_unhealthy_debt() public {
        _deposit_collateral(borrower_A, markets[0], 250e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 100e18);

        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 10e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 100e18);

        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 1);
        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 50e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
    }

    function test_withdraw_collateral_all_with_max() public {
        _deposit_collateral(borrower_A, markets[0], 300e18);

        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, type(uint128).max);

        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(collateral.balanceOf(borrower_A), 300e18);
    }

    function test_can_withdraw_collateral_when_oracle_price_is_stale_if_debt_is_zero() public {
        _deposit_collateral(borrower_A, markets[0], 300e18);

        vm.warp(pool.getStalePriceWindow() + 1);

        assertEq(pool.getHealthFactor(markets[0], borrower_A), UNIT);

        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 300e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(collateral.balanceOf(borrower_A), 300e18);
    }

    function test_borrow_orders_without_collaterall_will_be_deleted() public {
        _deposit_collateral(borrower_A, markets[0], 300e18);
        _deposit_collateral(borrower_B, markets[0], 300e18);
        _deposit_collateral(borrower_C, markets[0], 300e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_C); pool.placeBorrowOrder(borrower_C, markets[0], 10 * APR_PERCENT, 100e18);

        vm.prank(borrower_B); pool.withdrawCollateral(borrower_B, markets[0], borrower_B, 300e18);

        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_C, 100e18)]);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_B), 0);
        assertEq(pool.debtOf(markets[0], borrower_C), 0);

        _deposit(provider_A, 300e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 200e18, 200e18, 10);

        assertQueueEq(markets[0], 10 * APR_PERCENT /* [] */);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 0);
        assertEq(pool.debtOf(markets[0], borrower_C), 110e18);
    }

    function test_claim_after_provide() public {
        _deposit_collateral(borrower_A, markets[0], 250e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 100e18, 101e18, 10);

        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);

        skip(YEAR);

        _deposit(borrower_A, 110e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 110e18);
        vm.prank(provider_A); pool.claim(provider_A, markets[0], 110e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
    }

    function test_total_cleanup_after_withdraw_collateral() public {
        _deposit_collateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        // 10 / 0.05
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 100e18);

        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 300e18);

        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 0);

        assertQueueEq(markets[0], 10 * APR_PERCENT);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
    }
}

contract TestCreditPool_provide_own_order is TestCreditPool_borders_helpers {
    function beforeEach() public override {
        _deposit_collateral(borrower_A, markets[0], 300e18);
        _deposit_collateral(borrower_B, markets[0], 300e18);
        _deposit_collateral(borrower_C, markets[0], 300e18);
        _deposit_collateral(borrower_D, markets[0], 300e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_C); pool.placeBorrowOrder(borrower_C, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_D); pool.placeBorrowOrder(borrower_D, markets[0], 9 * APR_PERCENT, 100e18);

        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_B, 100e18), I(borrower_C, 100e18)]);
        assertQueueEq(markets[0], 9 * APR_PERCENT, [I(borrower_D, 100e18)]);

        _deposit(borrower_A, 300e18);
        _deposit(borrower_B, 300e18);
        _deposit(borrower_C, 300e18);
    }

    function test_provide_skip_own_orders_1() public {
        vm.prank(borrower_A); pool.provideExactIn(borrower_A, markets[0], 300e18, 300e18, 10);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18)]);
    }

    function test_provide_skip_own_orders_2() public {
        vm.prank(borrower_B); pool.provideExactIn(borrower_B, markets[0], 300e18, 300e18, 10);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_B, 100e18)]);
    }

    function test_provide_skip_own_orders_3() public {
        vm.prank(borrower_C); pool.provideExactIn(borrower_C, markets[0], 300e18, 300e18, 10);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_C, 100e18)]);
    }

    function test_self_skip_keeps_head_before_partially_filled_order() public {
        (uint128 loan, uint128 assets, uint16 crossed) =
            pool.previewProvideExactIn(markets[0], 50e18, 0, 2, borrower_A);
        assertEq(loan, 55e18);
        assertEq(assets, 50e18);
        assertEq(crossed, 2);

        vm.prank(borrower_A); pool.provideExactIn(borrower_A, markets[0], 50e18, 55e18, 2);
        assertEq(pool.loanOf(markets[0], borrower_A), 55e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_B, 50e18), I(borrower_C, 100e18)]);
    }

    function test_restored_self_head_prev_stays_zero_when_already_head() public {
        _assert_restored_self_links(borrower_A, 50e18, 0, 2);
    }

    function test_restored_self_head_prev_is_cleared_after_consumed_prefix() public {
        _assert_restored_self_links(borrower_B, 150e18, 1, 3);
    }

    function test_restored_self_head_prev_is_cleared_when_originally_tail() public {
        _assert_restored_self_links(borrower_C, 250e18, 2, 0);
    }

    function _assert_restored_self_links(address account, uint128 amount, uint48 previous, uint48 next) private {
        uint48 id = pool.viewBorrowOrderNodeId(markets[0], 10 * APR_PERCENT, account);
        (uint48 prevBefore,) = pool.viewBorrowOrderNodeLinks(markets[0], 10 * APR_PERCENT, id);
        assertEq(prevBefore, previous);

        vm.prank(account); pool.provideExactIn(account, markets[0], amount, 0, 4);

        assertEq(pool.viewBorrowOrderbookForTick(markets[0], 10 * APR_PERCENT)[0].borrower, account);
        assertEq(pool.viewBorrowOrderNodeId(markets[0], 10 * APR_PERCENT, account), id);
        (uint48 prevAfter, uint48 nextAfter) = pool.viewBorrowOrderNodeLinks(markets[0], 10 * APR_PERCENT, id);
        assertEq(prevAfter, 0);
        assertEq(nextAfter, next);
    }

    function test_self_skip_restores_middle_order_as_head_exact_out() public {
        (uint128 loan, uint128 assets, uint16 crossed) =
            pool.previewProvideExactOut(markets[0], 200e18, 165e18, 3, borrower_B);
        assertEq(loan, 165e18);
        assertEq(assets, 150e18);
        assertEq(crossed, 3);

        vm.prank(borrower_B); pool.provideExactOut(borrower_B, markets[0], 200e18, 165e18, 3);
        assertEq(pool.loanOf(markets[0], borrower_B), 165e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_B, 100e18), I(borrower_C, 50e18)]);

        // Cancellation uses the saved node ID and its repaired backward/forward links.
        vm.prank(borrower_B); pool.cancelBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 100e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_C, 50e18)]);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 100e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_C, 50e18), I(borrower_B, 100e18)]);
    }

    function test_self_skip_respects_crossing_limit_and_rolls_back() public {
        (, uint128 assets, uint16 crossed) = pool.previewProvideExactIn(markets[0], 50e18, 0, 1, borrower_A);
        assertEq(assets, 0);
        assertEq(crossed, 1);
        vm.expectRevert(abi.encodeWithSelector(ProvideMaxCrossedOrdersExceeded.selector, 2, 1));
        vm.prank(borrower_A); pool.provideExactIn(borrower_A, markets[0], 50e18, 0, 1);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_B, 100e18), I(borrower_C, 100e18)]);
        assertEq(pool.balanceOf(borrower_A), 300e18);
    }

    function test_self_skip_cannot_rotate_dust_orders_to_tail() public {
        _deposit(provider_A, 300e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 100e18 - 1, 0, 1);
        vm.prank(borrower_A); pool.provideExactIn(borrower_A, markets[0], MIN_AMOUNT, 0, 2);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 1), I(borrower_B, 100e18 - MIN_AMOUNT), I(borrower_C, 100e18)]);

        // Reaching B consumes A's dust first, so the next self-skip cannot accumulate it.
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 100e18 - MIN_AMOUNT, 0, 2);
        vm.prank(borrower_B); pool.provideExactIn(borrower_B, markets[0], MIN_AMOUNT, 0, 2);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_B, 1), I(borrower_C, 100e18 - MIN_AMOUNT)]);
    }

    function test_restored_single_self_order_keeps_tail_and_tick_active() public {
        vm.prank(borrower_C); pool.provideExactIn(borrower_C, markets[0], 250e18, 0, 4);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_C, 100e18)]);
        _deposit_collateral(borrower_A, markets[0], 100e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 50e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_C, 100e18), I(borrower_A, 50e18)]);
        vm.prank(borrower_C); pool.cancelBorrowOrder(borrower_C, markets[0], 10 * APR_PERCENT, 100e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 50e18)]);
    }

    function test_self_skip_does_not_revive_filled_orders_after_restored_head() public {
        vm.prank(borrower_A); pool.provideExactIn(borrower_A, markets[0], 150e18, 0, 3);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_B), 0);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_C, 50e18)]);

        _deposit_collateral(borrower_B, markets[0], 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 50e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_C, 50e18), I(borrower_B, 50e18)]);
    }

    function test_self_skip_does_not_revive_collateral_limited_order() public {
        _deposit_collateral(borrower_C, markets[0], 300e18);
        priceOracle.setPrice(0.5e18);
        vm.prank(borrower_A); pool.provideExactIn(borrower_A, markets[0], 100e18, 0, 3);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_B), 0);
        assertEq(pool.debtOf(markets[0], borrower_B), 75e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_C, 68_181_818_181_818_181_818)]);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 168_181_818_181_818_181_818);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].count, 2);
    }

    function test_full_cancel_clears_node_id_without_changing_neighbors() public {
        vm.prank(borrower_B); pool.cancelBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, type(uint128).max);
        assertEq(pool.viewBorrowOrderNodeId(markets[0], 10 * APR_PERCENT, borrower_B), 0);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_C, 100e18)]);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 200e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].count, 2);
    }

    function test_cancel_filled_order_after_self_skip_does_not_remove_it_twice() public {
        vm.prank(borrower_A); pool.provideExactIn(borrower_A, markets[0], 150e18, 0, 3);
        assertEq(pool.viewBorrowOrderNodeId(markets[0], 10 * APR_PERCENT, borrower_A), 1);
        assertEq(pool.viewBorrowOrderNodeId(markets[0], 10 * APR_PERCENT, borrower_B), 0);

        vm.prank(borrower_B); pool.cancelBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, type(uint128).max);
        assertEq(pool.getAllBorrowOrders(markets[0], borrower_B).length, 0);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_C, 50e18)]);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 150e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].count, 2);
    }

    function test_collateral_cleanup_clears_node_id() public {
        vm.prank(borrower_B); pool.withdrawCollateral(borrower_B, markets[0], borrower_B, 300e18);
        assertEq(pool.viewBorrowOrderNodeId(markets[0], 10 * APR_PERCENT, borrower_B), 0);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_C, 100e18)]);
    }

    function test_skipping_own_order_counts_once_for_max_crossed_orders() public {
        (, uint256 consumedAssets, uint16 crossedOrders) = pool.previewProvideExactIn(markets[0], 250e18, 0, 4, borrower_A);
        assertEq(consumedAssets, 250e18);
        assertEq(crossedOrders, 4);

        vm.prank(borrower_A); pool.provideExactIn(borrower_A, markets[0], 250e18, 0, 4);

        assertEq(pool.loanOf(markets[0], borrower_A), 274.5e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18)]);
        assertQueueEq(markets[0],  9 * APR_PERCENT, [I(borrower_D,  50e18)]);
    }

    function test_full_borrow_order_cancel_removes_from_queue() public {
        vm.prank(borrower_B); pool.cancelBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 50e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_B, 50e18), I(borrower_C, 100e18)]);

        vm.prank(borrower_B); pool.cancelBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 50e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18), I(borrower_C, 100e18)]);

        vm.prank(borrower_C); pool.cancelBorrowOrder(borrower_C, markets[0], 10 * APR_PERCENT, 100e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_A, 100e18)]);

        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT);
    }
}

contract TestCreditPool_provide_stop is TestCreditPool_borders_helpers {
    uint256 internal constant INITIAL_BALANCE = 100e18;

    function provided() public view returns (uint256) {
        return INITIAL_BALANCE - pool.balanceOf(provider_A);
    }

    function beforeEach() public override {
        _deposit(provider_A, INITIAL_BALANCE);
        _deposit_collateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
    }

    function test_dont_stop_on_min_loan() public {
        OrderFill[] memory fills = new OrderFill[](1);
        fills[0] = OrderFill(borrower_A, 10 * APR_PERCENT, 50e18, 55e18, false);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Provided(provider_A, markets[0], 50e18, 55e18, fills, new InvalidatedBorrowOrder[](0), new ReconciledReloanOrder[](0));
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 50e18, 51e18, 10);
        assertEq(provided(), 50e18);
        assertEq(pool.loanOf(markets[0], provider_A), 55e18);
    }

    function test_stop_on_min_loan() public {
        (uint256 collected, uint256 paid,) = pool.previewProvideExactOut(markets[0], 50e18, 51e18, 10, provider_A);
        assertEq(collected, 51e18);
        assertApproxEqAbs(paid, 46.36e18, 1e16);

        OrderFill[] memory fills = new OrderFill[](1);
        fills[0] = OrderFill(borrower_A, 10 * APR_PERCENT, 46363636363636363637, 51e18, false);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Provided(provider_A, markets[0], 46363636363636363637, 51e18, fills, new InvalidatedBorrowOrder[](0), new ReconciledReloanOrder[](0));
        vm.prank(provider_A); pool.provideExactOut(provider_A, markets[0], 50e18, 51e18, 10);
        assertApproxEqAbs(provided(), 46.36e18, 1e16);
        assertEq(pool.loanOf(markets[0], provider_A), 51e18);
    }

    function test_max_crossed_orders_limits_provide_exact_in() public {
        _deposit_collateral(borrower_B, markets[0], 300e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 100e18);
        _deposit(provider_A, 50e18);
        vm.prank(provider_A); asset.approve(address(pool), 150e18);

        (uint256 collectedLoan, uint256 consumedAssets, uint16 crossedOrders) = pool.previewProvideExactIn(markets[0], 150e18, 0, 1, provider_A);
        assertEq(collectedLoan, 110e18);
        assertEq(consumedAssets, 100e18);
        assertEq(crossedOrders, 1);

        vm.expectRevert(abi.encodeWithSelector(ProvideMaxCrossedOrdersExceeded.selector, 2, 1));
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 150e18, 0, 1);

        (collectedLoan, consumedAssets, crossedOrders) = pool.previewProvideExactIn(markets[0], 150e18, 0, 2, provider_A);
        assertEq(collectedLoan, 165e18);
        assertEq(consumedAssets, 150e18);
        assertEq(crossedOrders, 2);

        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 150e18, 0, 2);
        assertEq(pool.loanOf(markets[0], provider_A), 165e18);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(borrower_B, 50e18)]);
    }
}

contract TestCreditPool_reloan_order is TestCreditPool_borders_helpers {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.maxActiveBorrowOrders = 3;
    }

    function beforeEach() public override {
        _deposit(provider_A, 200e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 200e18);
        _borrow(markets[0], borrower_A, 100e18);

        _deposit_collateral(provider_A, markets[0], 1000e18);
        _deposit(provider_B, 200e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.collateralOf(markets[0], provider_A), 1000e18);
        assertEq(pool.balanceOf(borrower_A), 100e18);
        assertEq(pool.balanceOf(provider_B), 200e18);
    }

    function test_cant_place_more_than_loan() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);

        vm.expectRevert(abi.encodeWithSelector(ReloanOrderExceedsLoan.selector, 200e18, 110e18));
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);
    }

    function test_zero_apr_borrow_order_does_not_initialize_reloan_locator() public {
        vm.prank(provider_D); pool.reconcileReloanOrder(borrower_D, markets[0]);

        vm.prank(provider_A); pool.placeBorrowOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_D); pool.reconcileReloanOrder(provider_A, markets[0]);

        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 100e18);
        assertEq(pool.getBorrowOrderType(markets[0], 0, provider_A), BOrderType.Borrow);

        vm.prank(provider_A); pool.cancelBorrowOrder(provider_A, markets[0], 0, type(uint128).max);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 10e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 10e18);
        assertEq(pool.getBorrowOrderType(markets[0], 0, provider_A), BOrderType.Reloan);
    }

    function test_same_apr_reloan_top_up_reuses_node_and_second_apr_reverts() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 40e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 30e18);

        assertQueueEq(markets[0], 5 * APR_PERCENT, [I(provider_A, 70e18)]);

        vm.expectRevert(abi.encodeWithSelector(ReloanOrderAlreadyExists.selector, 5 * APR_PERCENT));
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 10e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 70e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
    }

    function test_full_cancel_resets_reloan_locator_and_allows_new_apr() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 100e18);
        vm.recordLogs();
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 0, type(uint128).max);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        _assert_reloan_cancellation(logs[0], provider_A, 0, 100e18, false);

        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 0);
        assertQueueEq(markets[0], 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 100e18);
        assertQueueEq(markets[0], 5 * APR_PERCENT, [I(provider_A, 100e18)]);
    }

    function test_full_cancel_resets_reloan_locator_while_borrow_order_remains() public {
        vm.prank(provider_A); pool.placeBorrowOrder(provider_A, markets[0], 10 * APR_PERCENT, 20e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 0, type(uint128).max);

        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 20e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 100e18);
    }

    function test_lazy_full_fill_can_be_reconciled_before_new_reloan_apr() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 0, 10);

        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 10e18);

        vm.prank(provider_D); pool.reconcileReloanOrder(provider_A, markets[0]);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 10e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 10e18);
        assertQueueEq(markets[0], 5 * APR_PERCENT, [I(provider_A, 10e18)]);
    }

    function test_transfer_loan_reconciles_reloan_order_in_place() public {
        vm.prank(provider_A); pool.placeBorrowOrder(provider_A, markets[0], 5 * APR_PERCENT, 20e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ReloanOrderCancelled(provider_A, markets[0], 10 * APR_PERCENT, 50e18, true);
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_C, 60e18);

        assertEq(pool.loanOf(markets[0], provider_A), 50e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 20e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 50e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 45454545454545454545);
        assertQueueEq(markets[0], 10 * APR_PERCENT, [I(provider_A, 50e18)]);
    }

    function test_reconcile_removes_middle_reloan_node() public {
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_C, 30e18);
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_D, 30e18);

        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 50e18);
        vm.prank(provider_C); pool.placeReloanOrder(provider_C, markets[0], 0, 30e18);
        vm.prank(provider_D); pool.placeReloanOrder(provider_D, markets[0], 0, 30e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ReloanOrderCancelled(provider_C, markets[0], 0, 30e18, true);
        vm.prank(provider_C); pool.transferLoan(markets[0], provider_B, 30e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_C), 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 80e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 2);
        assertQueueEq(markets[0], 0, [I(provider_A, 50e18), I(provider_D, 30e18)]);
    }

    function test_self_skip_keeps_reloan_order_ahead_of_partial_fill() public {
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_C, 30e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 50e18);
        vm.prank(provider_C); pool.placeReloanOrder(provider_C, markets[0], 0, 30e18);
        _deposit(provider_A, 20e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 20e18, 20e18, 2);
        assertQueueEq(markets[0], 0, [I(provider_A, 50e18), I(provider_C, 10e18)]);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 60e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 2);
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 0, type(uint128).max);
        assertQueueEq(markets[0], 0, [I(provider_C, 10e18)]);
    }

    function test_reloan_cancel_and_backing_cleanup_clear_node_ids() public {
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_C, 30e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 50e18);
        vm.prank(provider_C); pool.placeReloanOrder(provider_C, markets[0], 0, 30e18);
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 0, type(uint128).max);
        assertEq(pool.viewBorrowOrderNodeId(markets[0], 0, provider_A), 0);
        vm.prank(provider_C); pool.transferLoan(markets[0], provider_B, 30e18);
        assertEq(pool.viewBorrowOrderNodeId(markets[0], 0, provider_C), 0);
        assertQueueEq(markets[0], 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 0);
    }

    function test_permissionless_reconcile_resizes_reloan_after_bad_debt() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 110e18);
        pool.badDebt(markets[0], 10e18);

        assertEq(pool.loanOf(markets[0], provider_A), 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 100e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 110e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ReloanOrderCancelled(provider_A, markets[0], 0, 10e18, true);
        vm.prank(provider_D); pool.reconcileReloanOrder(provider_A, markets[0]);

        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 100e18);
        assertQueueEq(markets[0], 0, [I(provider_A, 100e18)]);

        vm.recordLogs();
        vm.prank(provider_C); pool.reconcileReloanOrder(provider_A, markets[0]);
        assertEq(vm.getRecordedLogs().length, 0);

        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 100e18);
        assertQueueEq(markets[0], 0, [I(provider_A, 100e18)]);
    }

    function test_fuzz_permissionless_reconcile_after_bad_debt(uint96 rawLoss) public {
        uint128 loss = uint128(bound(rawLoss, 1, 109.5e18));
        uint128 remainingLoan = 110e18 - loss;
        uint128 expectedOrder = remainingLoan < 1e18 ? 0 : remainingLoan;

        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 110e18);
        pool.badDebt(markets[0], loss);

        vm.prank(provider_D); pool.reconcileReloanOrder(provider_A, markets[0]);

        assertEq(pool.loanOf(markets[0], provider_A), remainingLoan);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), expectedOrder);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, expectedOrder);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, expectedOrder == 0 ? 0 : 1);
    }

    function test_permissionless_reconcile_removes_finalized_reloan_order() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 110e18);

        skip(YEAR);

        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 110e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 1);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ReloanOrderCancelled(provider_A, markets[0], 0, 110e18, true);
        vm.prank(provider_D); pool.reconcileReloanOrder(provider_A, markets[0]);

        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 0);
        assertQueueEq(markets[0], 0);
    }

    function test_partial_reloan_fill_clamps_order_to_remaining_loan() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 110e18);
        pool.badDebt(markets[0], 10e18);

        vm.recordLogs();
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 40e18, 0, 10);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Provided.selector);
        (uint128 assetsProvided, uint128 loanReceived, OrderFill[] memory fills, InvalidatedBorrowOrder[] memory invalidated, ReconciledReloanOrder[] memory reconciled) =
            abi.decode(logs[0].data, (uint128, uint128, OrderFill[], InvalidatedBorrowOrder[], ReconciledReloanOrder[]));
        assertEq(assetsProvided, 40e18);
        assertEq(loanReceived, 40e18);
        assertEq(fills.length, 1);
        assertEq(fills[0].account, provider_A);
        assertEq(fills[0].loanAmount, 40e18);
        assertEq(fills[0].isReloan, true);
        assertEq(invalidated.length, 0);
        assertEq(reconciled.length, 1);
        // 110 ordered - 40 filled - 60 still backed = 10 cancelled.
        _assert_provided_reconciliation(logs[0], provider_A, 0, 10e18);

        assertEq(pool.loanOf(markets[0], provider_A), 60e18);
        assertEq(pool.loanOf(markets[0], provider_B), 40e18);
        assertEq(pool.balanceOf(provider_A), 40e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 60e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 60e18);
        assertQueueEq(markets[0], 0, [I(provider_A, 60e18)]);
    }

    function test_partial_reloan_fill_keeps_sub_minimum_remainder_for_next_provider() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 1e18 + 2_000);

        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 1e18, 0, 10);

        assertEq(pool.loanOf(markets[0], provider_A), 109e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 2_000);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 2_000);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 1);
        assertQueueEq(markets[0], 0, [I(provider_A, 2_000)]);

        vm.prank(provider_D); pool.reconcileReloanOrder(provider_A, markets[0]);

        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 2_000);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 2_000);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 1);
        assertQueueEq(markets[0], 0, [I(provider_A, 2_000)]);

        (uint256 collectedLoan, uint256 consumedAssets, uint256 crossedOrders) = pool.previewProvideExactIn(
            markets[0], 2_000, 2_000, 1, provider_C
        );
        assertEq(collectedLoan, 2_000);
        assertEq(consumedAssets, 2_000);
        assertEq(crossedOrders, 1);

        _deposit(provider_C, 2_000);
        vm.prank(provider_C); pool.provideExactIn(provider_C, markets[0], 2_000, 2_000, 1);

        assertEq(pool.loanOf(markets[0], provider_A), 109e18 - 2_000);
        assertEq(pool.loanOf(markets[0], provider_C), 2_000);
        assertEq(pool.balanceOf(provider_A), 1e18 + 2_000);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 0);
        assertQueueEq(markets[0], 0);
    }

    function test_can_cancel_reloan_order() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 100e18);
        assertEq(pool.getBorrowOrderType(markets[0], 5 * APR_PERCENT, provider_A), BOrderType.Reloan);

        vm.recordLogs();
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 60e18);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        _assert_reloan_cancellation(logs[0], provider_A, 5 * APR_PERCENT, 60e18, false);
        assertEq(pool.getBorrowOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 40e18);
        assertEq(pool.getBorrowOrderType(markets[0], 5 * APR_PERCENT, provider_A), BOrderType.Reloan);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 100e18, 1, 40e18));
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);
    }

    function test_cant_place_border_from_another_type() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);
        assertEq(pool.getBorrowOrderType(markets[0], 5 * APR_PERCENT, provider_A), BOrderType.Reloan);

        vm.expectRevert(abi.encodeWithSelector(BorrowOrderTypeMismatch.selector, BOrderType.Borrow, BOrderType.Reloan));
        vm.prank(provider_A); pool.placeBorrowOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);

        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);
        vm.prank(provider_A); pool.placeBorrowOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);
        assertEq(pool.getBorrowOrderType(markets[0], 5 * APR_PERCENT, provider_A), BOrderType.Borrow);
    }

    function test_reloan_order() public {
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 110e18);

        vm.recordLogs();
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 101e18, 10);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Provided.selector);
        (,,,, ReconciledReloanOrder[] memory reconciled) =
            abi.decode(logs[0].data, (uint128, uint128, OrderFill[], InvalidatedBorrowOrder[], ReconciledReloanOrder[]));
        assertEq(reconciled.length, 0);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.debtOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 110e18);
        assertEq(pool.balanceOf(provider_A), 100e18);
    }

    function test_reloan_order_stop() public {
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 110e18);

        vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 100e18, 66e18, 10);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 44e18);
        assertEq(pool.debtOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
        assertEq(pool.loanOf(markets[0], provider_B), 66e18);
        assertEq(pool.balanceOf(provider_A), 60e18);
    }

    function test_reloan_order_partial() public {
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 84e18);

        vm.recordLogs();
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 20e18, 21e18, 10);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Provided.selector);
        (,,,, ReconciledReloanOrder[] memory reconciled) =
            abi.decode(logs[0].data, (uint128, uint128, OrderFill[], InvalidatedBorrowOrder[], ReconciledReloanOrder[]));
        assertEq(reconciled.length, 0);

        assertEq(pool.getBorrowOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 63e18);
        assertEq(pool.debtOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 89e18);
        assertEq(pool.loanOf(markets[0], provider_B), 21e18);
        assertEq(pool.balanceOf(provider_A), 20e18);
    }

    function test_reloan_order_less_than_balance() public {
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 110e18);

        pool.badDebt(markets[0], 10e18);

        (uint256 collectedLoan, uint256 consumedAssets,) = pool.previewProvideExactIn(markets[0], 100e18, 101e18, 10, provider_B);
        assertEq(collectedLoan, 100e18);
        assertEq(consumedAssets, 100e18);

        vm.recordLogs();
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 0, 10);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Provided.selector);
        _assert_provided_reconciliation(logs[0], provider_A, 0, 10e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.debtOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 100e18);
        assertEq(pool.balanceOf(provider_A), 100e18);
    }

    function test_permissionless_reconcile_commits_after_failed_provide() public {
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 110e18);

        vm.prank(provider_A); pool.transferLoan(markets[0], provider_C, 55e18);
        pool.badDebt(markets[0], 110e18 - 1);
        assertEq(pool.loanOf(markets[0], provider_A), 0);

        vm.expectRevert(abi.encodeWithSelector(ProvideMinLoanNotReached.selector, 0, 101e18));
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 101e18, 10);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 50e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].count, 1);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ReloanOrderCancelled(provider_A, markets[0], 10 * APR_PERCENT, 55e18, true);
        vm.prank(provider_D); pool.reconcileReloanOrder(provider_A, markets[0]);

        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].count, 0);

        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 101e18, 1);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 0);
    }

    function test_zero_available_reloan_does_not_leave_stale_tick_total() public {
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 110e18);

        vm.prank(provider_A); pool.transferLoan(markets[0], provider_C, 55e18);
        pool.badDebt(markets[0], 110e18 - 1);

        _deposit_collateral(borrower_B, markets[0], 400e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 100e18);

        vm.recordLogs();
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 0, 10);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Provided.selector);
        _assert_provided_reconciliation(logs[0], provider_A, 10 * APR_PERCENT, 55e18);

        // 10 / 0.05
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 0);
        assertQueueEq(markets[0], 10 * APR_PERCENT);
    }

    function test_provided_preserves_all_three_matching_arrays() public {
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_C, 55e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 55e18);
        _deposit_collateral(borrower_B, markets[0], 20e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 0, 10e18);
        vm.prank(provider_C); pool.placeReloanOrder(provider_C, markets[0], 0, 55e18);
        _deposit_collateral(borrower_D, markets[0], 400e18);
        vm.prank(borrower_D); pool.placeBorrowOrder(borrower_D, markets[0], 0, 20e18);
        pool.badDebt(markets[0], 22e18);
        priceOracle.setPrice(0.25e18);

        vm.recordLogs();
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 0, 10);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Provided.selector);
        (uint128 assets, uint128 loan, OrderFill[] memory fills, InvalidatedBorrowOrder[] memory invalidated, ReconciledReloanOrder[] memory reconciled) =
            abi.decode(logs[0].data, (uint128, uint128, OrderFill[], InvalidatedBorrowOrder[], ReconciledReloanOrder[]));
        assertEq(assets, 100e18);
        assertEq(loan, 100e18);
        assertEq(fills.length, 4);
        assertEq(abi.encode(fills[0]), abi.encode(OrderFill(provider_A, 0, 44e18, 44e18, true)));
        assertEq(abi.encode(fills[1]), abi.encode(OrderFill(borrower_B, 0, 2.5e18, 2.5e18, false)));
        assertEq(abi.encode(fills[2]), abi.encode(OrderFill(provider_C, 0, 44e18, 44e18, true)));
        assertEq(abi.encode(fills[3]), abi.encode(OrderFill(borrower_D, 0, 9.5e18, 9.5e18, false)));
        assertEq(invalidated.length, 1);
        assertEq(abi.encode(invalidated[0]), abi.encode(InvalidatedBorrowOrder(borrower_B, 0, 7.5e18)));
        assertEq(reconciled.length, 2);
        assertEq(abi.encode(reconciled[0]), abi.encode(ReconciledReloanOrder(provider_A, 0, 11e18)));
        assertEq(abi.encode(reconciled[1]), abi.encode(ReconciledReloanOrder(provider_C, 0, 11e18)));
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_D), 10.5e18);
        assertEq(pool.loanOf(markets[0], provider_B), 100e18);
    }

    function _assert_provided_reconciliation(Vm.Log memory log, address account, uint256 APR, uint128 amount) private pure {
        (,,,, ReconciledReloanOrder[] memory reconciled) =
            abi.decode(log.data, (uint128, uint128, OrderFill[], InvalidatedBorrowOrder[], ReconciledReloanOrder[]));
        assertEq(reconciled.length, 1);
        assertEq(abi.encode(reconciled[0]), abi.encode(ReconciledReloanOrder(account, APR, amount)));
    }

    function _pool_logs(Vm.Log[] memory logs) private view returns (Vm.Log[] memory poolLogs) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool)) ++count;
        }
        poolLogs = new Vm.Log[](count);
        count = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool)) poolLogs[count++] = logs[i];
        }
    }

    function _assert_reloan_cancellation(Vm.Log memory log, address account, uint256 APR, uint128 amount, bool reconciled) private view {
        assertEq(log.topics.length, 3);
        assertEq(log.topics[0], keccak256("ReloanOrderCancelled(address,uint64,uint256,uint128,bool)"));
        assertEq(log.topics[1], bytes32(uint256(uint160(account))));
        assertEq(log.topics[2], bytes32(uint256(markets[0])));
        assertEq(log.data, abi.encode(APR, amount, reconciled));
    }

}

contract TestCreditPool_reloan_edge_cases is TestCreditPool_borders_helpers {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.borrowOrderMinAmount = MIN_AMOUNT;
    }

    function beforeEach() public override {
        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        _provide(markets[0], provider_A, 100e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
    }

    function test_provide_reloan_does_not_overburn_shrunken_positive_apr_loan() public {
        uint128 remainingLoan = MIN_AMOUNT * 110 / 100;

        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 110e18);
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_C, 110e18 - remainingLoan);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), remainingLoan);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, MIN_AMOUNT);
        assertEq(pool.loanOf(markets[0], provider_A), remainingLoan);
        assertEq(pool.loanOf(markets[0], provider_C), 110e18 - remainingLoan);

        (uint256 collectedLoan, uint256 consumedAssets,) = pool.previewProvideExactIn(markets[0], MIN_AMOUNT, 0, 10, provider_B);
        assertEq(collectedLoan, remainingLoan);
        assertEq(consumedAssets, MIN_AMOUNT);

        _deposit(provider_B, MIN_AMOUNT);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], MIN_AMOUNT, 0, 10);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), remainingLoan);
        assertEq(pool.loanOf(markets[0], provider_C), 110e18 - remainingLoan);
        assertEq(pool.balanceOf(provider_A), MIN_AMOUNT);
    }

    function test_transfer_loan_deletes_reloan_order_below_minimum() public {
        uint128 remainingLoan = MIN_AMOUNT * 110 / 100 - 1;

        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 110e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ReloanOrderCancelled(provider_A, markets[0], 10 * APR_PERCENT, 110e18, true);
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_C, 110e18 - remainingLoan);

        assertEq(pool.loanOf(markets[0], provider_A), remainingLoan);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.getBorrowOrderbook(markets[0])[200].amount, 0);
        assertQueueEq(markets[0], 10 * APR_PERCENT);
    }
}

contract TestCreditPool_multicall is TestCreditPool_borders_helpers {
    function test_multicall() public {
        _mint_collateral(borrower_A, 300e18);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(CreditPool.depositCollateral.selector, borrower_A, markets[0], 300e18);
        calls[1] = abi.encodeWithSelector(CreditPool.placeBorrowOrder.selector, borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(borrower_A); pool.multicall(calls);

        assertEq(pool.collateralOf(markets[0], borrower_A), 300e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 100e18);
    }
}

contract TestCreditPool_border_limits is CreditPoolTestSuite {
    uint128 constant BORDER_MIN = 1e18;

    function reconfigure(InitializationParams memory params) internal pure override {
        params.borrowOrderMinAmount = BORDER_MIN;
        params.marketsConfig.durations = [uint64(YEAR * 5), uint64(YEAR * 5), uint64(YEAR * 5)];
    }

    function beforeEach() public override {
        _deposit(provider_A, 1000e18);
        _deposit_collateral(borrower_A, markets[0], 999e18);
    }

    function test_cant_place_order_below_min() public {
        vm.expectRevert(abi.encodeWithSelector(BorrowOrderMinAmountNotReached.selector, BORDER_MIN - 1, BORDER_MIN));
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, BORDER_MIN - 1);
    }

    function test_cant_cancel_order_below_min() public {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, BORDER_MIN * 2);

        vm.expectRevert(abi.encodeWithSelector(BorrowOrderMinAmountNotReached.selector, BORDER_MIN - 1, BORDER_MIN));
        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 0, BORDER_MIN + 1);
    }

    function _setupOrderBelowMin() internal {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, BORDER_MIN * 2);
        _provide(markets[0], provider_A, BORDER_MIN * 101 / 100);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_A), BORDER_MIN * 99 / 100);
    }

    function test_cant_partial_cancel_order_when_below_min() public {
        _setupOrderBelowMin();

        vm.expectRevert(abi.encodeWithSelector(BorrowOrderMinAmountNotReached.selector, BORDER_MIN * 89 / 100, BORDER_MIN));
        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 0, 0.1e18);
    }

    function test_can_cancel_entire_order_below_min() public {
        _setupOrderBelowMin();

        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 0, BORDER_MIN * 99 / 100);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, borrower_A), 0);
    }

    function test_cant_increase_order_when_below_min() public {
        _setupOrderBelowMin();

        vm.expectRevert(abi.encodeWithSelector(BorrowOrderMinAmountNotReached.selector, BORDER_MIN * 991 / 1000, BORDER_MIN));
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, 0.001e18);

        // but can increase over min
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, 0.01e18);
    }

    function _setupLoan() internal {
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, 10e18);
        _provide(markets[0], provider_A, 10e18);
        assertEq(pool.loanOf(markets[0], provider_A), 10e18);
    }

    function test_place_reloan_orders() public {
        _setupLoan();

        // 1 / (1 + 0.05 * 5) = 0.8 < 1
        vm.expectRevert(abi.encodeWithSelector(BorrowOrderMinAmountNotReached.selector, BORDER_MIN * 8 / 10, BORDER_MIN));
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 1e18);

        // 1.1 / (1 + 0.05 * 5) = 0.88 < 1
        vm.expectRevert(abi.encodeWithSelector(BorrowOrderMinAmountNotReached.selector, BORDER_MIN * 88 / 100, BORDER_MIN));
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 5 * APR_PERCENT, 1.1e18);

        // 1.1 / (1 + 0.021 * 5) = 0.995 < 1
        vm.expectRevert(abi.encodeWithSelector(BorrowOrderMinAmountNotReached.selector, 995475113122171945, BORDER_MIN));
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 21 * APR_PERCENT / 10, 1.1e18);

        // 1.1 / (1 + 0.02 * 5) = 1 >= 1
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 2 * APR_PERCENT, 1.1e18);
    }

    function test_reloan_orders_are_checked_under_max_reward() public {
        _setupLoan();

        skip(YEAR);

        // same order as in test before, but 1 year later

        // 1.1 / (1 + 0.021 * 5) = 1.01 >= 1
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 21 * APR_PERCENT / 10, 1.1e18);
    }

    function test_reloan_orders_can_increase_over_time() public {
        _setupLoan();

        // 1.1 / (1 + 0.02 * 5) = 1
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 2 * APR_PERCENT, 1.1e18);

        // order is perfectly on min amount, can't cancel any
        vm.expectPartialRevert(BorrowOrderMinAmountNotReached.selector);
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 2 * APR_PERCENT, 0.01e18);

        skip(YEAR);

        // (1.1 - 0.02) / (1 + 0.02 * 4) = 1
        // after 1 year, order is above min amount, can cancel a bit

        vm.expectPartialRevert(BorrowOrderMinAmountNotReached.selector);
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 2 * APR_PERCENT, 0.021e18);
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 2 * APR_PERCENT, 0.02e18);

        skip(YEAR);

        // (1.1 - 0.04) / (1 + 0.02 * 3) = 1
        // after 1 year, order is above min amount, can cancel a bit more
        vm.expectPartialRevert(BorrowOrderMinAmountNotReached.selector);
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 2 * APR_PERCENT, 0.021e18);
        vm.prank(provider_A); pool.cancelReloanOrder(provider_A, markets[0], 2 * APR_PERCENT, 0.02e18);
    }
}
