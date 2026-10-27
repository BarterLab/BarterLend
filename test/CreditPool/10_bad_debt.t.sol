// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";
import { stdError } from "lib/forge-std/src/StdError.sol";

contract TestCreditPool_bad_debt_pending is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 300e18);
        _deposit(provider_C, 300e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 300e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[1], 10 * APR_PERCENT, 300e18);

        _borrow(markets[0], borrower_A, 200e18);
        _borrow(markets[1], borrower_B, 200e18);

        assertEq(pool.loanOf(markets[0], provider_A), 55e18);
        assertEq(pool.loanOf(markets[0], provider_B), 165e18);
        assertEq(pool.loanOf(markets[1], provider_C), 240e18);
    }

    function test_bad_debt_socializes_loss_across_pending_market_loans() public {
        (uint256 totalAssetsBefore, uint256 totalSharesBefore) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsBefore, 220e18);
        assertTrue(totalSharesBefore > 0);

        pool.badDebt(markets[0], 44e18);

        assertEq(pool.loanOf(markets[0], provider_A), 44e18);
        assertEq(pool.loanOf(markets[0], provider_B), 132e18);
        assertEq(pool.loanOf(markets[1], provider_C), 240e18);

        (uint256 totalAssetsAfter, uint256 totalSharesAfter) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsAfter, 220e18 - 44e18);
        assertEq(totalSharesAfter, totalSharesBefore);
    }

    function test_claim_before_bad_debt_socialization_shifts_loss_to_remaining_lenders() public {
        skip(YEAR); priceOracle.touch();

        vm.prank(borrower_A); asset.approve(address(pool), 200e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 200e18);

        vm.prank(provider_A); pool.claim(provider_A, markets[0], 55e18);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.balanceOf(provider_A), 55e18);

        priceOracle.setPrice(0.01e18);
        address liquidator = makeAddr("Liquidator");
        _mint(liquidator, 10e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 10e18, 0, type(uint256).max, "");

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 151.4e18);

        vm.prank(provider_B); pool.claim(provider_B, markets[0], type(uint128).max);

        assertEq(pool.balanceOf(provider_A), 55e18);
        assertEq(pool.balanceOf(provider_B), 151.4e18);
    }
}

contract TestCreditPool_bad_debt_mixed_sources is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _deposit_collateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        _provide(markets[0], provider_B, 100e18);
        _borrow(markets[0], borrower_B, 100e18);
    }

    function test_bad_debt_socializes_loss_across_realized_and_pending_loans() public {
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.loanOf(markets[0], provider_B), 110e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 110e18);

        pool.badDebt(markets[0], 22e18);

        assertEq(pool.loanOf(markets[0], provider_A), 99e18);
        assertEq(pool.loanOf(markets[0], provider_B), 99e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 110e18);
    }
}

contract TestCreditPool_bad_debt_zero_boundary is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        _borrow(markets[0], borrower_A, 100e18);
    }

    function test_bad_debt_cannot_write_down_last_asset() public {
        (uint256 totalAssetsBefore, uint256 totalSharesBefore) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsBefore, 100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 100e18);

        pool.badDebt(markets[0], 100e18 - 1);

        (uint256 totalAssetsAfterPartialWriteDown, uint256 totalSharesAfterPartialWriteDown) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsAfterPartialWriteDown, 1);
        assertEq(totalSharesAfterPartialWriteDown, totalSharesBefore);
        assertEq(pool.loanOf(markets[0], provider_A), 1);

        vm.expectRevert(stdError.assertionError);
        pool.badDebt(markets[0], 1);

        (uint256 totalAssetsAfterRevert, uint256 totalSharesAfterRevert) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsAfterRevert, 1);
        assertEq(totalSharesAfterRevert, totalSharesBefore);
        assertEq(pool.loanOf(markets[0], provider_A), 1);
    }

    function test_offset_can_empty_loan_pool_and_new_loans_start_fresh() public {
        vm.prank(provider_A); pool.transferLoan(markets[0], borrower_A, 100e18);
        vm.prank(borrower_A); pool.offset(borrower_A, markets[0], type(uint128).max);

        (uint256 totalAssetsAfterOffset, uint256 totalSharesAfterOffset) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsAfterOffset, 0);
        assertEq(totalSharesAfterOffset, 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 100e18);
        _borrow(markets[0], borrower_B, 100e18);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 100e18);

        (uint256 totalAssetsAfterRestart, uint256 totalSharesAfterRestart) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsAfterRestart, 100e18);
        assertEq(totalSharesAfterRestart, 100e18 * SCALE);
    }
}

contract TestCreditPool_bad_debt_early_lender_unfairness is CreditPoolTestSuite {
    // APR=0 for clean integer arithmetic: debt = principal, no interest multiplier
    function test_early_lender_absorbs_more_cumulative_bad_debt() public {
        // Provider A provides 120e18
        _deposit(provider_A, 120e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 120e18);
        _borrow(markets[0], borrower_A, 120e18);

        assertEq(pool.loanOf(markets[0], provider_A), 120e18);

        // 1st bad debt: A loses 50%
        pool.badDebt(markets[0], 60e18);

        assertEq(pool.loanOf(markets[0], provider_A), 60e18);

        // Provider B enters with the same 120e18 (buys shares at discounted pool price)
        _deposit(provider_B, 120e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 120e18);
        _borrow(markets[0], borrower_B, 120e18);

        assertEq(pool.loanOf(markets[0], provider_A), 60e18);
        assertEq(pool.loanOf(markets[0], provider_B), 120e18);

        // 2nd bad debt: proportional to current shares (A=1/3, B=2/3)
        pool.badDebt(markets[0], 60e18);

        // A: invested 120, remaining 40 → lost 80 (67%)
        // B: invested 120, remaining 80 → lost 40 (33%)
        // each event is pro-rata fair; cumulative gap is time-exposure risk, not a bug
        assertEq(pool.loanOf(markets[0], provider_A), 40e18);
        assertEq(pool.loanOf(markets[0], provider_B), 80e18);
    }
}

contract TestCreditPool_bad_debt_dust is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.provideOrderMinAmount = 1;
        params.borrowOrderMinAmount = 1;
        params.minDebtRemainingAfterLiquidation = 1;
    }

    function _set_degraded_loan_pool() internal {
        _deposit(provider_A, MIN_AMOUNT + 1);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, MIN_AMOUNT + 1);

        _deposit(provider_B, 1);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 1);

        _borrow(markets[0], borrower_A, MIN_AMOUNT + 2);

        priceOracle.setPriceFraction(((MIN_AMOUNT + 1) * 5 + 3) / 4, (MIN_AMOUNT + 2) * 4);
        _mint(provider_C, MIN_AMOUNT + 1);
        vm.prank(provider_C); pool.liquidate(markets[0], borrower_A, type(uint128).max, 0, type(uint256).max, "");

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), MIN_AMOUNT);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.getMarketBalance(markets[0]), MIN_AMOUNT + 1);
    }

    function test_claim_all_after_bad_debt_promotes_dust_to_remaining_lender() public {
        _set_degraded_loan_pool();

        skip(YEAR); priceOracle.touch();

        vm.prank(provider_A); pool.claim(provider_A, markets[0], type(uint128).max);

        (uint256 totalAssets, uint256 totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 1);
        assertEq(totalAssets, 1);
        assertEq(totalShares, SCALE);

        vm.prank(provider_B); pool.claim(provider_B, markets[0], type(uint128).max);

        (totalAssets, totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 0);
        assertEq(totalShares, 0);
        assertEq(pool.balanceOf(provider_A), MIN_AMOUNT);
        assertEq(pool.balanceOf(provider_B), 1);
    }

    function test_offset_all_after_bad_debt_burns_all_claimable_shares() public {
        _set_degraded_loan_pool();

        priceOracle.setPriceFraction(1e18, 1e18);

        _deposit(provider_C, MIN_AMOUNT);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 0, MIN_AMOUNT);

        _deposit_collateral(provider_A, markets[0], MIN_AMOUNT * 4);
        vm.prank(provider_A); pool.borrow(provider_A, markets[0], MIN_AMOUNT, type(uint128).max);

        vm.prank(provider_A); pool.offset(provider_A, markets[0], type(uint128).max);

        (uint256 totalAssets, uint256 totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(pool.debtOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_C), MIN_AMOUNT);
        assertEq(totalAssets, MIN_AMOUNT + 1);
        assertTrue(totalShares > 0);
        assertEq(totalAssets - pool.loanOf(markets[0], provider_C), 1);
    }

    function test_reloan_all_after_bad_debt_does_not_trap_remaining_claims() public {
        _set_degraded_loan_pool();

        _deposit(provider_C, MIN_AMOUNT);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 0, MIN_AMOUNT);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], type(uint128).max, MIN_AMOUNT);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.balanceOf(provider_A), MIN_AMOUNT);

        skip(YEAR); priceOracle.touch();

        vm.prank(provider_C); pool.claim(provider_C, markets[0], type(uint128).max);

        assertEq(pool.loanOf(markets[0], provider_B), 1);

        vm.prank(provider_B); pool.claim(provider_B, markets[0], type(uint128).max);

        (uint256 totalAssets, uint256 totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 0);
        assertEq(totalShares, 0);
        assertEq(pool.balanceOf(provider_B), 1);
        assertEq(pool.balanceOf(provider_C), MIN_AMOUNT);
    }

    function test_fuzz_claim_all_after_bad_debt_leaves_no_hidden_shares(
        uint8 providerAAmountRaw,
        uint8 providerBAmountRaw,
        uint8 badDebtRaw
    ) public {
        uint128 providerAAmount = uint128(bound(uint256(providerAAmountRaw), MIN_AMOUNT, MIN_AMOUNT + 20));
        uint128 providerBAmount = uint128(bound(uint256(providerBAmountRaw), 1, 20));
        uint128 totalBorrow = providerAAmount + providerBAmount;
        uint128 badDebtAmount = uint128(bound(uint256(badDebtRaw), 1, totalBorrow - 1));

        _deposit(provider_A, providerAAmount);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, providerAAmount);

        _deposit(provider_B, providerBAmount);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, providerBAmount);

        _borrow(markets[0], borrower_A, totalBorrow);

        priceOracle.setPriceFraction((uint256(totalBorrow - badDebtAmount) * 5 + 3) / 4, uint256(totalBorrow) * 4);
        _mint(provider_C, totalBorrow - badDebtAmount);
        vm.prank(provider_C); pool.liquidate(markets[0], borrower_A, type(uint128).max, 0, type(uint256).max, "");

        uint128 claimable = pool.loanOf(markets[0], provider_A);
        if (claimable == 0) return;

        skip(YEAR);
        priceOracle.touch();

        vm.prank(provider_A); pool.claim(provider_A, markets[0], type(uint128).max);

        (uint256 totalAssets,) = pool.viewLoanPool(markets[0]);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(totalAssets, pool.loanOf(markets[0], provider_B));
    }
}
