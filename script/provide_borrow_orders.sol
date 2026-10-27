// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { humanize_gas } from "script/_common.sol";
import { CreditPoolTestSuite } from "test/CreditPool/0_base.t.sol";

contract provide_borrow_orders is CreditPoolTestSuite {
    uint16 constant ORDERS = 50;
    uint128 constant ORDER_AMOUNT = 1e18;

    function _owner() internal pure override returns (address) {
        return address(1);
    }

    function beforeEach() public override {
        uint64 market = markets[0];

        for (uint256 i = 0; i < ORDERS; i += 1) {
            address borrower = address(uint160(0x1000 + i));
            _deposit_collateral(borrower, market, ORDER_AMOUNT * 4);
            vm.prank(borrower); pool.placeBorrowOrder(borrower, market, APR_PERCENT * (i / 4), ORDER_AMOUNT);
        }

        _deposit(provider_A, ORDER_AMOUNT * ORDERS);
    }

    function run() public {
        vm.startSnapshotGas("provide through 20 borrow orders");
        test();
        emit log_named_string("provide_borrow_orders", humanize_gas(vm.stopSnapshotGas()));
    }

    function test() public {
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], ORDER_AMOUNT * ORDERS, 0, ORDERS);
    }
}
