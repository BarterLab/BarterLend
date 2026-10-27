// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_admin is CreditPoolTestSuite {
    error OwnableUnauthorizedAccount(address account);

    function test_protocol_fee_is_consumed_from_cached_and_new_markets() public {
        uint256 new_protocol_fee = UNIT * 3 / 100;

        _deposit(provider_A, 1e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 1e18);

        pool.setProtocolFee(new_protocol_fee);

        _deposit(provider_A, 1000e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 1000e18);
        _deposit_collateral(borrower_A, markets[0], 4000e18);

        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1000e18, type(uint128).max);
        assertEq(pool.loanOf(markets[0], address(this)), 0);

        skip(YEAR);
        priceOracle.touch();

        _deposit(provider_B, 1030e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[3], 10 * APR_PERCENT, 1030e18);
        _deposit_collateral(borrower_B, markets[3], 4000e18);

        vm.prank(borrower_B); pool.borrow(borrower_B, markets[3], 1000e18, type(uint128).max);
        assertEq(pool.loanOf(markets[3], address(this)), 9e18);
    }

    function test_set_liquidation_grace_period_caches_active_and_grace_period_markets() public {
        assertEq(pool.getLiquidationGracePeriod(markets[0]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[1]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[2]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[3]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[4]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[5]), 86400);

        skip(YEAR + 1); // market 0 is in grace period, markets 1-3 are active

        pool.setLiquidationGracePeriod(0);

        assertEq(pool.getLiquidationGracePeriod(markets[0]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[1]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[2]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[3]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[4]), 0);
        assertEq(pool.getLiquidationGracePeriod(markets[5]), 0);

        pool.setLiquidationGracePeriod(1);

        assertEq(pool.getLiquidationGracePeriod(markets[0]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[1]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[2]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[3]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[4]), 1);
        assertEq(pool.getLiquidationGracePeriod(markets[5]), 1);

        skip(YEAR);

        pool.setLiquidationGracePeriod(2);

        assertEq(pool.getLiquidationGracePeriod(markets[0]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[1]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[2]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[3]), 86400);
        assertEq(pool.getLiquidationGracePeriod(markets[4]), 1);
        assertEq(pool.getLiquidationGracePeriod(markets[5]), 2);
    }

    function test_set_protocol_fee_caches_active_and_grace_period_markets() public {
        uint256 oldProtocolFee = pool.getProtocolFee(markets[0]);
        uint256 newProtocolFee = oldProtocolFee + 1;

        assertEq(pool.getProtocolFee(markets[0]), oldProtocolFee);
        assertEq(pool.getProtocolFee(markets[1]), oldProtocolFee);
        assertEq(pool.getProtocolFee(markets[2]), oldProtocolFee);
        assertEq(pool.getProtocolFee(markets[3]), oldProtocolFee);
        assertEq(pool.getProtocolFee(markets[4]), oldProtocolFee);
        assertEq(pool.getProtocolFee(markets[5]), oldProtocolFee);

        skip(YEAR + 1); // market 0 is in grace period, markets 1-3 are active

        pool.setProtocolFee(newProtocolFee);

        assertEq(pool.getProtocolFee(markets[0]), oldProtocolFee);
        assertEq(pool.getProtocolFee(markets[1]), oldProtocolFee);
        assertEq(pool.getProtocolFee(markets[2]), oldProtocolFee);
        assertEq(pool.getProtocolFee(markets[3]), oldProtocolFee);
        assertEq(pool.getProtocolFee(markets[4]), newProtocolFee);
        assertEq(pool.getProtocolFee(markets[5]), newProtocolFee);
    }

    function test_non_admins_cant_set_liquidation_grace_period() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, provider_A));
        vm.prank(provider_A); pool.setLiquidationGracePeriod(0);
    }

    function _set_account_balance_for_rollover(address borrower, uint256 amount) internal {
        uint256 balance = asset.balanceOf(borrower);
        if (balance > 0) vm.prank(borrower); asset.burn(balance);

        vm.prank(borrower); asset.mint(amount);
        vm.prank(borrower); asset.approve(address(permit2), amount);
        vm.prank(borrower); permit2.approve(address(asset), address(rolloverExtension), uint160(amount), type(uint48).max);
    }

    function _rollover(uint64 market, address borrower) internal {
        RolloverSolution memory solution;
        _rollover_extension(address(pool), market, borrower, address(this), UNIT / 100, solution);
        uint128 fee = rolloverExtension.getCollectedFee(address(asset), address(this));
        if (fee > 0) rolloverExtension.withdrawFee(address(asset), address(this), type(uint128).max);
    }
}
