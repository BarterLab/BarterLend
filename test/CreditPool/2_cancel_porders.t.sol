// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_cancel_porders is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.marketsConfig.durations[0] = uint64(YEAR * 1e6);
        params.marketsConfig.durations[1] = uint64(YEAR * 1e6);
        params.marketsConfig.durations[2] = uint64(YEAR * 1e6);
    }

    function test_cant_cancel_more_than_balance() public {
        _deposit(provider_A, 100e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        skip(YEAR);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 200e18, 1, 110e18 - 1));
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 200e18);
    }

    function test_cancel_all() public {
        _deposit(provider_A, 100e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        skip(YEAR);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, type(uint128).max);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        assertEq_(pool.balanceOf(provider_A), 110e18);
    }

    function test_yield_after_cancelling() public {
        _deposit(provider_A, 100e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        skip(YEAR);

        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 110e18);
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 10e18);

        skip(YEAR);

        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 110e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 110e18 - 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        assertEq_(pool.balanceOf(provider_A), 120e18);
    }

    function test_no_yielding_after_full_cancelling() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        skip(YEAR);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 110e18 - 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);

        skip(YEAR);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
    }

    function test_cancelling_independence() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 100e18);

        skip(YEAR);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 10e18);

        skip(YEAR);

        uint256 balance_A = pool.getProvideOrderBalance(markets[0], 0, provider_A) + pool.balanceOf(provider_A);
        uint256 balance_B = pool.getProvideOrderBalance(markets[0], 0, provider_B);
        assertEq_(balance_A + 1e18, balance_B);
    }

    function test_cancel_all_and_place_again() public {
        _deposit(provider_A, 150e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        skip(YEAR);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 110e18 - 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);

        skip(YEAR);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 50e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 50e18);

        skip(YEAR);

        assertApproxEqAbs(pool.getProvideOrderBalance(markets[0], 0, provider_A), 55e18, 2);
    }
}
