// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { humanize_gas } from "script/_common.sol";
import { CreditPoolTestSuite } from "test/CreditPool/0_base.t.sol";

contract worst_case_borrow is CreditPoolTestSuite {
    uint128 constant AMOUNT_PER_TICK = 1e18;
    uint128 constant TICKS = uint128(((MAX_APR / APR_TICK_SPACING) >> BUCKET_SIZE_AS_POWER_OF_TWO) << BUCKET_SIZE_AS_POWER_OF_TWO);

    uint128 borrowAmount;

    function _owner() internal pure override returns (address) {
        return address(1);
    }

    function beforeEach() override public {
        uint64 market = markets[0];
        uint256 MAX_ACTIVE_PORDERS = pool.getMaxActiveProvideOrders();

        for (uint256 i = 0; i < TICKS; i += 1) {
            address provider = address(uint160(0x1000 + i));
            _deposit(provider, AMOUNT_PER_TICK);
            vm.prank(provider); pool.placeProvideOrder(provider, market, i * APR_TICK_SPACING, AMOUNT_PER_TICK);
        }

        for (uint256 i = 0; i < MAX_ACTIVE_PORDERS; i += 1) {
            _deposit(borrower_A, AMOUNT_PER_TICK);
            vm.prank(borrower_A); pool.placeProvideOrder(borrower_A, market, i * APR_TICK_SPACING, AMOUNT_PER_TICK);
        }
        
        borrowAmount = AMOUNT_PER_TICK * TICKS - 1;
        _deposit_collateral(borrower_A, markets[0], borrowAmount * 4);
    }

    function run() public {
        vm.startSnapshotGas("worst case borrow");
        test();
        emit log_named_string("worst_case_borrow", humanize_gas(vm.stopSnapshotGas()));
    }

    function test() public {
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], borrowAmount, type(uint128).max);
    }
}
