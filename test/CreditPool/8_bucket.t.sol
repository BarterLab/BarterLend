// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_bucket is CreditPoolTestSuite {
    function test_zeroed_bucket_recovers_with_untouched_tick() public {
        uint64 market = markets[0];
        uint256 apr = APR_TICK_SPACING;
        uint256 nextBucketApr = TICKS_PER_BUCKET * APR_TICK_SPACING;

        pool.setProvideOrderMinAmount(1);
        _deposit(provider_A, 1);
        _deposit(provider_B, 1e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, market, apr, 1);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, nextBucketApr, 1e18);

        aaveToken.rebase(address(pool), -0.5e18);
        _deposit_collateral(borrower_A, market, 1e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, market, 2000, type(uint128).max);

        assertEq(pool.viewProvideLiquidityForBucket(market, 0), 0);
        assertEq(pool.viewProvideLiquidityForTick(market, apr), 0);

        aaveToken.rebase(address(pool), 0.5e18);

        assertEq(pool.viewProvideLiquidityForTick(market, apr), 1);
        assertEq(pool.getProvideOrderBalance(market, apr, provider_A), 1);

        (uint128 available,) = pool.previewBorrow(market, 2000, provider_A);
        assertEq(available, 2000);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, market, apr, type(uint128).max);
        assertEq(pool.viewProvideLiquidityForBucket(market, 0), 0);
    }

    function test_bucket_matches_lone_tick_after_staggered_loss_syncs() public {
        uint64 market = markets[0];
        uint256 apr = 10 * APR_PERCENT;
        uint256 otherApr = apr + APR_TICK_SPACING;
        uint256 bucketId = pool.bucketIdForAPR(apr);

        _deposit(provider_A, 100e18);
        _deposit(provider_B, 1e18);
        _deposit(provider_C, 73e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, market, apr, 100e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[1], apr, 73e18);

        for (uint256 i = 0; i < 10; i++) {
            aaveToken.rebase(address(pool), -0.1e18);
            vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, otherApr, 1e18);
            vm.prank(provider_B); pool.cancelProvideOrder(provider_B, market, otherApr, 1e18);
        }

        assertEq(pool.viewProvideLiquidityForBucket(market, bucketId), pool.viewProvideLiquidityForTick(market, apr));

        (uint128 available, uint128 debt) = pool.previewBorrow(market, 10e18, provider_A);
        assertEq(available, 0);
        assertEq(debt, 0);

        uint128 balance = pool.getProvideOrderBalance(market, apr, provider_A);
        (uint128 borrowable, uint128 fullDebt) = pool.previewBorrow(market, balance, provider_B);
        assertEq(borrowable, balance);
        assertEq(fullDebt, uint256(balance) + (uint256(balance) * apr + HUNDRED_PERCENT - 1) / HUNDRED_PERCENT);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, market, apr, balance);
        assertEq(pool.viewProvideLiquidityForBucket(market, bucketId), 0);
    }

    function test_bucket_liquidity_matches_sum_of_ticks_with_staggered_sync() public {
        uint64 market = markets[1];
        uint256 apr_A = 10 * APR_PERCENT;
        uint256 apr_B = 11 * APR_PERCENT;

        assertEq(
            pool.bucketIdForAPR(apr_A),
            pool.bucketIdForAPR(apr_B)
        );

        uint256 bucketId = pool.bucketIdForAPR(apr_A);

        _deposit(provider_A, 300e18);
        _deposit(provider_B, 200e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, market, apr_A, 100e18);
        assert_bucket_liquidity_eq_ticks(market, bucketId, apr_A, apr_B);

        skip(YEAR / 2); priceOracle.touch();

        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, apr_B, 80e18);
        assert_bucket_liquidity_eq_ticks(market, bucketId, apr_A, apr_B);

        skip(YEAR / 2); priceOracle.touch();
        assert_bucket_liquidity_eq_ticks(market, bucketId, apr_A, apr_B);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, market, apr_A, 33e18);
        assert_bucket_liquidity_eq_ticks(market, bucketId, apr_A, apr_B);

        skip(YEAR / 2); priceOracle.touch();
        assert_bucket_liquidity_eq_ticks(market, bucketId, apr_A, apr_B);

        (, uint128 debt) = pool.previewBorrow(market, 120e18, borrower_A);
        _mint_collateral(borrower_A, 300e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, market, 300e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, market, 120e18, debt);
        assert_bucket_liquidity_eq_ticks(market, bucketId, apr_A, apr_B);
    }

    function test_borrow_consumes_full_bucket_before_next_bucket_ticks() public {
        uint64 market = markets[0];
        uint256 apr_A = 1 * APR_PERCENT;
        uint256 apr_B = 120;
        uint256 apr_C = 2 * APR_PERCENT;

        _deposit(provider_A, 50e18);
        _deposit(provider_B, 70e18);
        _deposit(provider_C, 100e18);

        uint256 bucket_0 = pool.bucketIdForAPR(apr_A);
        uint256 bucket_1 = pool.bucketIdForAPR(apr_C);

        assertEq(bucket_0, pool.bucketIdForAPR(apr_B));
        assertEq(bucket_1, bucket_0 + 1);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, market, apr_A, 50e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, apr_B, 70e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, market, apr_C, 100e18);

        (uint128 borrowed, uint128 debt) = pool.previewBorrow(market, 150e18, borrower_A);
        assertEq(borrowed, 150e18);
        assertEq(debt, 151.94e18);

        _mint_collateral(borrower_A, 400e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, market, 400e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, market, 150e18, debt);

        assertEq(pool.getProvideOrderBalance(market, apr_A, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(market, apr_B, provider_B), 0);
        assertEq(pool.getProvideOrderBalance(market, apr_C, provider_C), 70e18);

        assertEq(pool.loanOf(market, provider_A), 50.5e18);
        assertEq(pool.loanOf(market, provider_B), 70.84e18);
        assertEq(pool.loanOf(market, provider_C), 30.6e18);

        assertEq(pool.viewProvideLiquidityForBucket(market, bucket_0), 0);
        assertEq(pool.viewProvideLiquidityForBucket(market, bucket_1), 70e18);
    }

    function assert_bucket_liquidity_eq_ticks(uint64 market, uint256 bucketId, uint256 apr_A, uint256 apr_B) internal view {
        uint256 tickLiquidity_A = pool.viewProvideLiquidityForTick(market, apr_A);
        uint256 tickLiquidity_B = pool.viewProvideLiquidityForTick(market, apr_B);
        uint256 bucketLiquidity = pool.viewProvideLiquidityForBucket(market, bucketId);

        assertEq(bucketLiquidity, tickLiquidity_A + tickLiquidity_B);
    }
}
