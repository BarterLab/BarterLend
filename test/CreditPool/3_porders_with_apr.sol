// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_porders_apr is CreditPoolTestSuite {
    function test_porders_balance_independence() public {
        _deposit(provider_A, 60e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 1 * APR_PERCENT, 10e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 2 * APR_PERCENT, 20e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[1], 3 * APR_PERCENT, 30e18);

        skip(YEAR);

        _deposit(provider_A, 10e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[1], 3 * APR_PERCENT, 10e18);

        assertEq_(pool.getProvideOrderBalance(markets[0], 1 * APR_PERCENT, provider_A), 11e18);
        assertEq_(pool.getProvideOrderBalance(markets[0], 2 * APR_PERCENT, provider_A), 22e18);
        assertEq_(pool.getProvideOrderBalance(markets[1], 3 * APR_PERCENT, provider_A), 43e18); // 33 + new 10
    }
}
