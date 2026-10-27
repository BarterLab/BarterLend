// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_protocol_fee is CreditPoolTestSuite {
    address internal feeOwner = makeAddr("Fee Owner");

    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT * 40 / 100;
    }

    function _owner() internal view override returns (address) {
        return feeOwner;
    }

    function test_borrow() public {
        _deposit(provider_A, 1000e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 1000e18);
        _deposit_collateral(borrower_A, markets[0], 4000e18);

        (uint128 borrowed, uint128 debt) = pool.previewBorrow(markets[0], 1000e18, borrower_A);
        assertEq(borrowed, 1000e18);
        assertEq(debt, 1100e18);

        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1000e18, 1100e18);

        // interest = 1100 - 1000 = 100; fee = 100 * 40% = 40
        assertEq(pool.balanceOf(borrower_A), 1000e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 1100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1060e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 40e18);
    }

    function test_provide_exact_in() public {
        _deposit_collateral(borrower_A, markets[0], 4000e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 1000e18);
        _deposit(provider_A, 1000e18);

        (uint128 previewLoan, uint128 previewAssets,) =
            pool.previewProvideExactIn(markets[0], 1000e18, 1060e18, 1, provider_A);
        assertEq(previewLoan, 1060e18);
        assertEq(previewAssets, 1000e18);

        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 1000e18, 1060e18, 1);

        // gross loan = 1000 * 110% = 1100; fee = 100 * 40% = 40
        assertEq(pool.balanceOf(provider_A), 0);
        assertEq(pool.balanceOf(borrower_A), 1000e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 1100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1060e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 40e18);
    }

    function test_provide_exact_out() public {
        _deposit_collateral(borrower_A, markets[0], 4000e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 1000e18);
        _deposit(provider_A, 1000e18);

        (uint128 previewLoan, uint128 previewAssets,) =
            pool.previewProvideExactOut(markets[0], 1000e18, 530e18, 1, provider_A);
        assertEq(previewLoan, 530e18);
        assertEq(previewAssets, 500e18);

        vm.prank(provider_A); pool.provideExactOut(provider_A, markets[0], 1000e18, 530e18, 1);

        // requested net loan = 530; gross loan = 550; principal = 500; fee = 50 * 40% = 20
        assertEq(pool.balanceOf(provider_A), 500e18);
        assertEq(pool.balanceOf(borrower_A), 500e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 550e18);
        assertEq(pool.loanOf(markets[0], provider_A), 530e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 20e18);
    }

    function test_reloan() public {
        _deposit(provider_A, 1100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 1100e18);
        _deposit_collateral(borrower_A, markets[0], 4400e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1100e18, 1100e18);

        _deposit(provider_B, 1000e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 1000e18);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 1100e18, 1000e18);

        // seller receives principal = 1000; new loan = 1100; fee = 100 * 40% = 40
        assertEq(pool.balanceOf(provider_A), 1000e18);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 1060e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 40e18);
    }

    function test_sweep() public {
        _deposit(provider_A, 106e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 5 * APR_PERCENT, 106e18);
        _deposit_collateral(borrower_A, markets[0], 420e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 6 * APR_PERCENT, 105e18);

        _deposit_collateral(borrower_B, markets[0], 4e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 5 * APR_PERCENT, 1e18);

        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 106e18, 2);

        // D = 106*1.05 = 111.3; X0 = D/1.06 = 105; S = 1; first-leg fee = 5.3*40% = 2.12.
        // v = floor(0.4*111.3/(0.6*106+0.4*111.3), 18 decimals) = 0.411764705882352941.
        // N = ceil(S*v, wei); K = floor(N*1.05/(1+0.05*(1-v)), wei) = 0.419999999999999999.
        // Y = ceil(K/1.05, wei) = 0.4; reward = 1-Y = 0.6.
        // Lender loan = 111.3-2.12 = 109.18; owner loan = 2.12+K = 2.539999999999999999.
        assertEq(pool.balanceOf(provider_C), 0.6e18);
        assertEq(pool.balanceOf(feeOwner), 0);
        assertEq(pool.balanceOf(borrower_A), 105e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 111.3e18);
        assertEq(pool.loanOf(markets[0], provider_A), 109.18e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 2.539999999999999999e18);
    }

    function test_protocol_fee_is_calculated_only_from_interest() public {
        assertEq(pool.protocolFeeAssets(100e18, 110e18, UNIT * 40 / 100), 4e18);
    }

    function test_protocol_fee_rounds_down() public {
        assertEq(pool.protocolFeeAssets(1000, 1001, UNIT / 2), 0);
    }

    function test_protocol_fee_share_split_preserves_gross_shares() public {
        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        _deposit(provider_A, 100e18);

        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 100e18, 106e18, 1);

        (uint128 totalAssets, uint256 totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 110e18);
        assertEq(totalShares, 110e18 * SCALE);
        assertEq(pool.loanOf(markets[0], provider_A), 106e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 4e18);
    }

    function test_gross_loan_for_exact_net_loan() public {
        uint128 grossLoan = pool.grossLoanForNetLoan(
            106e18,
            10 * APR_PERCENT,
            YEAR,
            UNIT * 40 / 100,
            type(uint128).max
        );

        assertEq(grossLoan, 110e18);
    }

    function test_gross_loan_inverse_caps_overflowing_upper_bound() public {
        uint128 grossLoan = pool.grossLoanForNetLoan(
            283568639100782052886145506193140176213,
            MAX_APR,
            YEAR,
            UNIT,
            type(uint128).max
        );

        assertEq(grossLoan, type(uint128).max);
    }

    function test_gross_loan_rounds_fee_in_protocol_favor_by_one_wei() public view {
        uint128 grossLoan = pool.grossLoanForNetLoan(
            2041, 10 * APR_PERCENT, YEAR, UNIT * 40 / 100, type(uint128).max
        );

        assertEq(grossLoan, 2118);
        // Principal = ceil(2118 / 1.1) = 1926; floor(192 * 40%) = 76.
        assertEq(grossLoan - 2041, 77);
    }

    function test_fuzz_gross_loan_for_exact_net_loan(
        uint128 rawNetLoan,
        uint256 rawAPR,
        uint256 rawDuration,
        uint256 rawProtocolFee
    ) public view {
        uint128 netLoan = uint128(bound(uint256(rawNetLoan), 1, 1e30));
        uint256 APR = bound(rawAPR, 0, MAX_APR);
        uint256 duration = bound(rawDuration, 1, 10 * YEAR);
        uint256 protocolFee = bound(rawProtocolFee, 0, UNIT);

        uint128 grossLoan = pool.grossLoanForNetLoan(
            netLoan,
            APR,
            duration,
            protocolFee,
            type(uint128).max
        );

        uint256 denominator = HUNDRED_PERCENT * YEAR;
        uint256 factor = denominator + APR * duration;
        uint256 principal = (uint256(grossLoan) * denominator + factor - 1) / factor;
        uint256 feeAssets = grossLoan - netLoan;
        assertEq(feeAssets <= grossLoan - principal, true);
        uint256 roundedFee = (uint256(grossLoan) - principal) * protocolFee / UNIT;
        assertGe(feeAssets, roundedFee);
        assertLe(feeAssets - roundedFee, 1);
    }

    function test_borrow_credits_aggregate_owner_fee_across_ticks() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 5 * APR_PERCENT, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 100e18);
        _deposit_collateral(borrower_A, markets[0], 800e18);

        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 200e18, 215e18);

        assertEq(pool.balanceOf(borrower_A), 200e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 215e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 6e18);
    }

    function test_bad_debt_reduces_lender_and_owner_loan_proportionally() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 110e18);

        assertEq(pool.loanOf(markets[0], provider_A), 106e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 4e18);

        pool.badDebt(markets[0], 55e18);

        assertEq(pool.loanOf(markets[0], provider_A), 53e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 2e18);
    }

    function test_provide_exact_out_uses_inverse_only_for_final_partial_order() public {
        _deposit_collateral(borrower_A, markets[0], 200e18);
        _deposit_collateral(borrower_B, markets[0], 400e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 50e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 5 * APR_PERCENT, 100e18);
        _deposit(provider_A, 75e18);

        (uint128 previewLoan, uint128 previewConsumedAssets,) =
            pool.previewProvideExactOut(markets[0], 75e18, 78.75e18, 10, provider_A);

        assertEq(previewLoan, 78.75e18);
        assertEq(previewConsumedAssets, 75e18);

        vm.prank(provider_A); pool.provideExactOut(provider_A, markets[0], 75e18, 78.75e18, 10);

        assertEq(pool.loanOf(markets[0], provider_A), 78.75e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 2.5e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 55e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 26.25e18);
    }

    function test_provide_against_reloan_order_has_same_fee_split() public {
        _deposit(provider_A, 110e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 110e18);
        _deposit_collateral(borrower_A, markets[0], 440e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 110e18, 110e18);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 110e18);

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 106e18, 10);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.balanceOf(provider_A), 100e18);
        assertEq(pool.loanOf(markets[0], provider_B), 106e18);
        assertEq(pool.loanOf(markets[0], feeOwner), 4e18);
    }
}

contract TestCreditPool_protocol_fee_exact_out_bounds is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT * 90 / 100;
        params.provideOrderMinAmount = 1;
        params.borrowOrderMinAmount = 1;
        params.marketsConfig.durations = [10 * YEAR, 10 * YEAR, 10 * YEAR];
    }

    function test_exact_out_rounding_does_not_exceed_available_reloan() public {
        _deposit(provider_A, 10009);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 10009);
        _deposit_collateral(borrower_A, markets[0], 40036);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 10009, 10009);
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 20 * APR_PERCENT, 10009);
        _deposit(provider_B, 3337);

        (uint128 previewLoan, uint128 previewAssets,) =
            pool.previewProvideExactOut(markets[0], 3337, 4004, 1, provider_B);

        assertEq(previewLoan, 4004);
        assertEq(previewAssets, 3337);

        vm.prank(provider_B); pool.provideExactOut(provider_B, markets[0], 3337, 4004, 1);

        assertEq(pool.balanceOf(provider_B), 0);
        assertEq(pool.balanceOf(provider_A), 3337);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 4004);
        assertEq(pool.loanOf(markets[0], address(this)), 6005);
        assertEq(pool.debtOf(markets[0], borrower_A), 10009);
    }
}
