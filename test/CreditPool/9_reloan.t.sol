// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolTestSuite } from "./0_base.t.sol";

using Math for uint256;

contract TestCreditPool_reloan is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _borrow(markets[0], borrower_A, 100e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
    }

    function test_cant_reloan_when_no_other_providers() public {
        vm.expectRevert(abi.encodeWithSelector(BorrowDebtNotReached.selector, 50e18, 0));
        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 50e18, 50e18);
    }

    function test_cant_reloan_with_active_orders() public {
        _deposit(provider_A, 200e18);
        _deposit(provider_B, 200e18);
        _deposit(provider_C, 200e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 30e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 20 * APR_PERCENT, 30e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 30e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 20 * APR_PERCENT, 30e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 10 * APR_PERCENT, 30e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 20 * APR_PERCENT, 30e18);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 110e18, 0e18);
        assertEq(pool.loanOf(markets[0], provider_A), 0e18);
        assertEq_(pool.loanOf(markets[0], provider_B), 33e18 + 22e18);
        assertEq_(pool.loanOf(markets[0], provider_C), 33e18 + 22e18);

        assertApproxEqAbs(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 30e18, 1);
        assertApproxEqAbs(pool.getProvideOrderBalance(markets[0], 20 * APR_PERCENT, provider_A), 30e18, 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 20 * APR_PERCENT, provider_B), 11_666666666666666667); // 30 - 22 / 120%
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_C), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 20 * APR_PERCENT, provider_C), 11_666666666666666667); // 30 - 22 / 120%
    }

    function test_preview_reloan_skips_own_orders() public {
        _deposit(provider_A, 200e18);
        _deposit(provider_B, 200e18);
        _deposit(provider_C, 200e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 30e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 20 * APR_PERCENT, 30e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 30e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 20 * APR_PERCENT, 30e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 10 * APR_PERCENT, 30e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 20 * APR_PERCENT, 30e18);

        uint128 loanAmount = pool.loanOf(markets[0], provider_A);
        (uint128 loanConsumed, uint128 assetsReceived) = pool.previewReloan(markets[0], loanAmount, provider_A);

        assertEq(loanConsumed, 110e18);
        assertEq(assetsReceived, 96_666666666666666666);

        uint256 balanceBefore = pool.balanceOf(provider_A);
        vm.prank(provider_A); pool.reloan(provider_A, markets[0], loanConsumed, assetsReceived);

        assertEq(pool.balanceOf(provider_A), balanceBefore + assetsReceived);
    }

    function test_reloan_lower_percent() public {
        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 5 * APR_PERCENT, 100e18);

        vm.expectRevert(abi.encodeWithSelector(BorrowAssetsNotReached.selector, 52.5e18, 50e18));
        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 52.5e18, 52.5e18);

        (uint128 loanConsumed, uint128 assetsReceived) = pool.previewReloan(markets[0], 52.5e18, provider_A);
        assertEq(loanConsumed, 52.5e18);
        assertEq(assetsReceived, 50e18); // 52.5 / 105%

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], loanConsumed, assetsReceived);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18 - loanConsumed);
        assertEq(pool.balanceOf(provider_A), assetsReceived);
        assertEq(pool.loanOf(markets[0], provider_B), loanConsumed);
        assertEq(pool.getProvideOrderBalance(markets[0], 5 * APR_PERCENT, provider_B), 100e18 - assetsReceived);
    }

    function test_reloan_greater_percent() public {
        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 20 * APR_PERCENT, 100e18);

        (uint128 loanConsumed, uint128 assetsReceived) = pool.previewReloan(markets[0], 60e18, provider_A);
        assertEq(loanConsumed, 60e18);
        assertEq(assetsReceived, 50e18); // 60 / 120%

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], loanConsumed, assetsReceived);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18 - loanConsumed);
        assertEq(pool.balanceOf(provider_A), assetsReceived);
        assertEq(pool.loanOf(markets[0], provider_B), loanConsumed);
        assertEq(pool.getProvideOrderBalance(markets[0], 20 * APR_PERCENT, provider_B), 100e18 - assetsReceived);
    }

    function test_reloan_reconciles_active_reloan_order_to_remaining_loan() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 100e18);

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 20 * APR_PERCENT, 100e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 100e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 100e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 1);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ReloanOrderCancelled(provider_A, markets[0], 0, 50e18, true);
        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 60e18, 50e18);

        assertEq(pool.loanOf(markets[0], provider_A), 50e18);
        assertEq(pool.balanceOf(provider_A), 50e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 50e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].amount, 50e18);
        assertEq(pool.getBorrowOrderbook(markets[0])[0].count, 1);
    }

    function test_reloan_greater_percent_and_half_year_skip() public {
        skip(YEAR / 2);

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 20 * APR_PERCENT, 100e18);

        (uint128 loanConsumed, uint128 assetsReceived) = pool.previewReloan(markets[0], 60e18, provider_A);
        assertEq(loanConsumed, 60e18);
        assertEq(assetsReceived, 54545454545454545454); // floor(60 / (100% + 20% * 0.5))

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], loanConsumed, assetsReceived);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18 - loanConsumed);
        assertEq(pool.balanceOf(provider_A), assetsReceived);
        assertEq(pool.loanOf(markets[0], provider_B), loanConsumed);
        assertEq(pool.getProvideOrderBalance(markets[0], 20 * APR_PERCENT, provider_B), 100e18 - assetsReceived);
    }

}

contract TestCreditPool_reloan_equivalence is CreditPoolTestSuite {
    struct ReloanPair {
        uint128 loanConsumed;
        uint128 assetsReceived;
    }

    function reconfigure(InitializationParams memory params) internal pure override {
        params.provideOrderMinAmount = 1;
        params.borrowOrderMinAmount = 1;
    }

    function _executeReloanScenario(uint256 APR, uint128 tickLiquidity, uint128 requestedLoan)
        internal
        returns (ReloanPair memory pair)
    {
        _deposit(provider_B, tickLiquidity);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], APR, tickLiquidity);

        (pair.loanConsumed, pair.assetsReceived) = pool.previewReloan(markets[0], requestedLoan, provider_A);

        assertGt(pair.loanConsumed, 0, "reloan loanConsumed");
        assertGt(pair.assetsReceived, 0, "reloan assetsReceived");

        uint128 providerALoanBefore = pool.loanOf(markets[0], provider_A);
        uint256 providerAAssetBefore = pool.balanceOf(provider_A);
        uint128 providerBLoanBefore = pool.loanOf(markets[0], provider_B);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], pair.loanConsumed, pair.assetsReceived);

        assertEq(pool.loanOf(markets[0], provider_A), providerALoanBefore - pair.loanConsumed, "reloan provider A loan");
        assertEq(pool.balanceOf(provider_A), providerAAssetBefore + pair.assetsReceived, "reloan provider A assets");
        assertEq_(pool.loanOf(markets[0], provider_B), providerBLoanBefore + pair.loanConsumed);
        assertEq(pool.getProvideOrderBalance(markets[0], APR, provider_B), tickLiquidity - pair.assetsReceived, "reloan remaining porder");
    }

    function _executeProvideAgainstReloanScenario(uint256 APR, ReloanPair memory pair) internal {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], APR, pair.loanConsumed);

        (uint128 provideCollectedLoan, uint128 provideConsumedAssets,) =
            pool.previewProvideExactOut(markets[0], pair.assetsReceived, pair.loanConsumed, 10, provider_C);

        assertEq(provideCollectedLoan, pair.loanConsumed, "provide preview loan");
        assertEq(provideConsumedAssets, pair.assetsReceived, "provide preview assets");

        uint128 providerALoanBeforeProvide = pool.loanOf(markets[0], provider_A);
        uint128 providerAInternalAssetsBefore = pool.balanceOf(provider_A);
        uint128 providerCLoanBefore = pool.loanOf(markets[0], provider_C);

        _deposit(provider_C, pair.assetsReceived);
        vm.prank(provider_C); pool.provideExactOut(provider_C, markets[0], pair.assetsReceived, pair.loanConsumed, 10);

        assertEq(pool.loanOf(markets[0], provider_A), providerALoanBeforeProvide - pair.loanConsumed, "provide provider A loan");
        assertEq(pool.balanceOf(provider_A), providerAInternalAssetsBefore + pair.assetsReceived, "provide provider A assets");
        assertEq(pool.loanOf(markets[0], provider_C), providerCLoanBefore + pair.loanConsumed, "provide provider C loan");
        assertEq(pool.getBorrowOrderBalance(markets[0], APR, provider_A), 0, "provide remaining border");
    }

    function test_fuzz_provide_reloan_order_matches_reloan_math(
        uint16 rawAPRTick,
        uint128 rawTickLiquidity,
        uint128 rawRequestedLoan
    ) public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        _borrow(markets[0], borrower_A, 100e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);

        uint256 APR = bound(uint256(rawAPRTick), 0, MAX_APR / APR_TICK_SPACING) * APR_TICK_SPACING;
        uint128 tickLiquidity = uint128(bound(uint256(rawTickLiquidity), MIN_AMOUNT, 200e18));
        uint128 requestedLoan = uint128(bound(uint256(rawRequestedLoan), MIN_AMOUNT, pool.loanOf(markets[0], provider_A)));

        uint256 previewSnapshot = vm.snapshotState();
        _deposit(provider_B, tickLiquidity);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], APR, tickLiquidity);

        (uint128 previewLoanConsumed, uint128 previewAssetsReceived) = pool.previewReloan(markets[0], requestedLoan, provider_A);
        vm.assume(previewLoanConsumed >= MIN_AMOUNT);
        vm.assume(previewAssetsReceived >= MIN_AMOUNT);
        assertTrue(vm.revertToState(previewSnapshot));

        uint256 snapshot = vm.snapshotState();

        ReloanPair memory pair = _executeReloanScenario(APR, tickLiquidity, requestedLoan);

        assertTrue(vm.revertToState(snapshot));

        _executeProvideAgainstReloanScenario(APR, pair);
    }
}

contract TestCreditPool_reloan2 is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT * 10 / 100; // 10%
    }

    function test_reloan_credits_protocol_fee_as_owner_loan() public {
        _deposit(provider_A, 110e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 110e18);
        _borrow(markets[0], borrower_A, 110e18);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 100e18);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 110e18, 100e18);

        assertEq(pool.balanceOf(provider_A), 100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 109e18);
        assertEq(pool.loanOf(markets[0], address(this)), 1e18);
    }
}

contract TestCreditPool_reloan_dust is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        _borrow(markets[0], borrower_A, 100e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);

        _deposit(provider_B, 1e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], APR_TICK_SPACING, 1e18);

        _mint_collateral(borrower_B, 4e18);
        vm.prank(borrower_B); pool.depositCollateral(borrower_B, markets[0], 4e18);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], 1e18 - 1, type(uint128).max);

        assertEq(pool.getProvideOrderBalance(markets[0], APR_TICK_SPACING, provider_B), 1);

        _deposit(provider_C, 200e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 10 * APR_PERCENT, 200e18);
    }

    function test_preview_reloan_handles_positive_apr_dust_tick() public view {
        (uint128 loanConsumed, uint128 assetsReceived) = pool.previewReloan(markets[0], 110e18, provider_A);

        assertEq(loanConsumed, 110e18);
        assertEq(assetsReceived, 100e18 - 1);
        assertEq(pool.getProvideOrderBalance(markets[0], APR_TICK_SPACING, provider_B), 1);
    }

    function test_reloan_handles_positive_apr_dust_tick() public {
        uint256 provider_B_loan_before = pool.loanOf(markets[0], provider_B);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 110e18, 100e18 - 1);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.balanceOf(provider_A), 100e18 - 1);
        assertEq(pool.getProvideOrderBalance(markets[0], APR_TICK_SPACING, provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_B), provider_B_loan_before + 2);
        assertEq(pool.loanOf(markets[0], provider_C), 110e18 - 2);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_C), 100e18 + 2);
    }
}

contract TestCreditPool_offset is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 200e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 200e18);

        _deposit(provider_B, 200e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 200e18);

        _deposit_collateral(borrower_A, markets[0], 300e18);
        _deposit_collateral(borrower_B, markets[0], 300e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 50e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 10 * APR_PERCENT, 60e18);
    }

    function test_cant_offset_more_than_loan_or_debt() public {
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.debtOf(markets[0], provider_A), 0);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 110e18, 1, 0));
        vm.prank(provider_A); pool.offset(provider_A, markets[0], 110e18);

        _borrow(markets[0], borrower_A, 200e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.debtOf(markets[0], provider_A), 0);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 110e18, 1, 0));
        vm.prank(provider_A); pool.offset(provider_A, markets[0], 110e18);

        _borrow(markets[0], provider_A, 50e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.debtOf(markets[0], provider_A), 55e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit DebtOffsetWithLoan(provider_A, markets[0], 55e18);
        vm.prank(provider_A); pool.offset(provider_A, markets[0], type(uint128).max);

        assertEq(pool.loanOf(markets[0], provider_A), 55e18);
        assertEq(pool.debtOf(markets[0], provider_A), 0);
    }

    function test_repay_via_provide_and_offset() public {
        _borrow(markets[0], borrower_A, 100e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.loanOf(markets[0], borrower_A), 0);

        skip(YEAR / 2); priceOracle.touch();

        _deposit(borrower_A, 5e18);
        assertEq(pool.balanceOf(borrower_A), 105e18);
        vm.prank(borrower_A); asset.approve(address(pool), 105e18);
        vm.prank(borrower_A); pool.provideExactOut(borrower_A, markets[0], 105e18, 110e18, 10);

        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.loanOf(markets[0], borrower_A), 110e18);

        vm.prank(borrower_A); pool.offset(borrower_A, markets[0], 110e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], borrower_A), 0);
    }
}

contract TestCreditPool_preview_reloan_bad_debt_dust is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.provideOrderMinAmount = 1;
        params.borrowOrderMinAmount = 1;
    }

    function test_preview_reloan_matches_execution_after_bad_debt_dust() public {
        _deposit(provider_A, MIN_AMOUNT + 1);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, MIN_AMOUNT + 1);

        _deposit(provider_B, 1);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 1);

        _borrow(markets[0], borrower_A, MIN_AMOUNT + 2);

        assertEq(pool.loanOf(markets[0], provider_A), MIN_AMOUNT + 1);
        assertEq(pool.loanOf(markets[0], provider_B), 1);

        pool.badDebt(markets[0], 1);

        assertEq(pool.loanOf(markets[0], provider_A), MIN_AMOUNT);
        assertEq(pool.loanOf(markets[0], provider_B), 0);

        _deposit(provider_C, MIN_AMOUNT);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 0, MIN_AMOUNT);

        uint128 loanAmount = pool.loanOf(markets[0], provider_A);
        (uint128 loanConsumed, uint128 assetsReceived) = pool.previewReloan(markets[0], loanAmount, provider_A);

        assertEq(loanAmount, MIN_AMOUNT);
        assertEq(loanConsumed, MIN_AMOUNT);
        assertEq(assetsReceived, MIN_AMOUNT);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], loanConsumed, assetsReceived);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.balanceOf(provider_A), MIN_AMOUNT);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_C), MIN_AMOUNT);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_C), 0);
    }
}
