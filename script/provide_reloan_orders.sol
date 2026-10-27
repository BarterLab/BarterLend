// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { humanize_gas } from "script/_common.sol";
import { CreditPoolTestSuite } from "test/CreditPool/0_base.t.sol";

contract provide_reloan_orders is CreditPoolTestSuite {
    uint16 constant ORDERS = 20;
    uint128 constant ORDER_AMOUNT = 1e18;

    function _owner() internal pure override returns (address) {
        return address(1);
    }

    function beforeEach() public override {
        uint64 market = markets[0];

        for (uint256 i = 0; i < ORDERS; i += 1) {
            address borrower = address(uint160(0x3000 + i));
            _deposit_collateral(borrower, market, ORDER_AMOUNT * 4);
            vm.prank(borrower); pool.placeBorrowOrder(borrower, market, 10 * APR_PERCENT, ORDER_AMOUNT);
        }

        for (uint256 i = 0; i < ORDERS; i += 1) {
            address provider = address(uint160(0x2000 + i));
            _deposit(provider, ORDER_AMOUNT);
            vm.prank(provider); pool.provideExactIn(provider, market, ORDER_AMOUNT, 0, 10);
            uint128 loan = pool.loanOf(market, provider);
            vm.prank(provider); pool.placeReloanOrder(provider, market, APR_PERCENT * (i / 4), loan);
        }

        _deposit(provider_A, ORDER_AMOUNT * ORDERS);
    }

    function run() public {
        uint64 market = markets[0];
        vm.startSnapshotGas("provide through 20 reloan orders");
        vm.prank(provider_A); pool.provideExactIn(provider_A, market, ORDER_AMOUNT * ORDERS, 0, ORDERS);
        emit log_named_string("provide_reloan_orders", humanize_gas(vm.stopSnapshotGas()));
    }
}
