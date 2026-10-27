// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_preview_provide_reloan is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT / 5;
    }

    function beforeEach() public override {
        _deposit(provider_A, 2e18);
        _deposit(provider_B, 2e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 2e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 2e18);
        _borrow(markets[0], borrower_A, 4e18);
    }

    function _place_reloan_orders(uint256 firstAPR, uint256 secondAPR) internal {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], firstAPR, 2e18);
        vm.prank(provider_B); pool.placeReloanOrder(provider_B, markets[0], secondAPR, 2e18);
        pool.badDebt(markets[0], 1);
        _deposit(provider_C, 4e18 - 1);
    }

    function test_exact_in_matches_execution_after_sequential_reloan_burns() public {
        _place_reloan_orders(0, 0);
        assertEq(pool.loanOf(markets[0], provider_A), 2e18 - 1);
        assertEq(pool.loanOf(markets[0], provider_B), 2e18 - 1);

        (uint128 loan, uint128 consumed, uint16 crossed) =
            pool.previewProvideExactIn(markets[0], 4e18 - 1, 0, 2, provider_C);
        assertEq(loan, 4e18 - 1);
        assertEq(consumed, 4e18 - 1);
        assertEq(crossed, 2);

        vm.prank(provider_C); pool.provideExactIn(provider_C, markets[0], 4e18 - 1, 0, 2);
        assertEq(pool.balanceOf(provider_A), 2e18 - 1);
        assertEq(pool.balanceOf(provider_B), 2e18);
        assertEq(pool.balanceOf(provider_C), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_C), 4e18 - 1);
    }

    function test_exact_out_reaches_target_after_sequential_reloan_burns() public {
        _place_reloan_orders(0, 0);

        (uint128 loan, uint128 consumed, uint16 crossed) =
            pool.previewProvideExactOut(markets[0], 4e18 - 1, 4e18 - 1, 2, provider_C);
        assertEq(loan, 4e18 - 1);
        assertEq(consumed, 4e18 - 1);
        assertEq(crossed, 2);

        vm.prank(provider_C); pool.provideExactOut(provider_C, markets[0], 4e18 - 1, 4e18 - 1, 2);
        assertEq(pool.balanceOf(provider_C), 0);
        assertEq(pool.loanOf(markets[0], provider_C), 4e18 - 1);
    }

    function test_exact_in_partial_fill_keeps_remaining_seller_loan() public {
        _place_reloan_orders(0, 0);

        (uint128 loan, uint128 consumed, uint16 crossed) =
            pool.previewProvideExactIn(markets[0], 3e18 - 1, 0, 2, provider_C);
        assertEq(loan, 3e18 - 1);
        assertEq(consumed, 3e18 - 1);
        assertEq(crossed, 2);

        vm.prank(provider_C); pool.provideExactIn(provider_C, markets[0], 3e18 - 1, 0, 2);
        assertEq(pool.loanOf(markets[0], provider_B), 1e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_B), 1e18);
        assertEq(pool.loanOf(markets[0], provider_C), 3e18 - 1);

        _provide(markets[0], provider_D, 1e18);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_D), 1e18);
    }

    function test_exact_out_partial_fill_stops_at_target() public {
        _place_reloan_orders(0, 0);

        (uint128 loan, uint128 consumed, uint16 crossed) =
            pool.previewProvideExactOut(markets[0], 4e18 - 1, 3e18 - 1, 2, provider_C);
        assertEq(loan, 3e18 - 1);
        assertEq(consumed, 3e18 - 1);
        assertEq(crossed, 2);

        vm.prank(provider_C); pool.provideExactOut(provider_C, markets[0], 4e18 - 1, 3e18 - 1, 2);
        assertEq(pool.balanceOf(provider_C), 1e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1e18);
        assertEq(pool.loanOf(markets[0], provider_C), 3e18 - 1);
    }

    function test_partial_claim_burn_is_used_for_next_reloan() public {
        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 1e18);
        vm.prank(provider_B); pool.placeReloanOrder(provider_B, markets[0], 0, 2e18);
        pool.badDebt(markets[0], 1);
        _deposit(provider_C, 3e18 - 1);

        (uint128 loan, uint128 consumed, uint16 crossed) =
            pool.previewProvideExactIn(markets[0], 3e18 - 1, 0, 2, provider_C);
        assertEq(loan, 3e18 - 1);
        assertEq(consumed, 3e18 - 1);
        assertEq(crossed, 2);

        vm.prank(provider_C); pool.provideExactIn(provider_C, markets[0], 3e18 - 1, 0, 2);
        assertEq(pool.balanceOf(provider_A), 1e18);
        assertEq(pool.balanceOf(provider_B), 2e18 - 1);
        assertEq(pool.loanOf(markets[0], provider_A), 1e18 - 1);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_C), 3e18 - 1);
    }

    function test_reloan_burns_carry_across_aprs_with_protocol_fee() public {
        _place_reloan_orders(20 * APR_PERCENT, 0);

        (uint128 loan, uint128 consumed, uint16 crossed) =
            pool.previewProvideExactOut(markets[0], 4e18 - 1, 3_933_333_333_333_333_333, 2, provider_C);
        assertEq(loan, 3_933_333_333_333_333_333);
        assertEq(consumed, 3_666_666_666_666_666_666);
        assertEq(crossed, 2);

        vm.prank(provider_C); pool.provideExactOut(provider_C, markets[0], 4e18 - 1, 3_933_333_333_333_333_333, 2);
        assertEq(pool.balanceOf(provider_A), 1_666_666_666_666_666_666);
        assertEq(pool.balanceOf(provider_B), 2e18);
        assertEq(pool.balanceOf(provider_C), 333_333_333_333_333_333);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_C), 3_933_333_333_333_333_333);
        assertEq(pool.loanOf(markets[0], address(this)), 66_666_666_666_666_666);
    }

    function test_borrow_fill_after_reloans_keeps_final_pool_totals() public {
        _place_reloan_orders(0, 0);
        _deposit_collateral(borrower_B, markets[0], 4e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 0, 1e18);
        _deposit(provider_C, 1e18);

        (uint128 loan, uint128 consumed, uint16 crossed) =
            pool.previewProvideExactIn(markets[0], 5e18 - 1, 0, 3, provider_C);
        assertEq(loan, 5e18 - 1);
        assertEq(consumed, 5e18 - 1);
        assertEq(crossed, 3);

        vm.prank(provider_C); pool.provideExactIn(provider_C, markets[0], 5e18 - 1, 0, 3);
        assertEq(pool.balanceOf(provider_C), 0);
        assertEq(pool.loanOf(markets[0], provider_C), 5e18 - 1);
        assertEq(pool.debtOf(markets[0], borrower_B), 1e18);
        (uint128 totalAssets,) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 5e18 - 1);
    }

    function test_skipping_own_reloan_does_not_burn_its_shares() public {
        _place_reloan_orders(0, 0);
        _deposit(provider_A, 2e18);

        (uint128 loan, uint128 consumed, uint16 crossed) =
            pool.previewProvideExactIn(markets[0], 2e18, 0, 2, provider_A);
        assertEq(loan, 2e18 - 1);
        assertEq(consumed, 2e18 - 1);
        assertEq(crossed, 2);

        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 2e18 - 1, 0, 2);
        assertEq(pool.balanceOf(provider_A), 1);
        assertEq(pool.loanOf(markets[0], provider_A), 4e18 - 1);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 2e18);
    }

    function test_crossed_order_limit_stops_before_second_reloan() public {
        _place_reloan_orders(0, 0);

        (uint128 loan, uint128 consumed, uint16 crossed) =
            pool.previewProvideExactOut(markets[0], 4e18 - 1, 4e18 - 1, 1, provider_C);
        assertEq(loan, 2e18 - 1);
        assertEq(consumed, 2e18 - 1);
        assertEq(crossed, 1);

        vm.expectRevert(abi.encodeWithSelector(ProvideMaxCrossedOrdersExceeded.selector, 2, 1));
        vm.prank(provider_C); pool.provideExactOut(provider_C, markets[0], 4e18 - 1, 4e18 - 1, 1);
    }

    function test_fuzz_sequential_reloan_burns_match_after_loss(uint64 rawLoss, bool exactOut) public {
        _place_reloan_orders(0, 0);
        uint128 loss = uint128(bound(rawLoss, 1, 1e18));
        if (loss > 1) pool.badDebt(markets[0], loss - 1);
        uint128 amount = 4e18 - loss;

        (uint128 loan, uint128 consumed, uint16 crossed) = exactOut
            ? pool.previewProvideExactOut(markets[0], amount, amount, 2, provider_C)
            : pool.previewProvideExactIn(markets[0], amount, 0, 2, provider_C);
        assertEq(loan, amount);
        assertEq(consumed, amount);
        assertEq(crossed, 2);

        if (exactOut) {
            vm.prank(provider_C); pool.provideExactOut(provider_C, markets[0], amount, amount, 2);
        } else {
            vm.prank(provider_C); pool.provideExactIn(provider_C, markets[0], amount, 0, 2);
        }
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_C), amount);
        assertEq(pool.balanceOf(provider_C), loss - 1);
    }
}
