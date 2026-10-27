// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ICreditPool } from "src/interfaces/ICreditPool.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";

using Math for uint256;

contract KeeperHelpers is CreditPoolTestSuite {
    ReborrowSolution[] internal _reborrows;
    uint256 internal constant KEEPER_FEE = UNIT / 100; // 1%

    function beforeEach() public override virtual {
        while (_reborrows.length > 0) _reborrows.pop();
    }

    function _execute() internal {
        _execute(0, "");
    }

    function _execute(uint256 extraSkip, bytes memory revertData) internal {
        _mature(extraSkip);
        _rollover(revertData);
    }

    function _mature(uint256 extraSkip) internal {
        skip(YEAR + extraSkip);
        priceOracle.touch();
    }

    function _rollover() internal {
        _rollover("");
    }

    function _rollover(bytes memory revertData) internal {
        RolloverSolution memory solution;
        solution.reborrows = new ReborrowSolution[](_reborrows.length);
        for (uint256 i = 0; i < _reborrows.length; i++) {
            ReborrowSolution memory reborrow = _reborrows[i];
            solution.reborrows[i] = reborrow;
        }

        if (revertData.length > 0) vm.expectRevert(revertData);
        _rollover_extension(address(pool), markets[0], borrower_A, address(this), KEEPER_FEE, solution);
        if (revertData.length == 0) _withdraw_rollover_fee(address(this));

        while (_reborrows.length > 0) _reborrows.pop();
    }

    function _withdraw_rollover_fee(address recipient) internal {
        uint128 fee = rolloverExtension.getCollectedFee(address(asset), recipient);
        if (fee > 0) rolloverExtension.withdrawFee(address(asset), recipient, type(uint128).max);
    }

    function _set_max_rollover_factor(uint256 factor) internal {
        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, factor, KEEPER_FEE);
        _approve_rollover_extension(borrower_A);
    }

    function _set_loan(uint128 amount) internal {
        _deposit(borrower_A, amount);
        vm.prank(borrower_A); pool.placeProvideOrder(borrower_A, markets[0], 0, amount);
        _borrow(markets[0], borrower_B, amount);
        assertEq(pool.loanOf(markets[0], borrower_A), amount);
    }

    function _set_available_to_claim(uint128 amount) internal {
        _mint(borrower_B, amount);
        vm.prank(borrower_B); asset.transfer(address(pool), amount);
        pool.setAvailableToClaim(markets[0], amount);
    }

    function _set_debt(uint128 amount) internal {
        _deposit(provider_A, amount);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, amount);
        _deposit_collateral(borrower_A, markets[0], amount * 4);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], amount, type(uint128).max);
        _withdraw_and_burn(borrower_A, amount);
        assertEq(pool.debtOf(markets[0], borrower_A), amount);
    }

    function _set_collateral(uint128 amount) internal {
        uint128 balance = pool.collateralOf(markets[0], borrower_A);
        if (balance > amount) {
            vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, balance - amount);
        } else if (balance < amount) {
            _deposit_collateral(borrower_A, markets[0], amount - balance);
        }
    }

    function _set_pool_balance(uint128 amount) internal {
        _deposit_collateral(borrower_A, markets[0], amount * 4);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, amount);
        _deposit(provider_A, amount);
        _provide(markets[0], provider_A, amount);
        _deposit(borrower_A, amount);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], amount);
        assertEq(pool.balanceOf(borrower_A), amount);
    }

    function _set_account_balance(uint128 amount) internal {
        uint256 balance = asset.balanceOf(borrower_A);
        if (balance > 0) vm.prank(borrower_A); asset.burn(balance);
        vm.prank(borrower_A); asset.mint(amount);
        vm.prank(borrower_A); asset.approve(address(permit2), amount);
        vm.prank(borrower_A); permit2.approve(address(asset), address(rolloverExtension), uint160(amount), type(uint48).max);
    }

    function _set_provide_order(uint64 market, uint256 APR, uint128 amount) internal {
        _deposit(provider_A, amount);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, market, APR * APR_PERCENT, amount);
    }

    function _add_reborrow(uint64 market, uint256 debtPercent) internal {
        _reborrows.push(ReborrowSolution({
            market: market,
            debtPercent: debtPercent
        }));
    }
}



contract TestCreditPool_keeper is KeeperHelpers {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.liquidationGracePeriod = 0;
    }

    function test_cant_rollover_when_fee_is_greater() public {
        _set_debt(1000e18);
        _set_max_rollover_factor(0);

        _mature(0);

        RolloverSolution memory solution;
        vm.expectRevert(abi.encodeWithSelector(KeeperFeeTooHigh.selector, KEEPER_FEE, KEEPER_FEE + 1));
        _rollover_extension(address(pool), markets[0], borrower_A, address(this), KEEPER_FEE + 1, solution);
    }

    function test_pool_balance() public {
        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit RolloverConfigUpdated(address(pool), borrower_A, markets[0], true, 0, KEEPER_FEE);
        _set_max_rollover_factor(0);

        _set_debt(1000e18);
        _set_pool_balance(1100e18);

        _mature(0);

        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit DebtCoveredFromPoolBalance(address(pool), borrower_A, markets[0], 1000e18, 10e18);
        _rollover();

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(asset.balanceOf(address(this)), 10e18);
        assertEq(pool.balanceOf(borrower_A), 90e18);
    }

    function test_can_claim_after_rollover() public {
        _set_max_rollover_factor(UNIT * 20 / 100);

        _deposit(provider_A, 300e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[1],  5 * APR_PERCENT, 200e18);
        _borrow(markets[0], borrower_A, 100e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);

        _add_reborrow(markets[1], UNIT);
        _execute();

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        vm.prank(provider_A); pool.claim(provider_A, markets[0], 110e18);
    }

    function test_cant_rollover_for_active_marker() public {
        RolloverSolution memory solution;

        _set_max_rollover_factor(UNIT);
        _set_debt(1000e18);
        _set_pool_balance(1100e18);

        vm.expectRevert(abi.encodeWithSelector(ActiveMarket.selector, markets[0]));
        vm.prank(provider_B); _rollover_extension(address(pool), markets[0], borrower_A, address(this), KEEPER_FEE, solution);
    }

    function test_cant_rollover_when_max_rollover_is_not_enabled() public {
        _set_debt(1000e18);
        _set_pool_balance(1100e18);

        _execute(0, abi.encodeWithSelector(RolloverDisabled.selector, address(pool), borrower_A, markets[0]));
    }

    function test_loan() public {
        _set_max_rollover_factor(0); // keeper fee only

        _set_debt(1000e18);
        _set_loan(1010e18);
        _set_available_to_claim(10e18);

        _mature(0);
        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit DebtCoveredWithLoan(address(pool), borrower_A, markets[0], 1000e18, 10e18);
        _rollover();

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], borrower_A), 0);
        assertEq(asset.balanceOf(address(this)), 10e18);
    }

    function test_loan_partial() public {
        _set_max_rollover_factor(0); // keeper fee only

        _set_debt(2000e18);
        _set_loan(1010e18);
        _set_available_to_claim(5e18);
        _set_account_balance(505e18);

        _mature(0);
        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit DebtCoveredWithLoan(address(pool), borrower_A, markets[0], 500e18, 5e18);
        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit DebtCoveredFromAccountTransfer(address(pool), borrower_A, markets[0], 500e18, 5e18);
        _rollover();

        assertEq(pool.debtOf(markets[0], borrower_A), 1000e18);
        assertEq(pool.loanOf(markets[0], borrower_A), 505e18);
        assertEq(pool.balanceOf(borrower_A), 0);
        assertEq(asset.balanceOf(address(this)), 10e18);
    }

    function test_transfer() public {
        _set_max_rollover_factor(0); // keeper fee only

        _set_debt(1000e18);
        _set_account_balance(1100e18);

        _mature(0);

        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit DebtCoveredFromAccountTransfer(address(pool), borrower_A, markets[0], 1000e18, 10e18);
        _rollover();

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(asset.balanceOf(address(this)), 10e18);
        assertEq(asset.balanceOf(borrower_A), 90e18);
    }

    function test_pool_and_transfer() public {
        _set_max_rollover_factor(0); // keeper fee only

        _set_debt(1000e18);
        _set_pool_balance(500e18);
        _set_account_balance(600e18);

        _execute();

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq_(asset.balanceOf(address(this)), 10e18);
        assertEq_(asset.balanceOf(borrower_A), 90e18);
    }

    function test_reborrow() public {
        _set_max_rollover_factor(UNIT * 111 / 1000); // (1000 debt + 10 fee) * (1 + 10%)

        _set_debt(1000e18);
        _set_provide_order(markets[1], 10, 2000e18);
        _add_reborrow(markets[1], UNIT);

        _mature(0);

        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit DebtRolledOver(address(pool), borrower_A, markets[0], markets[1], 1000e18, 1111e18, 4000e18, 10e18);
        _rollover();

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(asset.balanceOf(address(this)), 10e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 1111e18); // (1000 * 101%) * 110%
    }

    function test_reborrow_two_markets() public {
        _set_max_rollover_factor(UNIT * 20 / 100);

        _set_debt(1000e18);
        _set_collateral(2500e18);
        _set_provide_order(markets[1], 10, 600e18);
        _set_provide_order(markets[2], 10, 600e18);
        _add_reborrow(markets[1], UNIT * 50 / 100);
        _add_reborrow(markets[2], UNIT * 50 / 100);

        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 1);
        _execute();

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(asset.balanceOf(address(this)), 10e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 555.5e18); // (500 * 101%) * 110%
        assertEq(pool.debtOf(markets[2], borrower_A), 606.0e18); // (500 * 101%) * 120%

        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertApproxEqAbs(pool.collateralOf(markets[1], borrower_A), 1195.65e18, 1e16); // 2500 * 555.5 / (555.5 + 606.0)
        assertApproxEqAbs(pool.collateralOf(markets[2], borrower_A), 1304.35e18, 1e16); // 2500 * 606.0 / (555.5 + 606.0)
    }

    function test_reborrow_repeated_target_uses_actual_orderbook_without_preview() public {
        _set_max_rollover_factor(UNIT * 7 / 100);

        _set_debt(1000e18);
        _mature(0);

        _set_provide_order(markets[1], 0, 505e18);
        _set_provide_order(markets[1], 10, 505e18);
        _add_reborrow(markets[1], UNIT * 50 / 100);
        _add_reborrow(markets[1], UNIT * 50 / 100);

        vm.mockCallRevert(
            address(pool),
            abi.encodeWithSelector(ICreditPool.previewBorrow.selector),
            bytes("previewBorrow called")
        );
        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit DebtRolledOver(
            address(pool),
            borrower_A,
            markets[0],
            markets[1],
            500e18,
            505e18,
            1904761904761904761525,
            5e18
        );
        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit DebtRolledOver(
            address(pool),
            borrower_A,
            markets[0],
            markets[1],
            500e18,
            555.5e18,
            2095238095238095238475,
            5e18
        );
        vm.expectEmit(true, true, false, true, address(rolloverExtension));
        emit FeeCollected(address(asset), address(this), 10e18);
        _rollover();

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[1], borrower_A), 1060.5e18);
        assertEq(pool.loanOf(markets[1], provider_A), 1060.5e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[1], borrower_A), 4000e18);
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[1], 10 * APR_PERCENT, provider_A), 0);
        assertEq(asset.balanceOf(address(this)), 10e18);
    }

    function test_reborrow_actual_factor_excess_reverts_all_state() public {
        _set_max_rollover_factor(UNIT * 6 / 100);

        _set_debt(1000e18);
        _mature(0);

        _set_provide_order(markets[1], 0, 505e18);
        _set_provide_order(markets[1], 10, 505e18);
        _add_reborrow(markets[1], UNIT * 50 / 100);
        _add_reborrow(markets[1], UNIT * 50 / 100);

        _rollover(abi.encodeWithSelector(
            MaxRolloverFactorExceeded.selector,
            0.0605e18,
            0.06e18
        ));

        assertEq(pool.debtOf(markets[0], borrower_A), 1000e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 0);
        assertEq(pool.loanOf(markets[1], provider_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 4000e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_A), 505e18);
        assertEq(pool.getProvideOrderBalance(markets[1], 10 * APR_PERCENT, provider_A), 505e18);
        assertEq(pool.getAvailableToClaim(markets[0]), 0);
        assertEq(pool.balanceOf(borrower_A), 0);
        assertEq(rolloverExtension.getCollectedFee(address(asset), address(this)), 0);
        assertEq(asset.balanceOf(address(rolloverExtension)), 0);
    }

    function test_reborrow_liquidity_shortfall_reverts_completed_prior_leg() public {
        _set_max_rollover_factor(UNIT * 20 / 100);

        _set_debt(1000e18);
        _mature(0);

        _set_provide_order(markets[1], 0, 505e18);
        _set_provide_order(markets[2], 0, 500e18);
        _add_reborrow(markets[1], UNIT * 50 / 100);
        _add_reborrow(markets[2], UNIT * 50 / 100);

        _rollover(abi.encodeWithSelector(BorrowAssetsNotReached.selector, 505e18, 500e18));

        assertEq(pool.debtOf(markets[0], borrower_A), 1000e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 0);
        assertEq(pool.debtOf(markets[2], borrower_A), 0);
        assertEq(pool.loanOf(markets[1], provider_A), 0);
        assertEq(pool.loanOf(markets[2], provider_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 4000e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 0);
        assertEq(pool.collateralOf(markets[2], borrower_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_A), 505e18);
        assertEq(pool.getProvideOrderBalance(markets[2], 0, provider_A), 500e18);
        assertEq(pool.getAvailableToClaim(markets[0]), 0);
        assertEq(pool.balanceOf(borrower_A), 0);
        assertEq(rolloverExtension.getCollectedFee(address(asset), address(this)), 0);
        assertEq(asset.balanceOf(address(rolloverExtension)), 0);
    }

    function test_partial_reborrow() public {
        _set_max_rollover_factor(UNIT * 20 / 100);

        _set_debt(1000e18);
        _set_collateral(2500e18);
        _set_provide_order(markets[1], 10, 500e18);
        _add_reborrow(markets[1], UNIT * 20 / 100);

        _execute();

        assertEq(pool.debtOf(markets[0], borrower_A), 800e18);
        assertEq(asset.balanceOf(address(this)), 2e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 222.2e18); // (200 * 101%) * 110%
        assertApproxEqAbs(pool.collateralOf(markets[0], borrower_A), 1956.56e18, 1e16);
        assertApproxEqAbs(pool.collateralOf(markets[1], borrower_A),  543.43e18, 1e16);
    }

    function test_all_sources_but_partial() public {
        _set_max_rollover_factor(UNIT * 12 / 100);

        _set_debt(1000e18);
        _set_pool_balance(100e18);
        _set_account_balance(200e18);
        _set_provide_order(markets[1], 10, 300e18);
        _set_provide_order(markets[2], 5, 300e18);

        _add_reborrow(markets[1], UNIT * 35 / 100);
        _add_reborrow(markets[2], UNIT * 40 / 100);

        _execute();

        // 1. pool
        // Δdebt₁ = 100 / 101%  = 99.01
        // Δfee₁  = 100 - 99.01 = 0.99

        // 2. account
        // Δdebt₂ = 200 / 101%   = 198.02
        // Δfee₂  = 200 - 198.02 = 1.98

        // remaining debt = (1000 - Σ₂ Δdebtᵢ) = 702.97

        // 3. provide to market#1
        // Δdebt₃  = remaining debt * 35%   = 246.04
        // Δdebt₃' = (Δdebt₃ * 101%) * 110% = 246.04 * 101% * 110% = 273.35

        // 3. provide to market#2
        // Δdebt₄  = remaining debt * 40%   = 281.19
        // Δdebt₄' = (Δdebt₄ * 101%) * 110% = 281.19 * 101% * 110% = 312.4

        // Δdebt  = Σ Δdebtᵢ  = 246.04 + 281.19 = 527.23
        // Δdebt' = Σ Δdebtᵢ' = 273.35 + 312.4  = 585.75

        // factor = Δdebt' / Δdebt
        //        = 585.75 / 527.23
        //        = 111.1% <= 112%

        assertApproxEqAbs(asset.balanceOf(address(this)), 8.24e18, 1e16);
        assertApproxEqAbs(pool.debtOf(markets[0], borrower_A), 1000e18 - 824.26e18, 1e16);
        assertApproxEqAbs(pool.debtOf(markets[1], borrower_A), 246.04e18 + 24.85e18 + 2.46e18, 1e16);
        assertApproxEqAbs(pool.debtOf(markets[2], borrower_A), 281.19e18 + 28.4e18  + 2.81e18, 1e16);
        assertEq(pool.balanceOf(borrower_A), 0);
        assertEq(asset.balanceOf(borrower_A), 0);
    }
}



contract TestCreditPool_keeper_dust is KeeperHelpers {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.liquidationGracePeriod = 0;

        params.marketsConfig.active[0] = 5;
        params.marketsConfig.active[1] = 5;
        params.marketsConfig.active[2] = 5;
    }

    function test_rollover_three_markets_moves_two_wei_remainder_to_last_market() public {
        _set_max_rollover_factor(UNIT * 20 / 100);

        _set_debt(1000e18);
        _set_collateral(2020e18 + 2);

        skip(YEAR);
        priceOracle.touch();

        _set_provide_order(markets[1], 0, 400e18);
        _set_provide_order(markets[2], 0, 400e18);
        _set_provide_order(markets[3], 0, 500e18);

        _add_reborrow(markets[1], UNIT * 30 / 100);
        _add_reborrow(markets[2], UNIT * 30 / 100);
        _add_reborrow(markets[3], UNIT * 40 / 100);

        RolloverSolution memory solution;
        solution.reborrows = new ReborrowSolution[](_reborrows.length);
        for (uint256 i = 0; i < _reborrows.length; i++) {
            solution.reborrows[i] = _reborrows[i];
        }

        _rollover_extension(address(pool), markets[0], borrower_A, address(this), KEEPER_FEE, solution);
        _withdraw_rollover_fee(address(this));

        uint256 totalCollateral = pool.collateralOf(markets[0], borrower_A)
            + pool.collateralOf(markets[1], borrower_A)
            + pool.collateralOf(markets[2], borrower_A)
            + pool.collateralOf(markets[3], borrower_A);

        // (2020e18 + 2) * [303, 303, 404] / 1010 floors to [606e18, 606e18, 808e18],
        // and the 2 wei remainder must be assigned to the last market.
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[1], borrower_A), 606e18);
        assertEq(pool.collateralOf(markets[2], borrower_A), 606e18);
        assertEq(pool.collateralOf(markets[3], borrower_A), 808e18 + 2);
        assertEq(totalCollateral, 2020e18 + 2);
        assertEq(collateral.balanceOf(address(pool)), totalCollateral);
    }

    function test_rollover_four_markets_moves_three_wei_remainder_to_last_market() public {
        _set_max_rollover_factor(UNIT * 20 / 100);

        _set_debt(500e18);
        _set_collateral(2020e18 + 3);

        _set_provide_order(markets[1], 0, 200e18);
        _set_provide_order(markets[2], 0, 200e18);
        _set_provide_order(markets[3], 0, 200e18);
        _set_provide_order(markets[4], 0, 200e18);

        _add_reborrow(markets[1], UNIT * 25 / 100);
        _add_reborrow(markets[2], UNIT * 25 / 100);
        _add_reborrow(markets[3], UNIT * 25 / 100);
        _add_reborrow(markets[4], UNIT * 25 / 100);

        _execute();

        uint256 totalCollateral = pool.collateralOf(markets[0], borrower_A)
            + pool.collateralOf(markets[1], borrower_A)
            + pool.collateralOf(markets[2], borrower_A)
            + pool.collateralOf(markets[3], borrower_A)
            + pool.collateralOf(markets[4], borrower_A);

        // (2020e18 + 3) * [126.25, 126.25, 126.25, 126.25] / 505 floors the first three legs,
        // so the 3 wei remainder must be assigned to the last market.
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[1], borrower_A), 505e18);
        assertEq(pool.collateralOf(markets[2], borrower_A), 505e18);
        assertEq(pool.collateralOf(markets[3], borrower_A), 505e18);
        assertEq(pool.collateralOf(markets[4], borrower_A), 505e18 + 3);
        assertEq(totalCollateral, 2020e18 + 3);
        assertEq(collateral.balanceOf(address(pool)), totalCollateral);
    }

    function test_rollover_three_markets_moves_two_wei_debt_remainder_to_last_market() public {
        _set_max_rollover_factor(UNIT * 20 / 100);

        _set_debt(1010e18 + 2);

        skip(YEAR);
        priceOracle.touch();

        _set_provide_order(markets[1], 0, 400e18);
        _set_provide_order(markets[2], 0, 400e18);
        _set_provide_order(markets[3], 0, 500e18);

        _add_reborrow(markets[1], UNIT * 30 / 100);
        _add_reborrow(markets[2], UNIT * 30 / 100);
        _add_reborrow(markets[3], UNIT * 40 / 100);

        RolloverSolution memory solution;
        solution.reborrows = new ReborrowSolution[](_reborrows.length);
        for (uint256 i = 0; i < _reborrows.length; i++) {
            solution.reborrows[i] = _reborrows[i];
        }

        _rollover_extension(address(pool), markets[0], borrower_A, address(this), KEEPER_FEE, solution);
        _withdraw_rollover_fee(address(this));

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[1], borrower_A), 306.03e18);
        assertEq(pool.debtOf(markets[2], borrower_A), 306.03e18);
        assertEq(pool.debtOf(markets[3], borrower_A), 408.04e18 + 3);
        assertEq(asset.balanceOf(address(this)), 10.1e18 + 1);
    }

    function test_cant_rollover_when_reborrow_percent_exceeds_unit() public {
        _set_max_rollover_factor(UNIT * 20 / 100);

        _set_debt(100e18);
        _set_pool_balance(25e18);
        _set_account_balance(25e18);
        _mature(0);

        _set_provide_order(markets[1], 0, 100e18);
        _set_provide_order(markets[2], 0, 100e18);

        _add_reborrow(markets[1], UNIT * 60 / 100);
        _add_reborrow(markets[2], UNIT * 50 / 100);

        _rollover(abi.encodeWithSelector(RolloverDebtPercentExceeded.selector, UNIT * 110 / 100, UNIT));

        assertEq(pool.debtOf(markets[0], borrower_A), 100e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 0);
        assertEq(pool.debtOf(markets[2], borrower_A), 0);
        assertEq(pool.loanOf(markets[1], provider_A), 0);
        assertEq(pool.loanOf(markets[2], provider_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 500e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 0);
        assertEq(pool.collateralOf(markets[2], borrower_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[1], 0, provider_A), 100e18);
        assertEq(pool.getProvideOrderBalance(markets[2], 0, provider_A), 100e18);
        assertEq(pool.getAvailableToClaim(markets[0]), 25e18);
        assertEq(pool.balanceOf(borrower_A), 25e18);
        assertEq(asset.balanceOf(borrower_A), 25e18);
        assertEq(rolloverExtension.getCollectedFee(address(asset), address(this)), 0);
        assertEq(asset.balanceOf(address(rolloverExtension)), 0);
    }

    function test_fuzz_full_rollover_reborrow_clears_source_dust(
        uint256 rawPercentA,
        uint256 rawPercentB,
        uint8 debtDust,
        uint8 collateralDust
    ) public {
        _set_max_rollover_factor(UNIT * 20 / 100);

        uint256 percentA = bound(rawPercentA, 1, UNIT - 2);
        uint256 percentB = bound(rawPercentB, 1, UNIT - percentA - 1);
        uint256 percentC = UNIT - percentA - percentB;

        uint128 debt = 1000e18 + debtDust;
        uint128 collateralAmount = debt * 4 + collateralDust;
        uint256 minReborrowDebt = Math.mulDiv(MIN_AMOUNT, UNIT, UNIT * 101 / 100, Math.Rounding.Floor);

        uint256 debtA = Math.mulDiv(debt, percentA, UNIT, Math.Rounding.Floor);
        uint256 debtB = Math.mulDiv(debt, percentB, UNIT, Math.Rounding.Floor);
        uint256 debtC = debt - debtA - debtB;

        vm.assume(debtA >= minReborrowDebt);
        vm.assume(debtB >= minReborrowDebt);
        vm.assume(debtC >= minReborrowDebt);

        _set_debt(debt);
        _set_collateral(collateralAmount);

        _set_provide_order(markets[1], 0, debt * 2);
        _set_provide_order(markets[2], 0, debt * 2);
        _set_provide_order(markets[3], 0, debt * 2);

        _add_reborrow(markets[1], percentA);
        _add_reborrow(markets[2], percentB);
        _add_reborrow(markets[3], percentC);

        _execute();

        uint256 totalCollateral = pool.collateralOf(markets[0], borrower_A)
            + pool.collateralOf(markets[1], borrower_A)
            + pool.collateralOf(markets[2], borrower_A)
            + pool.collateralOf(markets[3], borrower_A);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(totalCollateral, collateralAmount);
    }
}

contract TestCreditPool_split_rollover is KeeperHelpers {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.liquidationGracePeriod = 0;
    }

    function beforeEach() public override {
        _set_max_rollover_factor(UNIT * 20 / 100);
        _set_debt(1000e18);
        _set_provide_order(markets[1], 10, 1000000e18);
        _mature(0);

        assertEq(pool.collateralOf(markets[0], borrower_A), 4000e18);
    }

    function test_single_rollover() public {
        _add_reborrow(markets[1], UNIT * 40 / 100);
        _rollover();

        assertEq(pool.debtOf(markets[0], borrower_A), 600e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 444.4e18);
        assertApproxEqAbs(pool.collateralOf(markets[0], borrower_A), 2298e18, 1e17); // 4000 / (600 + 400 * 101% * 110%) * 600
        assertApproxEqAbs(pool.collateralOf(markets[1], borrower_A), 1702e18, 1e17); // 4000 / (600 + 400 * 101% * 110%) * (400 * 101% * 110%)
    }

    function test_two_rollovers() public {
        _add_reborrow(markets[1], UNIT * 20 / 100);
        _rollover();

        assertEq(pool.debtOf(markets[0], borrower_A), 800e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 222.2e18);
        assertApproxEqAbs(pool.collateralOf(markets[0], borrower_A), 3130.5e18, 1e17); // 4000 / (800 + 200 * 101% * 110%) * 800
        assertApproxEqAbs(pool.collateralOf(markets[1], borrower_A),  869.5e18, 1e17); // 4000 / (800 + 200 * 101% * 110%) * (200 * 101% * 110%)

        _add_reborrow(markets[1], UNIT * 25 / 100);
        _rollover();

        assertEq(pool.debtOf(markets[0], borrower_A), 600e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 444.4e18);
        assertApproxEqAbs(pool.collateralOf(markets[0], borrower_A), 2284.5e18, 1e17); // 3130.5e18 / (600 + 200 * 101% * 110%) * 600
        assertApproxEqAbs(pool.collateralOf(markets[1], borrower_A), 1715.5e18, 1e17); // 3130.5e18 / (600 + 200 * 101% * 110%) * (200 * 101% * 110%) + old
    }

    function test_by_0_1_percent() public {
        // D  - initial debt
        // p  - first percent to reborrow
        // p' - second percent to reborrow
        //
        // D * (1 - p) * p' = D * p
        // (1 - p) * p' = p
        // p' = p / (1 - p)

        uint256 p = UNIT / 1000;
        for (uint i = 0; i < 400; ++i) {
            _add_reborrow(markets[1], p);
            _rollover();

            p = p.mulDiv(UNIT, UNIT - p, Math.Rounding.Ceil);
        }

        assertApproxEqAbs(pool.debtOf(markets[0], borrower_A), 600e18,   1e16);
        assertApproxEqAbs(pool.debtOf(markets[1], borrower_A), 444.4e18, 1e16);
        assertApproxEqAbs(pool.collateralOf(markets[0], borrower_A), 2267.8e18, 1e17);
        assertApproxEqAbs(pool.collateralOf(markets[1], borrower_A), 1732.2e18, 1e17);
    }
}



contract TestCreditPool_keeper_dutch_without_reborrow is KeeperHelpers {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.liquidationGracePeriod = 1 days;
    }

    function beforeEach() public override {
        super.beforeEach();

        _set_max_rollover_factor(0);
        _set_debt(1000e18);
        _set_pool_balance(1010e18); 
    }

    // can be covered immediately
    function test_reborrow_at_t0() public {
        _execute();
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
    }
}



contract TestCreditPool_keeper_dutch_with_reborrow is KeeperHelpers {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.liquidationGracePeriod = 1 days;
    }

    function beforeEach() public override {
        super.beforeEach();

        _set_max_rollover_factor(UNIT * 20 / 100);
        _set_debt(1000e18);
        _set_provide_order(markets[1], 10, 2000e18);
        _add_reborrow(markets[1], UNIT);
    }

    function test_reborrow_at_t0() public {
        _execute(0, abi.encodeWithSelector(MaxRolloverFactorExceeded.selector,
            111000000000000000,
            0
        ));
    }

    function test_reborrow_at_t1() public {
        _execute(12 hours, abi.encodeWithSelector(MaxRolloverFactorExceeded.selector,
            110861643835616438,
            100000000000000000
        ));
    }

    function test_reborrow_at_t2() public {
        _execute(12.7 hours, abi.encodeWithSelector(MaxRolloverFactorExceeded.selector,
            110853573059360730,
            105833333333333334
        ));
    }

    // can't be covered until 13.4h after maturity
    function test_reborrow_at_t3() public {
        _execute(13.4 hours, "");
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
    }
}
