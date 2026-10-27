// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Vm } from "lib/forge-std/src/Vm.sol";

import { CreditPoolTestSuite } from "./0_base.t.sol";
import { IPermit2 } from "lib/permit2/src/interfaces/IPermit2.sol";

import { ICreditPool } from "src/interfaces/ICreditPool.sol";
import { ICreditPoolFactory } from "src/interfaces/ICreditPoolFactory.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { CreditPoolRolloverExtension } from "src/CreditPoolRolloverExtension.sol";

contract TestCreditPool_rollover_extension is CreditPoolTestSuite {
    uint256 internal constant KEEPER_FEE = UNIT / 100;

    function reconfigure(InitializationParams memory params) internal pure override {
        params.liquidationGracePeriod = 0;
        params.marketsConfig.active[0] = 5;
        params.marketsConfig.active[1] = 5;
        params.marketsConfig.active[2] = 5;
    }

    function test_required_actions_and_description() public view {
        assertEq(
            rolloverExtension.requiredActions(),
            DELEGATE_CLAIM | DELEGATE_REPAY | DELEGATE_OFFSET | DELEGATE_WITHDRAW | DELEGATE_BORROW | DELEGATE_MOVE_COLLATERAL
        );
        assertEq(rolloverExtension.description(), "CreditPool rollover extension");
    }

    function test_constructor_stores_permit2_and_factory() public view {
        assertEq(address(rolloverExtension.PERMIT2()), address(permit2));
        assertEq(address(rolloverExtension.FACTORY()), address(rolloverFactory));
    }

    function test_constructor_reverts_for_invalid_permit2() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidPermit2.selector, address(0)));
        new CreditPoolRolloverExtension(IPermit2(address(0)), rolloverFactory);
    }

    function test_constructor_reverts_for_non_contract_permit2() public {
        address invalidPermit2 = makeAddr("Invalid Permit2");

        vm.expectRevert(abi.encodeWithSelector(InvalidPermit2.selector, invalidPermit2));
        new CreditPoolRolloverExtension(IPermit2(invalidPermit2), rolloverFactory);
    }

    function test_constructor_reverts_for_invalid_factory() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidFactory.selector, address(0)));
        new CreditPoolRolloverExtension(permit2, ICreditPoolFactory(address(0)));
    }

    function test_constructor_reverts_for_non_contract_factory() public {
        address invalidFactory = makeAddr("Invalid Factory");

        vm.expectRevert(abi.encodeWithSelector(InvalidFactory.selector, invalidFactory));
        new CreditPoolRolloverExtension(permit2, ICreditPoolFactory(invalidFactory));
    }

    function test_set_get_and_revoke_config() public {
        vm.expectEmit(true, true, true, true, address(rolloverExtension));
        emit RolloverConfigUpdated(address(pool), borrower_A, markets[0], true, UNIT / 2, KEEPER_FEE);
        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, UNIT / 2, KEEPER_FEE);

        (bool enabled, uint256 maxDebtFactor, uint256 keeperFee) =
            rolloverExtension.getRolloverConfig(address(pool), markets[0], borrower_A);
        assertEq(enabled, true);
        assertEq(maxDebtFactor, UNIT / 2);
        assertEq(keeperFee, KEEPER_FEE);

        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], false, 0, 0);

        (enabled, maxDebtFactor, keeperFee) = rolloverExtension.getRolloverConfig(address(pool), markets[0], borrower_A);
        assertEq(enabled, false);
        assertEq(maxDebtFactor, 0);
        assertEq(keeperFee, 0);
    }

    function test_min_keeper_fee_below_config_uses_config_fee() public {
        address feeRecipient = makeAddr("Fee Recipient");
        _set_max_rollover_factor(0, KEEPER_FEE);
        _set_debt(1000e18);
        _set_pool_balance(1010e18);
        _mature();

        RolloverSolution memory solution;
        _rollover_extension(address(pool), markets[0], borrower_A, feeRecipient, KEEPER_FEE / 2, solution);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(rolloverExtension.getCollectedFee(address(asset), feeRecipient), 10e18);
    }

    function test_min_keeper_fee_above_config_reverts() public {
        address feeRecipient = makeAddr("Fee Recipient");
        _set_max_rollover_factor(0, KEEPER_FEE);
        _set_debt(1000e18);
        _set_pool_balance(1010e18);
        _mature();

        RolloverSolution memory solution;
        vm.expectRevert(abi.encodeWithSelector(KeeperFeeTooHigh.selector, KEEPER_FEE, KEEPER_FEE + 1));
        _rollover_extension(address(pool), markets[0], borrower_A, feeRecipient, KEEPER_FEE + 1, solution);
    }

    function test_withdraw_fee_partial_max_and_recipient_isolation() public {
        address feeRecipient = makeAddr("Fee Recipient");
        address otherRecipient = makeAddr("Other Recipient");
        _set_max_rollover_factor(0, KEEPER_FEE);
        _set_debt(1000e18);
        _set_pool_balance(1010e18);
        _mature();

        RolloverSolution memory solution;
        _rollover_extension(address(pool), markets[0], borrower_A, feeRecipient, KEEPER_FEE, solution);

        assertEq(rolloverExtension.getCollectedFee(address(asset), feeRecipient), 10e18);
        assertEq(rolloverExtension.getCollectedFee(address(asset), otherRecipient), 0);

        vm.expectRevert(abi.encodeWithSelector(InvalidFeeAmount.selector, 1e18, 0));
        vm.prank(otherRecipient); rolloverExtension.withdrawFee(address(asset), otherRecipient, 1e18);

        vm.prank(feeRecipient); rolloverExtension.withdrawFee(address(asset), feeRecipient, 4e18);
        assertEq(asset.balanceOf(feeRecipient), 4e18);
        assertEq(rolloverExtension.getCollectedFee(address(asset), feeRecipient), 6e18);

        vm.prank(feeRecipient); rolloverExtension.withdrawFee(address(asset), feeRecipient, type(uint128).max);
        assertEq(asset.balanceOf(feeRecipient), 10e18);
        assertEq(rolloverExtension.getCollectedFee(address(asset), feeRecipient), 0);
    }

    function test_delegate_revocation_blocks_rollover() public {
        _set_max_rollover_factor(0, KEEPER_FEE);
        _set_debt(1000e18);
        _set_pool_balance(1010e18);
        _mature();

        vm.prank(borrower_A); pool.setDelegate(address(rolloverExtension), 0);

        RolloverSolution memory solution;
        vm.expectRevert(abi.encodeWithSelector(DelegateNotApproved.selector, borrower_A, address(rolloverExtension), DELEGATE_REPAY));
        _rollover_extension(address(pool), markets[0], borrower_A, address(this), KEEPER_FEE, solution);
    }

    function test_rollover_rechecks_pool_registration() public {
        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, 0, KEEPER_FEE);
        rolloverFactory.setPool(address(pool), false);

        RolloverSolution memory solution;
        vm.expectRevert(abi.encodeWithSelector(InvalidPool.selector, address(pool)));
        _rollover_extension(address(pool), markets[0], borrower_A, address(this), KEEPER_FEE, solution);
    }

    function test_refinance_debts_requires_delegated_actions() public {
        _set_debt(1000e18);
        _set_provide_order(markets[1], 0, 2000e18);
        _mature();

        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](1);
        refinances[0] = RefinanceDebtParams({
            toMarket: markets[1],
            debtToRepay: 1000e18,
            assetsToBorrow: 1010e18
        });

        vm.expectRevert(abi.encodeWithSelector(
            DelegateNotApproved.selector,
            borrower_A,
            address(this),
            DELEGATE_BORROW | DELEGATE_REPAY | DELEGATE_MOVE_COLLATERAL
        ));
        pool.refinanceDebts(borrower_A, markets[0], type(uint256).max, refinances);
    }

    function test_refinance_debts_uses_one_oracle_snapshot() public {
        _set_debt(1000e18);
        _set_provide_order(markets[1], 0, 1000e18);
        _set_provide_order(markets[2], 0, 1000e18);
        _mature();

        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](2);
        refinances[0] = RefinanceDebtParams({
            toMarket: markets[1],
            debtToRepay: 500e18,
            assetsToBorrow: 505e18
        });
        refinances[1] = RefinanceDebtParams({
            toMarket: markets[2],
            debtToRepay: 500e18,
            assetsToBorrow: 505e18
        });

        vm.prank(borrower_A); pool.setDelegate(address(this), DELEGATE_BORROW | DELEGATE_REPAY | DELEGATE_MOVE_COLLATERAL);
        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 1);
        vm.recordLogs();
        RefinanceDebtResult[] memory results = pool.refinanceDebts(borrower_A, markets[0], UNIT / 100, refinances);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());

        assertEq(logs.length, 5);
        _assert_yield_index(logs[0]);
        _assert_refinance_leg(logs, 1, 3, markets[1], 500e18, 505e18, 505e18, 1999999999999999999980, 0);
        _assert_refinance_leg(logs, 2, 4, markets[2], 500e18, 505e18, 505e18, 2000000000000000000020, 0);
        assertEq(results.length, 2);
        assertEq(results[0].newDebt, 505e18);
        assertEq(results[0].collateralMoved, 1999999999999999999980);
        assertEq(results[1].newDebt, 505e18);
        assertEq(results[1].collateralMoved, 2000000000000000000020);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[1], borrower_A), 505e18);
        assertEq(pool.debtOf(markets[2], borrower_A), 505e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[1], borrower_A), 1999999999999999999980);
        assertEq(pool.collateralOf(markets[2], borrower_A), 2000000000000000000020);
        assertEq(pool.balanceOf(borrower_A), 10e18);
    }

    function test_refinance_emits_borrowed_with_interest_before_debt_refinanced() public {
        _set_debt(1000e18);
        _set_provide_order(markets[1], 10, 2000e18);
        _mature();
        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](1);
        refinances[0] = RefinanceDebtParams(markets[1], 1000e18, 1010e18);

        vm.recordLogs();
        vm.prank(borrower_A); RefinanceDebtResult[] memory results = pool.refinanceDebts(borrower_A, markets[0], UNIT / 5, refinances);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());

        assertEq(logs.length, 3);
        _assert_yield_index(logs[0]);
        _assert_refinance_leg(logs, 1, 2, markets[1], 1000e18, 1010e18, 1111e18, 4000e18, 1000);
        assertEq(results[0].newDebt, 1111e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[1], borrower_A), 1111e18);
        assertEq(pool.balanceOf(borrower_A), 10e18);
    }

    function test_refinance_emits_executions_before_summaries_for_repeated_target_market() public {
        _set_debt(1000e18);
        _set_provide_order(markets[1], 0, 2000e18);
        _mature();
        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](2);
        refinances[0] = RefinanceDebtParams(markets[1], 500e18, 505e18);
        refinances[1] = RefinanceDebtParams(markets[1], 500e18, 505e18);

        vm.recordLogs();
        vm.prank(borrower_A); RefinanceDebtResult[] memory results = pool.refinanceDebts(borrower_A, markets[0], UNIT / 100, refinances);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());

        assertEq(logs.length, 5);
        _assert_yield_index(logs[0]);
        _assert_refinance_leg(logs, 1, 3, markets[1], 500e18, 505e18, 505e18, 1999999999999999999980, 0);
        _assert_refinance_leg(logs, 2, 4, markets[1], 500e18, 505e18, 505e18, 2000000000000000000020, 0);
        assertEq(results[0].newDebt, 505e18);
        assertEq(results[1].newDebt, 505e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 1010e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 4000e18);
    }

    function test_rollover_emits_refinance_before_extension_events() public {
        address feeRecipient = makeAddr("Refinance Fee Recipient");
        _set_max_rollover_factor(UNIT / 100, KEEPER_FEE);
        _set_debt(1000e18);
        _set_provide_order(markets[1], 0, 2000e18);
        _mature();
        RolloverSolution memory solution;
        solution.reborrows = new ReborrowSolution[](1);
        solution.reborrows[0] = ReborrowSolution(markets[1], UNIT);

        vm.recordLogs();
        _rollover_extension(address(pool), markets[0], borrower_A, feeRecipient, KEEPER_FEE, solution);
        Vm.Log[] memory allLogs = vm.getRecordedLogs();
        Vm.Log[] memory logs = _pool_logs(allLogs);

        assertEq(logs.length, 4);
        _assert_yield_index(logs[0]);
        _assert_refinance_leg(logs, 1, 2, markets[1], 1000e18, 1010e18, 1010e18, 4000e18, 0);
        assertEq(logs[3].topics[0], AssetsWithdrawn.selector);
        uint256 extensionEvents;
        bool refinanceSeen;
        for (uint256 i; i < allLogs.length; ++i) {
            if (allLogs[i].emitter == address(pool) && allLogs[i].topics[0] == keccak256("DebtRefinanced(address,uint64,uint64,uint128,uint128)")) {
                refinanceSeen = true;
            }
            if (allLogs[i].emitter != address(rolloverExtension)) continue;
            assertEq(refinanceSeen, true);
            if (extensionEvents == 0) {
                assertEq(allLogs[i].topics[0], DebtRolledOver.selector);
                assertEq(allLogs[i].data, abi.encode(markets[1], uint128(1000e18), uint128(1010e18), uint128(4000e18), uint128(10e18)));
            }
            ++extensionEvents;
        }
        assertEq(extensionEvents, 3);
        assertEq(pool.debtOf(markets[1], borrower_A), 1010e18);
        assertEq(pool.balanceOf(borrower_A), 0);
        assertEq(rolloverExtension.getCollectedFee(address(asset), feeRecipient), 10e18);
    }

    function test_refinance_empty_array_emits_no_events() public {
        _set_debt(1000e18);
        _mature();
        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](0);

        vm.recordLogs();
        vm.prank(borrower_A); RefinanceDebtResult[] memory results = pool.refinanceDebts(borrower_A, markets[0], 0, refinances);

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(results.length, 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 1000e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 4000e18);
    }

    function test_refinance_debt_factor_failure_rolls_back_execution() public {
        _set_debt(1000e18);
        _set_provide_order(markets[1], 0, 2000e18);
        _mature();
        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](1);
        refinances[0] = RefinanceDebtParams(markets[1], 1000e18, 1010e18);

        vm.expectRevert(abi.encodeWithSelector(MaxRolloverFactorExceeded.selector, UNIT / 100, 0));
        vm.prank(borrower_A); pool.refinanceDebts(borrower_A, markets[0], 0, refinances);

        assertEq(pool.debtOf(markets[0], borrower_A), 1000e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 4000e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 0);
        assertEq(pool.balanceOf(borrower_A), 0);
        // The untouched provide order has earned 10% underlying yield over the elapsed year.
        assertEq_(pool.getProvideOrderBalance(markets[1], 0, provider_B), 2200e18);
    }

    function _pool_logs(Vm.Log[] memory logs) private view returns (Vm.Log[] memory poolLogs) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool)) ++count;
        }
        poolLogs = new Vm.Log[](count);
        count = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool)) poolLogs[count++] = logs[i];
        }
    }

    function _assert_yield_index(Vm.Log memory entry) private pure {
        assertEq(entry.topics[0], UnderlyingPoolIndexUpdated.selector);
        assertEq(entry.data, abi.encode(uint256(1.1e27), uint64(0)));
    }

    function _assert_refinance_leg(
        Vm.Log[] memory logs,
        uint256 index,
        uint256 summaryIndex,
        uint64 toMarket,
        uint128 debtRepaid,
        uint128 assetsBorrowed,
        uint128 newDebt,
        uint128 collateralMoved,
        uint256 endAPR
    ) private view {
        assertEq(logs[index].topics.length, 3);
        assertEq(logs[index].topics[0], Borrowed.selector);
        assertEq(logs[index].topics[1], bytes32(uint256(uint160(borrower_A))));
        assertEq(logs[index].topics[2], bytes32(uint256(toMarket)));
        assertEq(logs[index].data, abi.encode(assetsBorrowed, newDebt, endAPR));
        assertEq(logs[summaryIndex].topics.length, 4);
        assertEq(logs[summaryIndex].topics[0], keccak256("DebtRefinanced(address,uint64,uint64,uint128,uint128)"));
        assertEq(logs[summaryIndex].topics[1], bytes32(uint256(uint160(borrower_A))));
        assertEq(logs[summaryIndex].topics[2], bytes32(uint256(markets[0])));
        assertEq(logs[summaryIndex].topics[3], bytes32(uint256(toMarket)));
        assertEq(logs[summaryIndex].data, abi.encode(debtRepaid, collateralMoved));
    }

    function test_move_collateral_requires_delegated_action() public {
        _set_debt(1000e18);
        _mature();

        vm.expectRevert(abi.encodeWithSelector(
            DelegateNotApproved.selector,
            borrower_A,
            address(this),
            DELEGATE_MOVE_COLLATERAL
        ));
        pool.moveCollateral(borrower_A, markets[0], markets[1], 40e18);
    }

    function test_move_collateral_moves_balance_and_checks_only_source_health() public {
        _set_debt(1000e18);
        _mature();

        vm.prank(borrower_A); pool.setDelegate(address(this), DELEGATE_MOVE_COLLATERAL);
        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 1);
        vm.expectEmit(true, true, true, true, address(pool));
        emit CollateralMoved(borrower_A, markets[0], markets[1], 40e18);
        pool.moveCollateral(borrower_A, markets[0], markets[1], 40e18);

        assertEq(pool.debtOf(markets[0], borrower_A), 1000e18);
        assertEq(pool.debtOf(markets[1], borrower_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 3960e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 40e18);
        assertEq(pool.balanceOf(borrower_A), 0);
    }

    function test_move_collateral_allows_active_markets_and_unhealthy_target() public {
        _set_debt(1000e18);
        _deposit_collateral(borrower_A, markets[0], 2000e18);
        _set_provide_order(markets[1], 0, 100e18);
        _deposit_collateral(borrower_A, markets[1], 400e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[1], 100e18, 100e18);
        priceOracle.setPrice(0.4e18);

        vm.prank(borrower_A); pool.moveCollateral(borrower_A, markets[0], markets[1], 10e18);

        assertEq(pool.collateralOf(markets[0], borrower_A), 5990e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 410e18);
        assertEq(pool.getHealthFactor(markets[1], borrower_A), 0.82e18);
    }

    function test_move_collateral_reverts_when_source_would_be_unhealthy() public {
        _set_debt(1000e18);
        _mature();

        vm.prank(borrower_A); pool.setDelegate(address(this), DELEGATE_MOVE_COLLATERAL);
        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 0.5e18));
        pool.moveCollateral(borrower_A, markets[0], markets[1], 3000e18);

        assertEq(pool.collateralOf(markets[0], borrower_A), 4000e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 0);
    }

    function test_move_collateral_rejects_same_market() public {
        _deposit_collateral(borrower_A, markets[0], 40e18);

        vm.expectRevert(abi.encodeWithSelector(InvalidCollateralMove.selector, markets[0], markets[0]));
        vm.prank(borrower_A); pool.moveCollateral(borrower_A, markets[0], markets[0], 40e18);
    }

    function test_multicall_no_debt_move_does_not_load_stale_oracle() public {
        _deposit_collateral(borrower_A, markets[0], 40e18);
        skip(24 hours);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(ICreditPool.moveCollateral, (
            borrower_A,
            markets[0],
            markets[1],
            type(uint128).max
        ));
        vm.prank(borrower_A); pool.multicall(calls);

        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[1], borrower_A), 40e18);
    }

    function test_nested_multicall_reuses_snapshot_and_next_multicall_loads_fresh_price() public {
        _set_provide_order(markets[1], 0, 30e18);
        _deposit_collateral(borrower_A, markets[1], 120e18);

        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = abi.encodeCall(ICreditPool.borrow, (
            borrower_A,
            markets[1],
            10e18,
            10e18
        ));
        bytes[] memory outerCalls = new bytes[](2);
        outerCalls[0] = abi.encodeCall(ICreditPool.multicall, (innerCalls));
        outerCalls[1] = innerCalls[0];

        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 2);
        vm.prank(borrower_A); pool.multicall(outerCalls);

        priceOracle.setPrice(0.5e18);
        bytes[] memory nextCalls = new bytes[](1);
        nextCalls[0] = innerCalls[0];
        vm.prank(borrower_A); pool.multicall(nextCalls);

        assertEq(pool.debtOf(markets[1], borrower_A), 30e18);
    }

    function _set_max_rollover_factor(uint256 factor, uint256 keeperFee) internal {
        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, factor, keeperFee);
        _approve_rollover_extension(borrower_A);
    }

    function _set_debt(uint128 amount) internal {
        _deposit(provider_A, amount);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, amount);
        _deposit_collateral(borrower_A, markets[0], amount * 4);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], amount, type(uint128).max);
        _withdraw_and_burn(borrower_A, amount);
        assertEq(pool.debtOf(markets[0], borrower_A), amount);
    }

    function _set_pool_balance(uint128 amount) internal {
        _deposit_collateral(borrower_A, markets[0], amount * 4);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, amount);
        _deposit(provider_B, amount);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], amount, 0, 10);
        _deposit(borrower_A, amount);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], amount);
        assertEq(pool.balanceOf(borrower_A), amount);
    }

    function _set_provide_order(uint64 market, uint256 APR, uint128 amount) internal {
        _deposit(provider_B, amount);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, APR * APR_PERCENT, amount);
    }

    function _mature() internal {
        skip(YEAR);
        priceOracle.touch();
    }
}
