// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_total_collateral_cap is CreditPoolTestSuite {
    uint128 internal constant TOTAL_COLLATERAL_CAP = 100e18;

    error OwnableUnauthorizedAccount(address account);

    function reconfigure(InitializationParams memory params) internal pure override {
        params.totalCollateralCap = TOTAL_COLLATERAL_CAP;
    }

    function test_initial_total_collateral_cap() public view {
        assertEq(pool.getTotalCollateralCap(), 100e18);
    }

    function test_deposit_collateral_succeeds_at_total_collateral_cap() public {
        _deposit_collateral(borrower_A, markets[0], 60e18);
        _deposit_collateral(borrower_B, markets[1], 40e18);

        assertEq(pool.collateralOf(markets[0], borrower_A), 60e18);
        assertEq(pool.collateralOf(markets[1], borrower_B), 40e18);
        assertEq(collateral.balanceOf(address(pool)), 100e18);
    }

    function test_deposit_collateral_reverts_above_total_collateral_cap() public {
        _deposit_collateral(borrower_A, markets[0], 100e18);
        _mint_collateral(borrower_B, 1);

        vm.expectRevert(abi.encodeWithSelector(CollateralCapExceeded.selector, 100e18 + 1, 100e18));
        vm.prank(borrower_B); pool.depositCollateral(borrower_B, markets[1], 1);

        assertEq(pool.collateralOf(markets[0], borrower_A), 100e18);
        assertEq(pool.collateralOf(markets[1], borrower_B), 0);
        assertEq(collateral.balanceOf(address(pool)), 100e18);
        assertEq(collateral.balanceOf(borrower_B), 1);
    }

    function test_withdraw_collateral_releases_total_collateral_cap_capacity() public {
        _deposit_collateral(borrower_A, markets[0], 100e18);

        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 40e18);
        _deposit_collateral(borrower_B, markets[1], 40e18);

        assertEq(pool.collateralOf(markets[0], borrower_A), 60e18);
        assertEq(pool.collateralOf(markets[1], borrower_B), 40e18);
        assertEq(collateral.balanceOf(address(pool)), 100e18);
        assertEq(collateral.balanceOf(borrower_A), 40e18);
    }

    function test_liquidation_releases_total_collateral_cap_capacity() public {
        address liquidator = makeAddr("Liquidator");

        _deposit(provider_A, 40e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 40e18);
        _deposit_collateral(borrower_A, markets[0], 100e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 40e18, 40e18);

        priceOracle.setPrice(0.5e18);
        _mint(liquidator, 40e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 40e18, 0, type(uint256).max, "");

        _deposit_collateral(borrower_B, markets[1], 100e18);

        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[1], borrower_B), 100e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(collateral.balanceOf(liquidator), 100e18);
        assertEq(collateral.balanceOf(address(pool)), 100e18);
    }

    function test_fuzz_total_collateral_cap_is_global_for_any_deposit_split(uint128 rawFirstDeposit) public {
        uint128 firstDeposit = uint128(bound(rawFirstDeposit, 1, TOTAL_COLLATERAL_CAP - 1));
        uint128 secondDeposit = TOTAL_COLLATERAL_CAP - firstDeposit;

        _deposit_collateral(borrower_A, markets[0], firstDeposit);
        _deposit_collateral(borrower_B, markets[1], secondDeposit);
        _mint_collateral(borrower_C, 1);

        vm.expectRevert(abi.encodeWithSelector(CollateralCapExceeded.selector, 100e18 + 1, 100e18));
        vm.prank(borrower_C); pool.depositCollateral(borrower_C, markets[2], 1);

        assertEq(pool.collateralOf(markets[0], borrower_A), firstDeposit);
        assertEq(pool.collateralOf(markets[1], borrower_B), secondDeposit);
        assertEq(pool.collateralOf(markets[2], borrower_C), 0);
        assertEq(collateral.balanceOf(address(pool)), 100e18);
    }

    function test_non_owner_cannot_set_total_collateral_cap() public {
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, provider_A));
        vm.prank(provider_A); pool.setTotalCollateralCap(200e18);

        assertEq(pool.getTotalCollateralCap(), 100e18);
    }

    function test_set_total_collateral_cap_emits_admin_config_updated() public {
        vm.expectEmit(true, false, false, true, address(pool));
        emit AdminConfigUpdated(address(this), "totalCollateralCap", 100e18, 200e18);
        pool.setTotalCollateralCap(200e18);

        assertEq(pool.getTotalCollateralCap(), 200e18);
    }

    function test_increased_total_collateral_cap_applies_immediately_and_to_new_active_markets() public {
        _deposit_collateral(borrower_A, markets[0], 100e18);

        pool.setTotalCollateralCap(200e18);

        _deposit_collateral(borrower_A, markets[0], 10e18);
        _deposit_collateral(borrower_B, markets[1], 20e18);
        _deposit_collateral(borrower_C, markets[2], 30e18);

        skip(YEAR);
        _deposit_collateral(borrower_D, markets[3], 40e18);
        _mint_collateral(borrower_D, 1);

        for (uint256 i = 1; i < 4; ++i) {
            vm.expectRevert(abi.encodeWithSelector(CollateralCapExceeded.selector, 200e18 + 1, 200e18));
            vm.prank(borrower_D); pool.depositCollateral(borrower_D, markets[i], 1);
        }

        assertEq(pool.getTotalCollateralCap(), 200e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 110e18);
        assertEq(pool.collateralOf(markets[1], borrower_B), 20e18);
        assertEq(pool.collateralOf(markets[2], borrower_C), 30e18);
        assertEq(pool.collateralOf(markets[3], borrower_D), 40e18);
        assertEq(collateral.balanceOf(address(pool)), 200e18);
        assertEq(collateral.balanceOf(borrower_D), 1);
    }

    function test_total_collateral_cap_can_be_set_below_current_deposited_collateral_and_withdrawal_remains_available() public {
        _deposit_collateral(borrower_A, markets[0], 100e18);

        pool.setTotalCollateralCap(50e18);

        assertEq(pool.getTotalCollateralCap(), 50e18);
        assertEq(collateral.balanceOf(address(pool)), 100e18);

        _mint_collateral(borrower_B, 1);
        for (uint256 i = 0; i < 3; ++i) {
            vm.expectRevert(abi.encodeWithSelector(CollateralCapExceeded.selector, 100e18 + 1, 50e18));
            vm.prank(borrower_B); pool.depositCollateral(borrower_B, markets[i], 1);

            assertEq(pool.collateralOf(markets[i], borrower_B), 0);
        }

        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 25e18);

        assertEq(pool.collateralOf(markets[0], borrower_A), 75e18);
        assertEq(collateral.balanceOf(borrower_B), 1);
        assertEq(collateral.balanceOf(address(pool)), 75e18);
        assertEq(collateral.balanceOf(borrower_A), 25e18);

        vm.expectRevert(abi.encodeWithSelector(CollateralCapExceeded.selector, 75e18 + 1, 50e18));
        vm.prank(borrower_B); pool.depositCollateral(borrower_B, markets[1], 1);
    }

    function test_move_collateral_succeeds_above_total_collateral_cap() public {
        _deposit_collateral(borrower_A, markets[0], 100e18);
        pool.setTotalCollateralCap(50e18);

        vm.prank(borrower_A); pool.moveCollateral(borrower_A, markets[0], markets[1], 40e18);

        assertEq(pool.getTotalCollateralCap(), 50e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 60e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 40e18);
        assertEq(collateral.balanceOf(address(pool)), 100e18);
    }

    function test_direct_collateral_transfer_does_not_count_toward_total_collateral_cap() public {
        _mint_collateral(provider_A, 60e18);
        vm.prank(provider_A); collateral.transfer(address(pool), 60e18);

        _deposit_collateral(borrower_A, markets[0], 100e18);
        _mint_collateral(borrower_B, 1);

        vm.expectRevert(abi.encodeWithSelector(CollateralCapExceeded.selector, 100e18 + 1, 100e18));
        vm.prank(borrower_B); pool.depositCollateral(borrower_B, markets[1], 1);

        assertEq(pool.collateralOf(markets[0], provider_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 100e18);
        assertEq(pool.collateralOf(markets[1], borrower_B), 0);
        assertEq(collateral.balanceOf(address(pool)), 160e18);
        assertEq(collateral.balanceOf(borrower_B), 1);
    }

    function test_direct_collateral_transfer_above_cap_does_not_block_deposits_or_withdrawals() public {
        _mint_collateral(provider_A, 140e18);
        vm.prank(provider_A); collateral.transfer(address(pool), 140e18);

        _deposit_collateral(borrower_A, markets[0], 100e18);

        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 40e18);
        _deposit_collateral(borrower_B, markets[1], 40e18);

        assertEq(pool.collateralOf(markets[0], borrower_A), 60e18);
        assertEq(pool.collateralOf(markets[1], borrower_B), 40e18);
        assertEq(collateral.balanceOf(address(pool)), 240e18);
        assertEq(collateral.balanceOf(borrower_A), 40e18);
    }

    function test_refinance_debts_succeeds_above_total_collateral_cap() public {
        _deposit(provider_A, 20e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 20e18);
        _deposit_collateral(borrower_A, markets[0], 80e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 20e18, 20e18);

        pool.setTotalCollateralCap(50e18);
        skip(YEAR);
        priceOracle.touch();

        _deposit(provider_B, 20e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[1], 0, 20e18);

        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](1);
        refinances[0] = RefinanceDebtParams({
            toMarket: markets[1],
            debtToRepay: 20e18,
            assetsToBorrow: 20e18
        });

        vm.prank(borrower_A); pool.refinanceDebts(borrower_A, markets[0], 0, refinances);

        assertEq(pool.getTotalCollateralCap(), 50e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[1], borrower_A), 20e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[1], borrower_A), 80e18);
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_B), 0);
        assertEq(pool.balanceOf(borrower_A), 20e18);
        assertEq(collateral.balanceOf(address(pool)), 80e18);
    }
}
