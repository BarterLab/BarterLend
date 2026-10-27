// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_virtual_shares is CreditPoolTestSuite {
    function test_donation_cycles_do_not_block_small_deposits() public {
        _inflate_tick();

        _deposit(provider_B, 0.5e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 0.5e18);

        assertApproxEqAbs(pool.getProvideOrderBalance(markets[0], 0, provider_B), 0.5e18, 1);
    }

    function test_donation_cycles_do_not_steal_rounding_from_next_depositor() public {
        _inflate_tick();

        _deposit(provider_B, 2e18 - 1);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 2e18 - 1);

        assertApproxEqAbs(pool.getProvideOrderBalance(markets[0], 0, provider_B), 2e18 - 1, 1);
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, type(uint128).max);
        assertApproxEqAbs(pool.getProvideOrderBalance(markets[0], 0, provider_B), 2e18 - 1, 1);
    }

    function test_bucket_fill_does_not_return_virtual_donation_to_attacker() public {
        _inflate_tick();
        uint128 assets = uint128(pool.viewProvideLiquidityForTick(markets[0], 0));

        _borrow(markets[0], borrower_A, assets);

        assertApproxEqAbs(pool.loanOf(markets[0], provider_A), 1e18, 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);

        _deposit(provider_A, 2e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 2e18);

        assertApproxEqAbs(pool.loanOf(markets[0], provider_A), 1e18, 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 2e18);
    }

    function test_tick_fill_does_not_return_virtual_donation_to_attacker() public {
        _inflate_tick();
        uint128 assets = uint128(pool.viewProvideLiquidityForTick(markets[0], 0));

        _borrow(markets[0], borrower_A, assets - 1);

        assertApproxEqAbs(pool.loanOf(markets[0], provider_A), 1e18, 2);
    }

    function test_last_provider_cannot_leave_virtual_assets_to_next_depositor() public {
        _inflate_tick();
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, type(uint128).max);
        uint256 virtualAssets = pool.viewProvideLiquidityForTick(markets[0], 0);
        assertGt(virtualAssets, 1e18);

        _deposit(provider_B, 2e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 2e18);
        assertApproxEqAbs(pool.getProvideOrderBalance(markets[0], 0, provider_B), 2e18, 1);

        vm.prank(provider_B); pool.cancelProvideOrder(provider_B, markets[0], 0, type(uint128).max);
        assertApproxEqAbs(pool.balanceOf(provider_B), 2e18, 1);
        assertApproxEqAbs(pool.viewProvideLiquidityForTick(markets[0], 0), virtualAssets, 1);
    }

    function test_self_borrow_does_not_realize_virtual_assets_as_own_loan() public {
        _inflate_tick();
        uint128 assets = uint128(pool.viewProvideLiquidityForTick(markets[0], 0));

        _borrow(markets[0], provider_A, assets - 1e18);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 1e18);
    }

    function test_fuzz_partial_then_full_borrow_cannot_recover_virtual_donation(uint128 amount) public {
        _inflate_tick();
        uint128 assets = uint128(pool.viewProvideLiquidityForTick(markets[0], 0));
        amount = uint128(bound(amount, MIN_AMOUNT, assets - MIN_AMOUNT));

        _borrow(markets[0], borrower_A, amount);
        assertLe(
            uint256(pool.loanOf(markets[0], provider_A)) + pool.getProvideOrderBalance(markets[0], 0, provider_A),
            1e18
        );

        _borrow(markets[0], borrower_A, assets - amount);
        assertLe(pool.loanOf(markets[0], provider_A), 1e18);
        assertApproxEqAbs(pool.loanOf(markets[0], provider_A), 1e18, 2);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
    }

    function test_fuzz_atoken_donation_and_cancel_do_not_profit_from_next_depositor(
        uint128 donation,
        uint128 deposit
    ) public {
        donation = uint128(bound(donation, 1e18, 1e24));
        deposit = uint128(bound(deposit, 2e18, 1e24));
        _deposit(provider_A, 1e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 1e18);

        vm.prank(provider_A); asset.mint(donation);
        vm.prank(provider_A); asset.approve(address(aavePool), donation);
        vm.prank(provider_A); aavePool.supply(address(asset), donation, provider_A, 0);
        vm.prank(provider_A); aaveToken.transfer(address(pool), donation);

        uint128 balance = pool.getProvideOrderBalance(markets[0], 0, provider_A);
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, balance - 1e18);

        _deposit(provider_B, deposit);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, deposit);
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, type(uint128).max);
        vm.prank(provider_B); pool.cancelProvideOrder(provider_B, markets[0], 0, type(uint128).max);

        assertLe(pool.balanceOf(provider_A), uint256(donation) + 1e18);
        assertLe(pool.balanceOf(provider_B), deposit);
        assertApproxEqAbs(pool.balanceOf(provider_B), deposit, 1);
    }

    function test_borrow_reverts_atomically_when_own_order_cannot_be_restored() public {
        _seed_order_with_large_share_price();
        _deposit_collateral(provider_A, markets[0], 8000);

        vm.expectRevert(abi.encodeWithSelector(ZeroSharesMinted.selector, 1));
        vm.prank(provider_A); pool.borrow(provider_A, markets[0], 2000, 2000);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_C), 2000);
        assertEq(pool.loanOf(markets[0], provider_C), 0);
        assertEq(pool.debtOf(markets[0], provider_A), 0);
        assertEq(pool.balanceOf(provider_A), 1e27 - 1);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 1);
        vm.prank(provider_A); pool.borrow(provider_A, markets[0], 2000, 2000);
        assertEq(pool.debtOf(markets[0], provider_A), 2000);
        assertEq(pool.loanOf(markets[0], provider_C), 2000);

        _deposit(provider_B, 2);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 2);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_B), 1);
        vm.prank(provider_B); pool.cancelProvideOrder(provider_B, markets[0], 10 * APR_PERCENT, 1);
        assertEq(pool.balanceOf(provider_B), 1);
    }

    function test_reloan_reverts_atomically_when_own_order_cannot_be_restored() public {
        _seed_order_with_large_share_price();
        _deposit_collateral(borrower_A, markets[0], 8000);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, 2000);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 2000, 2000, 1);

        vm.expectRevert(abi.encodeWithSelector(ZeroSharesMinted.selector, 1));
        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 2000, 2000);

        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_C), 2000);
        assertEq(pool.loanOf(markets[0], provider_A), 2000);
        assertEq(pool.loanOf(markets[0], provider_C), 0);
        assertEq(pool.balanceOf(provider_A), 1e27 - 2001);
    }

    function _seed_order_with_large_share_price() private {
        pool.setProvideOrderMinAmount(1);
        pool.setBorrowOrderMinAmount(1);
        _deposit(provider_A, 1);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 1);

        vm.prank(provider_A); asset.mint(2e27);
        vm.prank(provider_A); asset.approve(address(aavePool), 2e27);
        vm.prank(provider_A); aavePool.supply(address(asset), 2e27, address(pool), 0);
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 1e27 - 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 1);

        _deposit(provider_C, 2000);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 0, 2000);
    }

    function _inflate_tick() private {
        pool.setProvideOrderMinAmount(1);
        _deposit(provider_A, 1e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 1e18);

        // Without virtual shares, 22 factors of 100 and one factor of 10 reduce 1e45 shares to 1.
        for (uint256 i = 0; i < 23; i++) {
            uint128 donation = i == 22 ? 9e18 : 99e18;
            vm.prank(provider_A); asset.mint(donation);
            vm.prank(provider_A); asset.approve(address(aavePool), donation);
            vm.prank(provider_A); aavePool.supply(address(asset), donation, address(pool), 0);

            uint128 balance = pool.getProvideOrderBalance(markets[0], 0, provider_A);
            vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, balance - 1e18);
        }
    }
}
