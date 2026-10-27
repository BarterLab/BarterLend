// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";
import { IUnderlyingPool } from "src/interfaces/IUnderlyingPool.sol";

contract TestCreditPool_underlying_pool is CreditPoolTestSuite {
    function test_get_provide_order_balance_reads_underlying_pool_once() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        vm.expectCall(address(aaveAdapter), _totalAssetsCall(), 1);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 100e18);
    }

    function test_place_provide_order_reads_underlying_pool_once() public {
        _deposit(provider_A, 100e18);

        vm.expectCall(address(aaveAdapter), _totalAssetsCall(), 1);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        assertEq(aaveToken.balanceOf(address(pool)), 100e18);
        assertEq(pool.balanceOf(provider_A), 0);
    }

    function test_cancel_provide_order_reads_underlying_pool_once() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        vm.expectCall(address(aaveAdapter), _totalAssetsCall(), 1);
        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 0, 40e18);

        assertEq(aaveToken.balanceOf(address(pool)), 60e18);
        assertEq(pool.balanceOf(provider_A), 40e18);
    }

    function test_borrow_reads_underlying_pool_once() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        _deposit_collateral(borrower_A, markets[0], 100e18);

        vm.expectCall(address(aaveAdapter), _totalAssetsCall(), 1);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 44e18);

        assertEq(pool.balanceOf(borrower_A), 40e18);
    }

    function test_get_all_provide_orders_reads_underlying_pool_once() public {
        _deposit(provider_A, 30e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 10e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], APR_TICK_SPACING, 10e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 2 * APR_TICK_SPACING, 10e18);

        vm.expectCall(address(aaveAdapter), _totalAssetsCall(), 1);
        ProvideOrderView[] memory orders = pool.getAllProvideOrders(markets[0], provider_A);

        assertEq(orders.length, 3);
        assertEq(orders[0].amount, 10e18);
        assertEq(orders[1].amount, 10e18);
        assertEq(orders[2].amount, 10e18);
    }

    function test_repay_does_not_read_underlying_pool() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        _deposit_collateral(borrower_A, markets[0], 100e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 44e18);

        vm.mockCallRevert(address(aaveAdapter), _totalAssetsCall(), bytes("valuation unavailable"));
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 10e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 34e18);
    }

    function test_place_borrow_order_does_not_read_underlying_pool() public {
        _deposit_collateral(borrower_A, markets[0], 100e18);

        vm.mockCallRevert(address(aaveAdapter), _totalAssetsCall(), bytes("valuation unavailable"));
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 10e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 10e18);
    }

    function test_liquidation_does_not_read_underlying_pool() public {
        address liquidator = makeAddr("liquidator");
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        _deposit_collateral(borrower_A, markets[0], 220e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 110e18);
        priceOracle.setPrice(0.9e18);
        _mint(liquidator, 110e18);

        vm.mockCallRevert(address(aaveAdapter), _totalAssetsCall(), bytes("valuation unavailable"));
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 110e18, 0, type(uint256).max, "");

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
    }

    function _totalAssetsCall() private view returns (bytes memory) {
        return abi.encodeCall(
            IUnderlyingPool.totalAssets,
            (address(pool), bytes32(uint256(uint160(address(aaveToken)))))
        );
    }
}
