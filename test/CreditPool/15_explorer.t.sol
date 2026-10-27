// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_explorer is CreditPoolTestSuite {
    uint64 market;
    uint256 apr_A = 1_00;
    uint256 apr_B = 1_20;
    uint256 apr_C = 2_00;

    function beforeEach() public override {
        market = markets[0];
    }

    function test_get_borrow_orderbook_aggregates_borrow_and_reloan_orders() public {
        BorrowOrderbookTickView[] memory orderbook;

        _deposit_collateral(borrower_A, market, 200e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, market, apr_A, 50e18);

        _deposit_collateral(borrower_B, market, 200e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, market, apr_B, 70e18);

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, market, apr_C, 100e18);
        _borrow(market, borrower_C, 100e18);
        assertEq(pool.loanOf(market, provider_A), 102e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, market, apr_C, 102e18);
        assertEq(pool.getBorrowOrderBalance(market, apr_C, provider_A), 102e18);

        orderbook = pool.getBorrowOrderbook(market);

        assertEq(orderbook.length, (MAX_APR / APR_TICK_SPACING) + 1);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].amount, 50e18);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].count, 1);
        assertEq(orderbook[apr_B / APR_TICK_SPACING].amount, 70e18);
        assertEq(orderbook[apr_B / APR_TICK_SPACING].count, 1);
        assertEq(orderbook[apr_C / APR_TICK_SPACING].amount, 100e18);
        assertEq(orderbook[apr_C / APR_TICK_SPACING].count, 1);
    }

    function test_get_borrow_orderbook_count_tracks_order_deletions() public {
        BorrowOrderbookTickView[] memory orderbook;

        _deposit_collateral(borrower_A, market, 300e18);
        _deposit_collateral(borrower_B, market, 300e18);
        _deposit_collateral(borrower_C, market, 300e18);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, market, apr_A, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, market, apr_A, 100e18);
        vm.prank(borrower_C); pool.placeBorrowOrder(borrower_C, market, apr_A, 100e18);

        orderbook = pool.getBorrowOrderbook(market);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].count, 3);

        vm.prank(borrower_B); pool.cancelBorrowOrder(borrower_B, market, apr_A, type(uint128).max);

        orderbook = pool.getBorrowOrderbook(market);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].count, 2);

        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, market, apr_A, type(uint128).max);

        orderbook = pool.getBorrowOrderbook(market);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].count, 1);

        vm.prank(borrower_C); pool.cancelBorrowOrder(borrower_C, market, apr_A, type(uint128).max);

        orderbook = pool.getBorrowOrderbook(market);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].count, 0);
    }

    function test_get_borrow_orderbook_count_tracks_head_shift_after_skip_own_order() public {
        BorrowOrderbookTickView[] memory orderbook;

        _deposit_collateral(borrower_A, market, 300e18);
        _deposit_collateral(borrower_B, market, 300e18);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, market, apr_A, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, market, apr_A, 100e18);

        orderbook = pool.getBorrowOrderbook(market);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].count, 2);

        _deposit(borrower_A, 100e18);
        vm.prank(borrower_A); pool.provideExactIn(borrower_A, market, 100e18, 0, 10);

        orderbook = pool.getBorrowOrderbook(market);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].amount, 100e18);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].count, 1);
    }

    function test_get_borrow_orderbook_count_does_not_change_on_partial_fill() public {
        BorrowOrderbookTickView[] memory orderbook;

        _deposit_collateral(borrower_A, market, 300e18);
        _deposit_collateral(borrower_B, market, 300e18);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, market, apr_A, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, market, apr_A, 100e18);

        _deposit(provider_A, 50e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, market, 50e18, 0, 10);

        orderbook = pool.getBorrowOrderbook(market);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].amount, 150e18);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].count, 2);
    }

    function test_get_provide_orderbook_zeros_stale_ticks_after_bucket_consumption() public {
        ProvideOrderbookTickView[] memory orderbook;

        _deposit(provider_A, 50e18);
        _deposit(provider_B, 70e18);
        _deposit(provider_C, 100e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, market, apr_A, 50e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, apr_B, 70e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, market, apr_C, 100e18);

        orderbook = pool.getProvideOrderbook(market);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].amount, 50e18);
        assertEq(orderbook[apr_B / APR_TICK_SPACING].amount, 70e18);
        assertEq(orderbook[apr_C / APR_TICK_SPACING].amount, 100e18);

        (uint128 borrowed, uint128 debt) = pool.previewBorrow(market, 150e18, borrower_A);
        assertEq(borrowed, 150e18);

        _mint_collateral(borrower_A, 400e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, market, 400e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, market, 150e18, debt);

        orderbook = pool.getProvideOrderbook(market);
        assertEq(orderbook[apr_A / APR_TICK_SPACING].amount, 0);
        assertEq(orderbook[apr_B / APR_TICK_SPACING].amount, 0);
        assertEq(orderbook[apr_C / APR_TICK_SPACING].amount, 70e18);
    }
}
