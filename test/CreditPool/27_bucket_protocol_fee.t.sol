// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract Test_bucket_protocol_fee is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT * 40 / 100;
        params.provideOrderMinAmount = 1;
    }

    function _seed(uint256 firstAPR, uint256 secondAPR) private {
        _deposit(provider_A, 1000e18);
        _deposit(provider_B, 1000e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], firstAPR, 1000e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], secondAPR, 1000e18);
        _deposit_collateral(borrower_A, markets[0], 8000e18);
    }

    function test_whole_bucket_charges_each_lender_only_on_own_interest() public {
        _seed(0, APR_PERCENT);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 2000e18, 2010e18);

        // Interest = 0 / 10; fee = 0 / 4; net loan = 1000 / 1006.
        assertEq(pool.loanOf(markets[0], provider_A), 1000e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1006e18);
        assertEq(pool.loanOf(markets[0], address(this)), 4e18);
        assertEq(pool.balanceOf(borrower_A), 2000e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 2010e18);

        // Claim materializes the same distribution that loanOf reads lazily.
        _deposit(borrower_A, 10e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 2010e18);
        vm.warp(markets[0]);
        vm.prank(provider_A); pool.claim(provider_A, markets[0], type(uint128).max);
        vm.prank(provider_B); pool.claim(provider_B, markets[0], type(uint128).max);
        pool.claim(address(this), markets[0], type(uint128).max);
        assertEq(pool.balanceOf(provider_A), 1000e18);
        assertEq(pool.balanceOf(provider_B), 1006e18);
        assertEq(pool.balanceOf(address(this)), 4e18);
        (uint128 totalAssets, uint256 totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 0);
        assertEq(totalShares, 0);
    }

    function test_positive_aprs_use_individual_net_interest_weights() public {
        _seed(APR_PERCENT / 2, APR_PERCENT);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 2000e18, 2015e18);
        // Interest = 5 / 10; fee = 2 / 4; net loan = 1003 / 1006.
        assertEq(pool.loanOf(markets[0], provider_A), 1003e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1006e18);
        assertEq(pool.loanOf(markets[0], address(this)), 6e18);
    }

    function test_whole_bucket_matches_separate_tick_fills() public {
        _seed(0, APR_PERCENT);
        uint256 snapshot = vm.snapshotState();
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 2000e18, 2010e18);
        uint128 firstLoan = pool.loanOf(markets[0], provider_A);
        uint128 secondLoan = pool.loanOf(markets[0], provider_B);
        assertEq(vm.revertToState(snapshot), true);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1000e18, 1000e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1000e18, 1010e18);
        assertEq(pool.loanOf(markets[0], provider_A), firstLoan);
        assertEq(pool.loanOf(markets[0], provider_B), secondLoan);
        assertEq(pool.loanOf(markets[0], address(this)), 4e18);
    }

    function test_settlement_keeps_fee_used_before_global_fee_change() public {
        _seed(0, APR_PERCENT);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 2000e18, 2010e18);
        pool.setProtocolFee(UNIT * 90 / 100);
        assertEq(pool.loanOf(markets[0], provider_A), 1000e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1006e18);
        vm.prank(provider_B); pool.transferLoan(markets[0], provider_C, type(uint128).max);
        assertEq(pool.loanOf(markets[0], provider_C), 1006e18);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
    }
    function test_reloan_distributes_net_shares_without_minting_again() public {
        _deposit(provider_C, 2010e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 0, 2010e18);
        _deposit_collateral(borrower_B, markets[0], 8040e18);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], 2010e18, 2010e18);
        _seed(0, APR_PERCENT);

        vm.prank(provider_C); pool.reloan(provider_C, markets[0], 2010e18, 2000e18);
        assertEq(pool.balanceOf(provider_C), 2000e18);
        assertEq(pool.loanOf(markets[0], provider_C), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 1000e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1006e18);
        assertEq(pool.loanOf(markets[0], address(this)), 4e18);
        (uint128 totalAssets, uint256 totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 2010e18);
        assertEq(totalShares, 2010e18 * SCALE);
    }

    function test_sweep_preserves_zero_apr_principal_before_self_offset() public {
        _seed(0, APR_PERCENT);
        _deposit_collateral(provider_A, markets[0], 8000e18);
        vm.prank(provider_A); pool.placeBorrowOrder(provider_A, markets[0], 20 * APR_PERCENT, 2000e18);
        vm.prank(provider_A); pool.sweep(provider_A, markets[0], 2000e18, 2);

        // Zero APR means zero lender fee, including when sweep's borrow uses fee=0.
        // The settlement must remember the applied fee, which can differ from the market fee.
        assertEq(pool.loanOf(markets[0], provider_A), 1000e18);
        uint128 debt = pool.debtOf(markets[0], provider_A);
        vm.prank(provider_A); pool.offset(provider_A, markets[0], 1000e18);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.debtOf(markets[0], provider_A), debt - 1000e18);
    }

    function test_partial_tick_then_whole_bucket_and_next_generation() public {
        _seed(0, APR_PERCENT);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 500e18, 500e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1500e18, 1510e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1000e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1006e18);

        _seed(0, APR_PERCENT);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 2000e18, 2010e18);
        assertEq(pool.loanOf(markets[0], provider_A), 2000e18);
        assertEq(pool.loanOf(markets[0], provider_B), 2012e18);
        assertEq(pool.loanOf(markets[0], address(this)), 8e18);
    }

    function test_bucket_after_bad_debt_uses_current_share_price() public {
        _deposit(provider_C, 100e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 0, 100e18);
        _deposit_collateral(borrower_B, markets[0], 400e18);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], 100e18, 100e18);
        pool.badDebt(markets[0], 50e18);
        _seed(0, APR_PERCENT);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 2000e18, 2010e18);

        // A 50% write-down doubles the shares needed for each new loan asset.
        assertEq(pool.loanOf(markets[0], provider_C), 50e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1000e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1006e18);
        assertEq(pool.loanOf(markets[0], address(this)), 4e18);
        (uint128 totalAssets, uint256 totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 2060e18);
        assertEq(totalShares, 4120e18 * SCALE);
    }

    function test_equal_aprs_keep_proportional_lender_claims() public {
        _seed(APR_PERCENT, APR_PERCENT);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 2000e18, 2020e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1006e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1006e18);
        assertEq(pool.loanOf(markets[0], address(this)), 8e18);
    }

    function test_zero_fee_keeps_gross_weights() public {
        _set_fee_for_new_market(0);
        _seed(0, APR_PERCENT);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 2000e18, 2010e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1000e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1010e18);
        assertEq(pool.loanOf(markets[0], address(this)), 0);
    }

    function test_fee_near_one_preserves_small_net_interest() public {
        _set_fee_for_new_market(UNIT - 1);
        _seed(0, APR_PERCENT);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 2000e18, 2010e18);
        // 10 tokens of interest * 1e-18 retained = 10 wei, not zero.
        assertEq(pool.loanOf(markets[0], provider_A), 1000e18);
        assertEq(pool.loanOf(markets[0], provider_B), 1000e18 + 10);
        assertEq(pool.loanOf(markets[0], address(this)), 10e18 - 10);
    }

    function _set_fee_for_new_market(uint256 fee) private {
        pool.setProtocolFee(fee);
        vm.warp(markets[2]);
        markets[0] = markets[3];
        priceOracle.setPrice(1e18);
    }

    function test_fuzz_bucket_net_claims(uint128 assetsA, uint128 assetsB, uint16 tickA, uint16 tickB, uint256 fee, uint32 duration) public {
        assetsA = uint128(bound(assetsA, 1e8, 1e24));
        assetsB = uint128(bound(assetsB, 1e8, 1e24));
        tickA = uint16(bound(tickA, 0, 31));
        tickB = uint16(bound(tickB, 0, 31));
        fee = bound(fee, 0, UNIT - 1);
        duration = uint32(bound(duration, 1, YEAR));
        _set_fee_for_new_market(fee);
        vm.warp(markets[0] - duration);
        priceOracle.setPrice(1e18);
        _deposit(provider_A, assetsA);
        _deposit(provider_B, assetsB);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], tickA * APR_TICK_SPACING, assetsA);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], tickB * APR_TICK_SPACING, assetsB);
        _deposit_collateral(borrower_A, markets[0], (assetsA + assetsB) * 4);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], assetsA + assetsB, type(uint128).max);

        _assert_net_claim(provider_A, assetsA, tickA, fee, duration);
        _assert_net_claim(provider_B, assetsB, tickB, fee, duration);
        (uint128 totalAssets,) = pool.viewLoanPool(markets[0]);
        uint256 totalClaims = uint256(pool.loanOf(markets[0], provider_A))
            + pool.loanOf(markets[0], provider_B) + pool.loanOf(markets[0], address(this));
        // With a pristine share price the owner claim is exact; only two lender claims can leave dust.
        assertLe(totalClaims, totalAssets);
        assertLe(totalAssets - totalClaims, 2);
    }

    function _assert_net_claim(address lender, uint128 assets, uint16 tick, uint256 fee, uint32 duration) private {
        uint256 interest = uint256(assets) * tick * APR_TICK_SPACING * duration / (HUNDRED_PERCENT * YEAR);
        uint256 expected = assets + interest * (UNIT - fee) / UNIT;
        // The reference is below ideal by <2 wei; aggregate debt/fee rounding adds <2 wei.
        // Weight/share/index floors reduce claims by <2 wei at these sizes, so 4 wei covers both directions.
        uint128 preview = pool.loanOf(markets[0], lender);
        assertApproxEqAbs(preview, expected, 4);
        vm.prank(lender); pool.transferLoan(markets[0], provider_D, type(uint128).max);
        assertEq(pool.loanOf(markets[0], lender), 0);
        assertApproxEqAbs(pool.loanOf(markets[0], provider_D), preview, 1);
        // Move the materialized shares back so total conservation can be checked across both lenders.
        vm.prank(provider_D); pool.transferLoan(markets[0], lender, type(uint128).max);
    }

}
