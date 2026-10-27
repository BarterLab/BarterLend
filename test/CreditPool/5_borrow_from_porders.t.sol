// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_borrow is CreditPoolTestSuite {
    function test_cant_borrow_from_empty_orderbook() public {
        vm.expectRevert(abi.encodeWithSelector(BorrowAssetsNotReached.selector, 50e18, 0));
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 50e18);
    }

    function test_cant_borrow_from_inactive_market() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        skip(YEAR);

        vm.expectRevert(abi.encodeWithSelector(InactiveMarket.selector, markets[0]));
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 50e18);
    }

    function test_cant_borrow_because_of_apr() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        vm.expectRevert(abi.encodeWithSelector(BorrowDebtExceeded.selector, 55e18, 54e18));
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 54e18);
    }

    function test_cant_borrow_same_liquidity_twice() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        _mint_collateral(borrower_A, 200e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 200e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 100e18);

        vm.expectRevert(abi.encodeWithSelector(BorrowAssetsNotReached.selector, MIN_AMOUNT, 0));
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], MIN_AMOUNT, MIN_AMOUNT);
    }

    function test_cant_borrow_with_wrong_collateral() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 0));
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 50e18);

        _mint_collateral(borrower_A, 200e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 50e18);

        // hf = 50% * (50 / 50) = 50%
        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 50e16));
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 50e18);
    }

    function test_simple_borrow_zero_apr() public {
        _deposit(provider_A, 100e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        _mint_collateral(borrower_A, 200e18);
        vm.expectEmit(true, true, false, true, address(pool));
        emit CollateralDeposited(borrower_A, markets[0], 200e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 200e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit Borrowed(borrower_A, markets[0], 40e18, 40e18, 0);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 40e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 60e18);
        assertEq(pool.loanOf(markets[0], provider_A), 40e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 40e18);
        assertEq(pool.balanceOf(borrower_A), 40e18);
    }

    function test_simple_borrow_nonzero_apr() public {
        _deposit(provider_A, 100e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 100e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 100e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 44e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 60e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 44e18);
        assertEq(pool.balanceOf(borrower_A), 40e18);
    }

    function test_cant_withdraw_collateral_when_bad_ltv() public {
        test_simple_borrow_nonzero_apr();

        // hf = 50% * ((100 - 50) / 44) = 56.(81)%
        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 568181818181818181));
        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 50e18);
    }

    function test_repay() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 100e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 100e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 44e18);

        assertEq(pool.balanceOf(borrower_A), 40e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 44e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 60e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);

        vm.prank(borrower_A); asset.approve(address(pool), 20e18);
        vm.expectEmit(true, true, true, true, address(pool));
        emit DebtRepaid(borrower_A, borrower_A, markets[0], 20e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 20e18);
        assertEq(pool.balanceOf(borrower_A), 20e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 24e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 60e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 40e18, 1, 24e18));
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 40e18);

        _deposit(borrower_A, 4e18);
        vm.prank(borrower_A); asset.approve(address(pool), 24e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 24e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 60e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
    }

    function test_borrow_best_apr() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 20 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 200e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 200e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 55e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 50e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 20 * APR_PERCENT, provider_B), 100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 55e18);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 55e18); // 10%
    }

    function test_composite_apr_borrow() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 20 * APR_PERCENT, 100e18);

        vm.expectRevert(abi.encodeWithSelector(BorrowDebtExceeded.selector, 206e18, 198e18));
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 180e18, 198e18);

        _mint_collateral(borrower_A, 500e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 500e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 180e18, 206e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 20 * APR_PERCENT, provider_B), 20e18);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.loanOf(markets[0], provider_B), 96e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 206e18); // 14.(4)% = (100*10% + 80*20%) / 180
    }

    function test_loan_and_debt_dont_yield() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 100e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 100e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 44e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 60e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 44e18);
        assertEq(pool.balanceOf(borrower_A), 40e18);

        skip(YEAR);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 66e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 44e18);
        assertEq(pool.balanceOf(borrower_A), 40e18);
    }

    function test_aave_rebase_in_both_directions_affects_only_idle_liquidity() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 200e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 200e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 80e18, 88e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 60e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 60e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
        assertEq(pool.loanOf(markets[0], provider_B), 44e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 88e18);
        assertEq(pool.balanceOf(borrower_A), 80e18);

        aaveToken.rebase(address(pool), 12e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 66e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 66e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
        assertEq(pool.loanOf(markets[0], provider_B), 44e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 88e18);
        assertEq(pool.balanceOf(borrower_A), 80e18);

        _deposit(provider_C, 68e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[1], 20 * APR_PERCENT, 68e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 66e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 66e18);
        assertEq(pool.getProvideOrderBalance(markets[1], 20 * APR_PERCENT, provider_C), 68e18);

        aaveToken.rebase(address(pool), -20e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 59.4e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 59.4e18);
        assertEq(pool.getProvideOrderBalance(markets[1], 20 * APR_PERCENT, provider_C), 61.2e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
        assertEq(pool.loanOf(markets[0], provider_B), 44e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 88e18);
        assertEq(pool.balanceOf(borrower_A), 80e18);
    }

    function test_full_idle_loss_preserves_lazy_bucket_loan_during_materialization() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);
        _deposit(provider_C, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 100e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[1], 0, 100e18);

        _deposit_collateral(borrower_A, markets[0], 500e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 200e18, 200e18);

        aaveToken.rebase(address(pool), -100e18);

        _deposit(provider_D, 50e18);
        vm.prank(provider_D); pool.placeProvideOrder(provider_D, markets[2], 0, 50e18);

        vm.prank(provider_A); pool.transferLoan(markets[0], provider_D, 100e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_B), 0);
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_C), 0);
        assertEq(pool.getProvideOrderBalance(markets[2], 0, provider_D), 50e18);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 100e18);
        assertEq(pool.loanOf(markets[0], provider_D), 100e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 200e18);
        assertEq(pool.balanceOf(borrower_A), 200e18);
    }

    function test_near_total_idle_loss_preserves_partial_loan_when_tick_is_reset() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], APR_TICK_SPACING, 100e18);

        _deposit_collateral(borrower_A, markets[0], 100e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 40e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 60e18);
        assertEq(pool.getProvideOrderBalance(markets[0], APR_TICK_SPACING, provider_B), 100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 40e18);

        aaveToken.rebase(address(pool), -(160e18 - 1));

        _deposit(provider_C, 100e18);
        vm.expectRevert(abi.encodeWithSelector(
            UnderlyingPoolIndexPrecisionExhausted.selector,
            6_250_000,
            100e18 + 1
        ));
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 0, 100e18);

        assertEq(pool.balanceOf(provider_C), 100e18);
        assertEq(aaveToken.balanceOf(address(pool)), 1);

        pool.settleUnderlyingPoolDust();
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 0, 100e18);
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_D, 40e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], APR_TICK_SPACING, provider_B), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_C), 100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_D), 40e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 40e18);
        assertEq(pool.balanceOf(borrower_A), 40e18);
        assertEq(aaveToken.balanceOf(address(pool)), 100e18);
        assertEq(pool.balanceOf(address(this)), 1);
    }

    function test_pro_rata_borrowing() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 200e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 200e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 80e18, 88e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 60e18);
        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 60e18);
        assertEq(pool.loanOf(markets[0], provider_B), 44e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 88e18);
    }

    function test_pro_rata_borrow_unbalanced() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 900e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 900e18);

        _mint_collateral(borrower_A, 300e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 110e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 90e18);
        assertEq(pool.loanOf(markets[0], provider_A), 11e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 810e18);
        assertEq(pool.loanOf(markets[0], provider_B), 99e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
    }

    // hehe dodep
    function test_dodeps() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 150e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 150e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 55e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 50e18);
        assertEq(pool.loanOf(markets[0], provider_A), 55e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 55e18);

        _deposit(provider_A, 50e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 50e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 55e18);

        _mint_collateral(borrower_A, 300e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 110e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0e18);
        assertEq_(pool.loanOf(markets[0], provider_A), 165e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 165e18);
    }

    function test_dodep_after_delay() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        skip(YEAR / 2); priceOracle.touch();

        assertEq_(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 105e18);
        assertEq(pool.loanOf(markets[0], provider_A), 0);

        _mint_collateral(borrower_A, 150e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 150e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 52.5e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 55e18);
        assertEq_(pool.loanOf(markets[0], provider_A), 52.5e18);

        _deposit(provider_A, 50e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 50e18);

        _deposit(provider_B, 50e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 50e18);

        assertEq_(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 105e18);
        assertEq_(pool.loanOf(markets[0], provider_A), 52.5e18);
        assertEq_(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 50e18);
        assertEq_(pool.loanOf(markets[0], provider_B), 0);

        _mint_collateral(borrower_A, 400e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 155e18, 162.75e18);

        assertEq_(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0e18);
        assertEq_(pool.loanOf(markets[0], provider_A), 162.75e18);
        assertEq_(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 0e18);
        assertEq_(pool.loanOf(markets[0], provider_B), 52.5e18);
        assertEq_(pool.debtOf(markets[0], borrower_A), 215.25e18);
    }

    function test_reopened_tick_does_not_revive_old_lender_position() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 300e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 110e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);

        _deposit(provider_B, 50e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 50e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 50e18);
        assertEq(pool.loanOf(markets[0], provider_B), 0);

        _mint_collateral(borrower_B, 200e18);
        vm.prank(borrower_B); pool.depositCollateral(borrower_B, markets[0], 200e18);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], 50e18, 55e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 55e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 55e18);
    }

    function test_full_cancel_then_reopen_same_tick_does_not_revive_old_position() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 300e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 50e18, 55e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 50e18);
        assertEq(pool.loanOf(markets[0], provider_A), 55e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, type(uint128).max);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 55e18);

        _deposit(provider_B, 50e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 50e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 55e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 50e18);
        assertEq(pool.loanOf(markets[0], provider_B), 0);

        _mint_collateral(borrower_B, 200e18);
        vm.prank(borrower_B); pool.depositCollateral(borrower_B, markets[0], 200e18);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], 50e18, 55e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 55e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 55e18);
    }
}

contract TestCreditPool_borrow_from_myself is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(provider_A, 300e18);
        _mint_collateral(borrower_A, 300e18);
        _mint_collateral(borrower_B, 300e18);
        vm.prank(provider_A); pool.depositCollateral(provider_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_B); pool.depositCollateral(borrower_B, markets[0], 300e18);
    }

    function test_own_orders_are_not_accounted() public {
        vm.expectRevert(abi.encodeWithSelector(BorrowAssetsNotReached.selector, 200e18, 100e18));
        vm.prank(provider_A); pool.borrow(provider_A, markets[0], 200e18, 220e18);
    }

    function test_preview_borrow_skips_own_orders() public view {
        (uint128 borrowed, uint128 debt) = pool.previewBorrow(markets[0], 200e18, provider_A);

        assertEq(borrowed, 100e18);
        assertEq(debt, 110e18);
    }

    function test_no_loan_from_own_orders_partial() public {
        vm.prank(provider_A); pool.borrow(provider_A, markets[0], 50e18, 55e18);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 55e18);
        assertEq(pool.debtOf(markets[0], provider_A), 55e18);
    }

    function test_correct_loan_after_noloan_partial_borrow() public {
        vm.prank(provider_A); pool.borrow(provider_A, markets[0], 50e18, 55e18);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], 60e18, type(uint128).max);

        assertEq_(pool.loanOf(markets[0], provider_A), 44e18); // (60 * (100 / 150)) * 110%
        assertEq(pool.loanOf(markets[0], provider_B), 55e18 + 22e18); // (60 * (50 / 150)) * 110%
    }

    function test_correct_loan_after_noloan_full_borrow() public {
        vm.prank(provider_A); pool.borrow(provider_A, markets[0], 100e18, 110e18);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], 100e18, type(uint128).max);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.loanOf(markets[0], provider_B), 110e18);
    }
}

contract TestCreditPool_borrow_with_fee is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT * 5 / 100; // 5%
    }

    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _deposit_collateral(borrower_A, markets[0], 300e18);
    }

    function test_borrow_with_fee() public {
        vm.expectRevert(abi.encodeWithSelector(BorrowAssetsNotReached.selector, 400e18, 100e18));
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 400e18, type(uint128).max);

        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, type(uint128).max);

        assertEq(pool.loanOf(markets[0], provider_A), 109.5e18);
        assertEq(pool.loanOf(markets[0], address(this)), 0.5e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.balanceOf(borrower_A), 100e18);
    }

    function test_preview_with_fee() public view {
        (uint128 borrowed, uint128 debt) = pool.previewBorrow(markets[0], 400e18, borrower_A);

        assertEq(borrowed, 100e18);
        assertEq(debt, 110e18);
    }

    function test_repay_all_with_max() public {
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, type(uint128).max);

        _deposit(borrower_A, 10e18);
        vm.prank(borrower_A); asset.approve(address(pool), 110e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], type(uint128).max);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.getAvailableToClaim(markets[0]), 110e18);
        assertEq(pool.balanceOf(borrower_A), 0);
    }
}

contract TestCreditPool_borrow_preview_dust is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT * 5 / 100;
        params.provideOrderMinAmount = 1;
        params.borrowOrderMinAmount = 1;
    }

    function test_preview_borrow_matches_execution_without_fee_adjustment() public {
        _deposit(provider_A, 2100);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 2100);

        _mint_collateral(borrower_A, 5000);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 5000);

        (uint128 borrowed, uint128 debt) = pool.previewBorrow(markets[0], MIN_AMOUNT, borrower_A);

        assertEq(borrowed, MIN_AMOUNT);
        assertEq(debt, MIN_AMOUNT);

        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], borrowed, debt);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 100);
        assertEq(pool.loanOf(markets[0], provider_A), MIN_AMOUNT - 1);
        assertEq(pool.debtOf(markets[0], borrower_A), MIN_AMOUNT);
        assertEq(pool.balanceOf(borrower_A), MIN_AMOUNT);
    }
}
