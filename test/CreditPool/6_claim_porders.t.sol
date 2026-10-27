// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_claim is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _borrow(markets[0], borrower_A, 100e18);

        skip(YEAR);

        vm.prank(borrower_A); asset.approve(address(pool), 100e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 100e18);
    }

    function test_cant_claim_more_than_pool_balance() public {
        vm.expectRevert(abi.encodeWithSelector(InsufficientPoolBalance.selector, address(asset), 100e18, 110e18));
        vm.prank(provider_A); pool.claim(provider_A, markets[0], 110e18);
    }

    function test_can_claim_available_balance_before_all_market_debt_is_settled() public {
        assertEq(pool.debtOf(markets[0], borrower_A), 10e18);

        vm.prank(provider_A); pool.claim(provider_A, markets[0], 100e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 10e18);
        assertEq(pool.loanOf(markets[0], provider_A), 10e18);
        assertEq(pool.balanceOf(provider_A), 100e18);

        _deposit(borrower_A, 10e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 10e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);

        vm.prank(provider_A); pool.claim(provider_A, markets[0], 10e18);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.balanceOf(provider_A), 110e18);
    }
}

contract TestCreditPool_claim_after_offset is CreditPoolTestSuite {
    function test_can_claim_after_offset_and_remaining_debt_repayment_settle_market() public {
        _deposit(provider_A, 50e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 50e18);

        _deposit(provider_B, 50e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 50e18);

        _borrow(markets[0], borrower_A, 100e18);

        vm.prank(provider_A); pool.transferLoan(markets[0], borrower_A, 50e18);
        vm.prank(borrower_A); pool.offset(borrower_A, markets[0], type(uint128).max);

        assertEq(pool.debtOf(markets[0], borrower_A), 50e18);
        assertEq(pool.loanOf(markets[0], provider_B), 50e18);

        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 50e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);

        skip(YEAR);

        vm.prank(provider_B); pool.claim(provider_B, markets[0], type(uint128).max);

        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.balanceOf(provider_B), 50e18);
    }
}

contract TestCreditPool_claim_single is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _borrow(markets[0], borrower_A, 100e18);

        _deposit(borrower_A, 110e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 110e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);

        skip(YEAR);
    }

    function test_cant_claim_from_active_market() public {
        vm.warp(block.timestamp - YEAR);

        vm.expectRevert(abi.encodeWithSelector(ActiveMarket.selector, markets[0]));
        vm.prank(provider_A); pool.claim(provider_A, markets[0], 110e18);
    }

    function test_cant_claim_more_than_loan() public {
        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 120e18, 1, 110e18));
        vm.prank(provider_A); pool.claim(provider_A, markets[0], 120e18);
    }

    function test_can_claim_in_parts() public {
        vm.prank(provider_A); pool.claim(provider_A, markets[0], 10e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 100e18);
        assertEq(pool.balanceOf(provider_A), 10e18);

        vm.prank(provider_A); pool.claim(provider_A, markets[0], 100e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0e18);
        assertEq(pool.balanceOf(provider_A), 110e18);
    }

    function test_claim_all() public {
        vm.prank(provider_A); pool.claim(provider_A, markets[0], type(uint128).max);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.balanceOf(provider_A), 110e18);
    }

    function test_can_claim_transferred_loan() public {
        vm.expectEmit(true, true, true, true, address(pool));
        emit LoanTransferred(provider_A, provider_B, markets[0], 40e18);
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_B, 40e18);

        assertEq(pool.loanOf(markets[0], provider_A), 70e18);
        assertEq(pool.loanOf(markets[0], provider_B), 40e18);

        vm.prank(provider_B); pool.claim(provider_B, markets[0], type(uint128).max);

        assertEq(pool.loanOf(markets[0], provider_A), 70e18);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.balanceOf(provider_B), 40e18);
    }
}

contract TestCreditPool_claim_multiple is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 150e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 5 * APR_PERCENT, 50e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 50e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 150e18);

        _borrow(markets[0], borrower_A, 100e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 107.5e18); // 100 + 50 * 5% + 50 * 10%
        assertEq(pool.getProvideOrderBalance(markets[0],  5 * APR_PERCENT, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A),  37.5e18); //  50 * (1 - 50/200)
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 112.5e18); // 150 * (1 - 50/200)

        // from  5%: 52.5  = 50 * 5% + 50 * 10% * 50/200
        // from 10%: 13.75 = 50 * 50/200 * 110%
        //    total: 66.25
        assertEq(pool.loanOf(markets[0], provider_A), 66.25e18);

        // from 10%: 41.25 = 50 * 150/200 * 110%
        assertEq(pool.loanOf(markets[0], provider_B), 41.25e18);

        skip(YEAR);

        _deposit(borrower_A, 107.5e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 107.5e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
    }

    function test_can_claim_multiple_positions_in_parts() public {
        vm.prank(provider_A); pool.claim(provider_A, markets[0], 6.25e18);
        assertEq(pool.balanceOf(provider_A), 6.25e18);
        assertEq(pool.loanOf(markets[0], provider_A), 60e18);

        vm.prank(provider_A); pool.claim(provider_A, markets[0], 60e18);
        vm.prank(provider_B); pool.claim(provider_B, markets[0], type(uint128).max);

        assertEq(pool.balanceOf(provider_A), 66.25e18);
        assertEq(pool.balanceOf(provider_B), 41.25e18);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
    }
}
