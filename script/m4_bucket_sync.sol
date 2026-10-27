// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { humanize_gas } from "script/_common.sol";
import { CreditPoolTestSuite } from "test/CreditPool/0_base.t.sol";

contract m4_bucket_sync is CreditPoolTestSuite {
    uint128 constant AMOUNT_PER_TICK = 1e18;

    function _owner() internal pure override returns (address) {
        return address(1);
    }

    function beforeEach() public override {
        uint64 market = markets[0];

        for (uint256 i = 0; i < TICKS_PER_BUCKET; i++) {
            address provider = address(uint160(0x1000 + i));
            _deposit(provider, AMOUNT_PER_TICK);
            vm.prank(provider); pool.placeProvideOrder(provider, market, i * APR_TICK_SPACING, AMOUNT_PER_TICK);
        }

        // A second market makes the global index differ from this bucket's share of the idle assets.
        _deposit(provider_B, 73e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[1], 0, 73e18);
        _deposit(provider_A, 3e18);
        _deposit_collateral(borrower_A, market, 200e18);
    }

    function run() public {
        uint64 market = markets[0];
        uint256 snapshot = vm.snapshotState();

        vm.startSnapshotGas("m4 place without index change");
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, market, 0, 2e18);
        uint256 gasUsed = vm.stopSnapshotGas();
        assertEq(vm.revertToState(snapshot), true);
        emit log_named_string("place_without_index_change", humanize_gas(gasUsed));

        skip(YEAR / 10); priceOracle.touch();

        snapshot = vm.snapshotState();
        vm.startSnapshotGas("m4 place after index change");
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, market, 0, 2e18);
        gasUsed = vm.stopSnapshotGas();
        assertEq(vm.revertToState(snapshot), true);
        emit log_named_string("place_after_index_change", humanize_gas(gasUsed));

        snapshot = vm.snapshotState();
        vm.startSnapshotGas("m4 cancel after index change");
        vm.prank(address(0x1000)); pool.cancelProvideOrder(address(0x1000), market, 0, type(uint128).max);
        gasUsed = vm.stopSnapshotGas();
        assertEq(vm.revertToState(snapshot), true);
        emit log_named_string("cancel_after_index_change", humanize_gas(gasUsed));

        snapshot = vm.snapshotState();
        vm.startSnapshotGas("m4 preview after index change");
        pool.previewBorrow(market, 10e18, borrower_A);
        gasUsed = vm.stopSnapshotGas();
        assertEq(vm.revertToState(snapshot), true);
        emit log_named_string("preview_after_index_change", humanize_gas(gasUsed));

        snapshot = vm.snapshotState();
        vm.startSnapshotGas("m4 partial borrow after index change");
        vm.prank(borrower_A); pool.borrow(borrower_A, market, 10e18, type(uint128).max);
        gasUsed = vm.stopSnapshotGas();
        assertEq(vm.revertToState(snapshot), true);
        emit log_named_string("partial_borrow_after_index_change", humanize_gas(gasUsed));

        uint128 bucketAssets = uint128(pool.viewProvideLiquidityForBucket(market, pool.bucketIdForAPR(0)));
        vm.startSnapshotGas("m4 whole bucket borrow after index change");
        vm.prank(borrower_A); pool.borrow(borrower_A, market, bucketAssets, type(uint128).max);
        emit log_named_string("whole_bucket_borrow_after_index_change", humanize_gas(vm.stopSnapshotGas()));
    }
}
