// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_markets is CreditPoolTestSuite {
    function assertActiveMarkets(uint64[] memory expectedMarkets) internal view {
        uint64[] memory activeMarkets = pool.getActiveMarkets();
        assertEq(activeMarkets.length, expectedMarkets.length);

        for (uint256 i = 0; i < activeMarkets.length; ++i) {
            assertEq(activeMarkets[i], expectedMarkets[i]);
        }
    }

    function assertActiveMarkets(uint64[3] memory expectedMarkets) internal view {
        uint64[] memory expected = new uint64[](expectedMarkets.length);
        for (uint256 i = 0; i < expectedMarkets.length; ++i) {
            expected[i] = expectedMarkets[i];
        }

        assertActiveMarkets(expected);
    }

    function test_initially_available_markets() public {
        assertActiveMarkets([markets[0], markets[1], markets[2]]);

        skip(YEAR - 1);

        assertActiveMarkets([markets[0], markets[1], markets[2]]);

        skip(1);

        assertActiveMarkets([markets[1], markets[2], markets[3]]);
    }

    function test_markets_timestamps() public view {
        assertEq(markets[0] - YEAR, block.timestamp);
        assertEq(markets[0], block.timestamp + YEAR);

        assertEq(markets[1] - YEAR, block.timestamp + YEAR);
        assertEq(markets[1], block.timestamp + 2 * YEAR);
    }

    function test_markets_balance_independence() public {
        _deposit(provider_A, 100e18);
        _deposit(provider_B, 100e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 60e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[1], 0, 40e18);

        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[1], 0, 100e18);

        skip(YEAR);

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[1], 0, 100e18);


        assertEq_(pool.getProvideOrderBalance(markets[0], 0, provider_A), 66e18);
        assertEq_(pool.getProvideOrderBalance(markets[1], 0, provider_A), 44e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_B), 0);
        assertApproxEqAbs(pool.getProvideOrderBalance(markets[1], 0, provider_B), 210e18, 1);
    }

    function test_cant_order_in_inactive_market() public {
        _deposit(provider_A, 100e18);

        vm.expectRevert(abi.encodeWithSelector(InactiveMarket.selector, markets[3]));
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[3], 0, 100e18);

        skip(YEAR);

        vm.expectRevert(abi.encodeWithSelector(InactiveMarket.selector, markets[0]));
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
    }

    function test_can_cancel_order_from_inactive_market() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        skip(YEAR);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 100e18);
    }

    function test_can_create_order_even_when_max_active_orders_reached_on_another_market() public {
        uint256 MAX_ACTIVE_PORDERS = pool.getMaxActiveProvideOrders();

        uint64 MARKET_A = markets[0];
        uint64 MARKET_B = markets[1];

        _deposit(provider_A, (MAX_ACTIVE_PORDERS + 1) * 1e18);

        for (uint256 i = 0; i < MAX_ACTIVE_PORDERS; ++i) {
            vm.prank(provider_A); pool.placeProvideOrder(provider_A, MARKET_A, i * APR_TICK_SPACING, 1e18);
        }

        vm.expectRevert(abi.encodeWithSelector(TooManyProvideOrders.selector, MAX_ACTIVE_PORDERS));
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, MARKET_A, MAX_ACTIVE_PORDERS * APR_TICK_SPACING, 1e18);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, MARKET_B, MAX_ACTIVE_PORDERS * APR_TICK_SPACING, 1e18);

        assertEq(pool.getProvideOrderBalance(MARKET_B, MAX_ACTIVE_PORDERS * APR_TICK_SPACING, provider_A), 1e18);
    }
}
