// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Vm } from "lib/forge-std/src/Vm.sol";

import { CreditPoolTestSuite } from "./0_base.t.sol";

// All examples have one year remaining. A = borrowed cash, D = gross debt, S = A-X0.
// With f = 20%: v = f*D / ((1-f)*A + f*D). For a fee fill at APR r:
// Y = v*S / (1+r*(1-v)), K = Y*(1+r); reward = S-Y; owner loan = (D-A)*f+K.
// The chosen inputs make v, Y and K exact in the contract's integer arithmetic.
contract Test_sweep is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT / 5; // 20%
    }

    function test_little_overlap() public {
        _place_provide_order(markets[0], provider_B, 20 * APR_PERCENT, 1000e18);
        _place_provide_order(markets[0], provider_A, 12 * APR_PERCENT, 5000e18);
    // --------------------------------------------|-----------------|------- //
        _place_borrow_order(markets[0],  borrower_A, 20 * APR_PERCENT, 3000e18);
        _place_borrow_order(markets[0],  borrower_B, 10 * APR_PERCENT, 1000e18);

        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 2775e18, 10);
        // D = 2775*1.12 = 3108; X0 = 3108/1.20 = 2590; S = 185; first fee = 333*20% = 66.6.
        // v = 0.2*1.12/(0.8+0.2*1.12) = 7/32; Y = (7/32)*185/(1+0.20*25/32) = 35.
        // K = 35*1.20 = 42; reward = 185-35 = 150; owner loan = 66.6+42 = 108.6.
        _assert_sweeper_state(provider_C, 150e18, 108.6e18);

        // Lender loan = 3108-66.6; borrower debt = 3108+42; borrowed cash = 2590+35.
        assertEq(pool.loanOf(markets[0], provider_A), 3041.4e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 3150e18);
        assertEq(pool.balanceOf(borrower_A), 2625e18);

        // Remaining provide = 5000-2775 = 2225; remaining borrow = 3000-2590-35 = 375.
        assertEq(pool.getProvideOrderBalance(markets[0], 20 * APR_PERCENT, provider_B), 1000e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 12 * APR_PERCENT, provider_A), 2225e18);
    // ------------------------------------------------|-----------------|------------|------- //
        assertEq(pool.getBorrowOrderBalance(markets[0],  20 * APR_PERCENT, borrower_A),  375e18);
        assertEq(pool.getBorrowOrderBalance(markets[0],  10 * APR_PERCENT, borrower_B), 1000e18);
    }

    function test_little_overlap_own_orders() public {
        _place_provide_order(markets[0], provider_B, 20 * APR_PERCENT, 1000e18);
        _place_provide_order(markets[0], provider_A, 12 * APR_PERCENT, 5000e18);
    // --------------------------------------------|-----------------|------- //
        _place_borrow_order(markets[0],  provider_A, 20 * APR_PERCENT, 3000e18);
        _place_borrow_order(markets[0],  borrower_B, 10 * APR_PERCENT, 1000e18);

        vm.prank(provider_A); pool.sweep(provider_A, markets[0], 2775e18, 10);
        // D = 2775*1.12 = 3108; X0 = 3108/1.20 = 2590; S = 185; first fee = 333*20% = 66.6.
        // v = 0.2*1.12/(0.8+0.2*1.12) = 7/32; Y = (7/32)*185/(1+0.20*25/32) = 35.
        // K = 35*1.20 = 42; reward = 185-35 = 150; owner loan = 66.6+42 = 108.6.
        assertEq(asset.balanceOf(provider_A), 0);
        // Lender loan = 3108-66.6; borrower debt = 3108+42; borrowed cash = 2590+35.
        assertEq(pool.loanOf(markets[0], provider_A), 3041.4e18);
        assertEq(pool.debtOf(markets[0], provider_A), 3150e18);
        // This account also receives the reward: 2590+35+150 = 2775.
        assertEq(pool.balanceOf(provider_A), 2775e18);
        assertEq(pool.balanceOf(address(this)), 0);
        assertEq(pool.loanOf(markets[0], address(this)), 108.6e18);

        vm.prank(provider_A); pool.offset(provider_A, markets[0], type(uint128).max);
        vm.prank(provider_A); pool.withdraw(provider_A, provider_A, type(uint128).max);
        assertEq(asset.balanceOf(provider_A), 2775e18);

        // Remaining provide = 5000-2775 = 2225; remaining borrow = 3000-2590-35 = 375.
        assertEq(pool.getProvideOrderBalance(markets[0], 20 * APR_PERCENT, provider_B), 1000e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 12 * APR_PERCENT, provider_A), 2225e18);
    // ------------------------------------------------|-----------------|------------|------- //
        assertEq(pool.getBorrowOrderBalance(markets[0],  20 * APR_PERCENT, provider_A),  375e18);
        assertEq(pool.getBorrowOrderBalance(markets[0],  10 * APR_PERCENT, borrower_B), 1000e18);
    }

    function test_outlier_provide_tick() public {
        _place_provide_order(markets[0], provider_B, 16 * APR_PERCENT, 1000e18);
        _place_provide_order(markets[0], provider_A,  0 * APR_PERCENT, 1000e18);
    // --------------------------------------------|-----------------|------- //
        _place_borrow_order(markets[0],  borrower_A, 10 * APR_PERCENT,  600e18);
        _place_borrow_order(markets[0],  borrower_B,  5 * APR_PERCENT, 1000e18);

        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 594e18, 10);
        // D = 594; X0 = 594/1.10 = 540; S = 54; first fee = 0; v = 20%.
        // Y = 0.2*54/(1+0.10*0.8) = 10; K = 10*1.10 = 11; reward = 54-10 = 44.
        _assert_sweeper_state(provider_C, 44e18, 11e18);
        assertEq(pool.loanOf(markets[0], provider_A), 594e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 605e18); // D+K = 594+11
        assertEq(pool.balanceOf(borrower_A), 550e18); // X0+Y = 540+10

        // Remaining provide = 1000-594; remaining borrow = 600-540-10.
        assertEq(pool.getProvideOrderBalance(markets[0], 16 * APR_PERCENT, provider_B), 1000e18);
        assertEq(pool.getProvideOrderBalance(markets[0],  0 * APR_PERCENT, provider_A),  406e18);
    // ------------------------------------------------|-----------------|------------|------- //
        assertEq(pool.getBorrowOrderBalance(markets[0],  10 * APR_PERCENT, borrower_A),   50e18);
        assertEq(pool.getBorrowOrderBalance(markets[0],   5 * APR_PERCENT, borrower_B), 1000e18);
    }

    function test_outlier_borrow_tick() public {
        _place_provide_order(markets[0], provider_B, 14 * APR_PERCENT,  1000e18);
        _place_provide_order(markets[0], provider_A, 12 * APR_PERCENT, 20000e18);
    // --------------------------------------------|-----------------|-------- //
        _place_borrow_order(markets[0],  borrower_A, 20 * APR_PERCENT, 15000e18);
        _place_borrow_order(markets[0],  borrower_B, 10 * APR_PERCENT,  1000e18);

        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 13875e18, 10);
        // D = 13875*1.12 = 15540; X0 = 15540/1.20 = 12950; S = 925; first fee = 1665*20% = 333.
        // v = 7/32; Y = (7/32)*925/(1+0.20*25/32) = 175; K = 175*1.20 = 210.
        // Reward = 925-175 = 750; owner loan = 333+210 = 543; lender loan = 15540-333 = 15207.
        _assert_sweeper_state(provider_C, 750e18, 543e18);
        assertEq(pool.loanOf(markets[0], provider_A), 15207e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 15750e18); // D+K
        assertEq(pool.balanceOf(borrower_A), 13125e18); // X0+Y

        // Remaining provide = 20000-13875; remaining borrow = 15000-12950-175.
        assertEq(pool.getProvideOrderBalance(markets[0], 14 * APR_PERCENT, provider_B), 1000e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 12 * APR_PERCENT, provider_A), 6125e18);
    // ------------------------------------------------|-----------------|------------|------- //
        assertEq(pool.getBorrowOrderBalance(markets[0],  20 * APR_PERCENT, borrower_A), 1875e18);
        assertEq(pool.getBorrowOrderBalance(markets[0],  10 * APR_PERCENT, borrower_B), 1000e18);
    }

    function test_zero_spread_succeeds_with_more_provide() public {
        _place_provide_order(markets[0], provider_B, 16 * APR_PERCENT, 1000e18);
        _place_provide_order(markets[0], provider_A, 12 * APR_PERCENT, 2000e18);
    // --------------------------------------------|-----------------|------- //
        _place_borrow_order(markets[0],  borrower_A, 12 * APR_PERCENT, 1000e18);
        _place_borrow_order(markets[0],  borrower_B, 10 * APR_PERCENT, 1000e18);

        // D = 1000*1.12 = 1120; X0 = 1120/1.12 = 1000; S = 0; owner loan = 120*20% = 24.
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1000e18, 10);
        _assert_sweeper_state(provider_C, 0, 24e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1096e18); // 1120-24
        assertEq(pool.debtOf(markets[0], borrower_A), 1120e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 16 * APR_PERCENT, provider_B), 1000e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 12 * APR_PERCENT, provider_A), 1000e18);
    // ------------------------------------------------|-----------------|------------|------- //
        assertEq(pool.getBorrowOrderBalance(markets[0],  12 * APR_PERCENT, borrower_A),       0);
        assertEq(pool.getBorrowOrderBalance(markets[0],  10 * APR_PERCENT, borrower_B), 1000e18);
    }

    function test_zero_spread_succeeds_with_more_borrow() public {
        _place_provide_order(markets[0], provider_B, 16 * APR_PERCENT, 1000e18);
        _place_provide_order(markets[0], provider_A, 12 * APR_PERCENT, 1000e18);
    // --------------------------------------------|-----------------|------- //
        _place_borrow_order(markets[0],  borrower_A, 12 * APR_PERCENT, 2000e18);
        _place_borrow_order(markets[0],  borrower_B, 10 * APR_PERCENT, 1000e18);

        // D = 1000*1.12 = 1120; X0 = 1120/1.12 = 1000; S = 0; owner loan = 120*20% = 24.
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1000e18, 10);
        _assert_sweeper_state(provider_C, 0, 24e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1096e18); // 1120-24
        assertEq(pool.debtOf(markets[0], borrower_A), 1120e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 16 * APR_PERCENT, provider_B), 1000e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 12 * APR_PERCENT, provider_A),       0);
    // ------------------------------------------------|-----------------|------------|------- //
        assertEq(pool.getBorrowOrderBalance(markets[0],  12 * APR_PERCENT, borrower_A), 1000e18);
        assertEq(pool.getBorrowOrderBalance(markets[0],  10 * APR_PERCENT, borrower_B), 1000e18);
    }

    function test_mixed_positive_and_zero_reward_ticks() public {
        _place_provide_order(markets[0], provider_D, 18 * APR_PERCENT,  10000e18);
        _place_provide_order(markets[0], provider_B, 16 * APR_PERCENT, 100000e18);
        _place_provide_order(markets[0], provider_A,  0 * APR_PERCENT,  27000e18);
    // --------------------------------------------|-----------------|--------- //
        _place_borrow_order(markets[0],  borrower_A, 20 * APR_PERCENT,  22500e18);
        _place_borrow_order(markets[0],  borrower_B, 16 * APR_PERCENT, 100000e18);
        _place_borrow_order(markets[0],  borrower_D, 10 * APR_PERCENT,  10000e18);

        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 108000e18, 10);
        // D = 27000+81000*1.16 = 120960; X0 = 27000/1.20+81000 = 103500; S = 4500.
        // D/A = 1.12, so v = 7/32; first fee = (120960-108000)*20% = 2592.
        // At r=16%: Y = (7/32)*4500/(1+0.16*25/32) = 875; K = 875*1.16 = 1015.
        // Reward = 4500-875 = 3625; owner loan = 2592+1015 = 3607.
        _assert_sweeper_state(provider_C, 3625e18, 3607e18);
        assertEq(pool.loanOf(markets[0], provider_A), 27000e18);
        assertEq(pool.loanOf(markets[0], provider_B), 91368e18); // 81000*1.16-2592
        assertEq(pool.debtOf(markets[0], borrower_A), 27000e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 94975e18); // (81000+875)*1.16

        // Remaining 16% provide = 100000-81000; borrow = 100000-81000-875.
        assertEq(pool.getProvideOrderBalance(markets[0], 18 * APR_PERCENT, provider_D), 10000e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 16 * APR_PERCENT, provider_B), 19000e18);
        assertEq(pool.getProvideOrderBalance(markets[0],  0 * APR_PERCENT, provider_A),        0);
    // ------------------------------------------------|-----------------|------------|-------- //
        assertEq(pool.getBorrowOrderBalance(markets[0],  20 * APR_PERCENT, borrower_A),        0);
        assertEq(pool.getBorrowOrderBalance(markets[0],  16 * APR_PERCENT, borrower_B), 18125e18);
        assertEq(pool.getBorrowOrderBalance(markets[0],  10 * APR_PERCENT, borrower_D), 10000e18);

        // The fee provide used 875 of the remaining 16% demand, so sweeping all 19000 now fails.
        vm.expectPartialRevert(ProvideMinLoanNotReached.selector);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 19000e18, 10);

        // Next D = 10000*1.16 = 11600; X0 = 10000; S = 0; reward unchanged, owner gains 1600*20% = 320.
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 10000e18, 10);
        _assert_sweeper_state(provider_C, 3625e18, 3927e18);

        // Remaining 16% provide = 19000-10000; borrow = 18125-10000.
        assertEq(pool.getProvideOrderBalance(markets[0], 18 * APR_PERCENT, provider_D), 10000e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 16 * APR_PERCENT, provider_B),  9000e18);
        assertEq(pool.getProvideOrderBalance(markets[0],  0 * APR_PERCENT, provider_A),        0);
    // ------------------------------------------------|-----------------|------------|-------- //
        assertEq(pool.getBorrowOrderBalance(markets[0],  20 * APR_PERCENT, borrower_A),        0);
        assertEq(pool.getBorrowOrderBalance(markets[0],  16 * APR_PERCENT, borrower_B),  8125e18);
        assertEq(pool.getBorrowOrderBalance(markets[0],  10 * APR_PERCENT, borrower_D), 10000e18);
    }

    function test_owner_sweeper_receives_cash_and_loan() public {
        _place_provide_order(markets[0], provider_A, 12 * APR_PERCENT, 7500e18);
        _place_borrow_order(markets[0],  borrower_A, 20 * APR_PERCENT, 7000e18);
        _place_borrow_order(markets[0],  borrower_B, 12 * APR_PERCENT,  500e18);

        pool.sweep(address(this), markets[0], 7500e18, 10);

        // D = 7500*1.12 = 8400; X0 = 8400/1.20 = 7000; S = 500; first fee = 900*20% = 180.
        // v = 7/32; at r=12%: Y = (7/32)*500/(1+0.12*25/32) = 100; K = 100*1.12 = 112.
        // Owner receives reward = 500-100 = 400 cash and 180+112 = 292 loan.
        assertEq(pool.balanceOf(address(this)), 400e18);
        assertEq(pool.loanOf(markets[0], address(this)), 292e18);
        assertEq(pool.loanOf(markets[0], provider_A), 8220e18); // 8400-180
        assertEq(pool.debtOf(markets[0], borrower_A), 8400e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 112e18);
    }


    // helpers

    function _assert_sweeper_state(address sweeper, uint256 reward, uint256 ownerLoan) internal view {
        assertEq(pool.balanceOf(sweeper), reward);
        assertEq(pool.balanceOf(address(this)), 0);
        assertEq(pool.loanOf(markets[0], address(this)), ownerLoan);
        assertEq(pool.debtOf(markets[0], sweeper), 0);
        assertEq(pool.loanOf(markets[0], sweeper), 0);
    }

    function _place_provide_order(uint64 market, address provider, uint256 APR, uint128 amount) internal {
        _deposit(provider, amount);
        vm.prank(provider); pool.placeProvideOrder(provider, market, APR, amount);
    }

    function _place_borrow_order(uint64 market, address borrower, uint256 APR, uint128 amount) internal {
        _deposit_collateral(borrower, market, amount * 4);
        vm.prank(borrower); pool.placeBorrowOrder(borrower, market, APR, amount);
    }
}

abstract contract SweepEventTestSuite is CreditPoolTestSuite {
    function _pool_logs(Vm.Log[] memory logs) internal view returns (Vm.Log[] memory poolLogs) {
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

    function _provided_reconciliations(Vm.Log memory log) internal pure returns (ReconciledReloanOrder[] memory reconciled) {
        assertEq(log.topics[0], Provided.selector);
        (,,,, reconciled) = abi.decode(log.data, (uint128, uint128, OrderFill[], InvalidatedBorrowOrder[], ReconciledReloanOrder[]));
    }

    function _seed_stale_reloans() internal {
        _deposit(provider_D, 20e18);
        vm.prank(provider_D); pool.placeProvideOrder(provider_D, markets[0], 0, 20e18);
        _borrow(markets[0], borrower_D, 20e18);
        vm.prank(provider_D); pool.transferLoan(markets[0], borrower_C, 10e18);
        vm.prank(provider_D); pool.placeReloanOrder(provider_D, markets[0], 7 * APR_PERCENT, 10e18);
        vm.prank(borrower_C); pool.placeReloanOrder(borrower_C, markets[0], 550, 10e18);
        // Retain one loan-token unit; each half rounds to zero without removing its resting order.
        pool.badDebt(markets[0], 20e18 - 1);
        assertEq(pool.loanOf(markets[0], provider_D), 0);
        assertEq(pool.loanOf(markets[0], borrower_C), 0);
    }
}

contract Test_sweep_without_protocol_fee is SweepEventTestSuite {
    function test_zero_spread_succeeds_without_protocol_fee() public {
        _deposit(provider_A, 120e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 5 * APR_PERCENT, 120e18);

        _deposit_collateral(borrower_A, markets[0], 480e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 5 * APR_PERCENT, 120e18);

        // D = 120*1.05 = 126; X0 = 126/1.05 = 120; reward = 120-120 = 0; fee = 0.
        vm.recordLogs();
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 120e18, 10);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 3);
        assertEq(logs[0].topics[0], Borrowed.selector);
        assertEq(_provided_reconciliations(logs[1]).length, 0);
        assertEq(logs[2].topics[0], Swept.selector);

        assertEq(pool.balanceOf(provider_C), 0);
        assertEq(pool.balanceOf(address(this)), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], 5 * APR_PERCENT, borrower_A), 0);
    }

    function test_sweep_without_protocol_fee_reports_only_primary_reconciliations() public {
        _seed_stale_reloans();
        _deposit(provider_A, 1060e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 5 * APR_PERCENT, 1060e18);
        _deposit_collateral(borrower_A, markets[0], 4200e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 6 * APR_PERCENT, 1050e18);

        vm.recordLogs();
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 4);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 3);
        assertEq(logs[0].topics[0], Borrowed.selector);
        ReconciledReloanOrder[] memory reconciled = _provided_reconciliations(logs[1]);
        assertEq(reconciled.length, 1);
        assertEq(abi.encode(reconciled[0]), abi.encode(ReconciledReloanOrder(provider_D, 7 * APR_PERCENT, 10e18)));
        assertEq(logs[2].topics[0], Swept.selector);
        assertEq(pool.balanceOf(provider_C), 10e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ReloanOrderCancelled(borrower_C, markets[0], 550, 10e18, true);
        pool.reconcileReloanOrder(borrower_C, markets[0]);
    }

}

contract Test_sweep_virtual_fee is SweepEventTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT / 10;
        params.provideOrderMinAmount = 1;
        params.borrowOrderMinAmount = 1;
    }

    function _seed(uint128 amount, uint128 primaryCash, uint128 feeLiquidity) private {
        _deposit(provider_A, amount);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 5 * APR_PERCENT, amount);
        _deposit_collateral(borrower_A, markets[0], primaryCash * 4);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 6 * APR_PERCENT, primaryCash);
        if (feeLiquidity != 0) {
            _deposit_collateral(borrower_B, markets[0], feeLiquidity * 4);
            vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 5 * APR_PERCENT, feeLiquidity);
        }
    }

    function test_sweep_credits_both_loan_fees_and_only_residual_cash() public {
        _seed(1060e18, 1050e18, 10e18);

        vm.recordLogs();
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 2);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 4);
        assertEq(logs[0].topics[0], Borrowed.selector);
        assertEq(_provided_reconciliations(logs[1]).length, 0);
        assertEq(_provided_reconciliations(logs[2]).length, 0);
        assertEq(logs[3].topics[0], Swept.selector);

        // D = 1060*1.05 = 1113; X0 = 1113/1.06 = 1050; S = 10; first-leg fee = 53*10% = 5.3.
        // v = floor(0.1*1113 / (0.9*1060+0.1*1113), 18 decimals) = 0.104477611940298507.
        // N = ceil(10*v, wei) = 1.044776119402985070.
        // K = floor(N*1.05 / (1+0.05*(1-v)), wei) = 1.049999999999999995.
        // Y = ceil(K/1.05, wei) = 0.999999999999999996; reward = 10-Y.
        // Lender loan = 1113-5.3; owner loan = 5.3+K; total loan = 1113+K.
        assertEq(pool.balanceOf(provider_C), 9.000000000000000004e18);
        assertEq(pool.balanceOf(address(this)), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 1107.7e18);
        assertEq(pool.loanOf(markets[0], address(this)), 6.349999999999999995e18);
        assertEq(pool.balanceOf(borrower_A), 1050e18);
        assertEq(pool.balanceOf(borrower_B), 0.999999999999999996e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 1.049999999999999995e18);
        (uint128 totalAssets, uint256 totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 1114.049999999999999995e18);
        assertEq(totalShares, 1114.049999999999999995e18 * SCALE);
        uint64[] memory ownerMarkets = pool.getUserMarkets(address(this), 0, type(uint256).max);
        assertEq(ownerMarkets.length, 1);
        assertEq(ownerMarkets[0], markets[0]);
    }

    function test_sweep_keeps_primary_and_fee_reconciliations_separate() public {
        _seed_stale_reloans();
        _seed(1060e18, 1050e18, 10e18);

        vm.recordLogs();
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 4);
        Vm.Log[] memory logs = _pool_logs(vm.getRecordedLogs());
        assertEq(logs.length, 4);
        assertEq(logs[0].topics[0], Borrowed.selector);
        ReconciledReloanOrder[] memory primary = _provided_reconciliations(logs[1]);
        ReconciledReloanOrder[] memory fee = _provided_reconciliations(logs[2]);
        assertEq(primary.length, 1);
        assertEq(fee.length, 1);
        assertEq(abi.encode(primary[0]), abi.encode(ReconciledReloanOrder(provider_D, 7 * APR_PERCENT, 10e18)));
        assertEq(abi.encode(fee[0]), abi.encode(ReconciledReloanOrder(borrower_C, 550, 10e18)));
        assertEq(logs[3].topics[0], Swept.selector);
        assertEq(pool.balanceOf(provider_C), 9.000000000000000004e18);
    }

    function test_owner_sweeper_still_executes_fee_provide() public {
        _seed(1060e18, 1050e18, 10e18);
        pool.sweep(address(this), markets[0], 1060e18, 2);
        // Same rounded K and Y as above: reward = 10-0.999999999999999996;
        // owner loan = (1113-1060)*10%+1.049999999999999995 = 6.349999999999999995.
        assertEq(pool.balanceOf(address(this)), 9.000000000000000004e18);
        assertEq(pool.loanOf(markets[0], address(this)), 6.349999999999999995e18);
        assertEq(pool.balanceOf(borrower_B), 0.999999999999999996e18);
    }

    function test_sweep_shares_order_budget_between_both_provides() public {
        _seed(1060e18, 1050e18, 10e18);
        vm.expectPartialRevert(ProvideMaxCrossedOrdersExceeded.selector);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 1);
        assertEq(pool.loanOf(markets[0], address(this)), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 5 * APR_PERCENT, provider_A), 1060e18);
    }

    function test_sweep_without_fee_liquidity_rolls_back() public {
        _seed(1060e18, 1050e18, 0);
        vm.expectPartialRevert(ProvideMinLoanNotReached.selector);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 2);
        assertEq(pool.loanOf(markets[0], address(this)), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], 6 * APR_PERCENT, borrower_A), 1050e18);
    }

    function test_sweep_executes_fee_provide_below_min_amount() public {
        _seed(10600, 10500, 100);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 10600, 2);
        // In wei: D = 10600*1.05 = 11130; X0 = 10500; S = 100; first-leg fee = (11130-10600)*10% = 53.
        // v = 0.104477611940298507; N = ceil(100*v) = 11; K = floor(11*1.05/(1+0.05*(1-v))) = 11.
        // Y = ceil(11/1.05) = 11; reward = 100-11 = 89; lender = 11130-53; owner = 53+11 = 64.
        assertEq(pool.balanceOf(provider_C), 89);
        assertEq(pool.balanceOf(borrower_B), 11);
        assertEq(pool.loanOf(markets[0], provider_A), 11077);
        assertEq(pool.loanOf(markets[0], address(this)), 64);
    }

    function test_fee_near_one_preserves_cash_and_loan_accounting() public {
        _set_fee_for_new_market(UNIT - 1);
        _seed(1060e18, 1050e18, 10e18);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 2);
        // f = v = 1-1e-18; S = 10; N = 10e18-10 wei; first-leg fee = 53e18-53 wei.
        // K = floor(N*1.05/(1+0.05e-18)) = 10.5e18-12 wei; Y = ceil(K/1.05) = 10e18-11 wei.
        // Reward = 11 wei; owner loan = 63.5e18-65 wei; lender = 1113e18-(53e18-53 wei).
        assertEq(pool.balanceOf(provider_C), 11);
        assertEq(pool.balanceOf(borrower_B), 9.999999999999999989e18);
        assertEq(pool.loanOf(markets[0], address(this)), 63.499999999999999935e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1060.000000000000000053e18);
    }

    function test_revisited_partial_order_uses_another_budget_slot() public {
        _seed(1060e18, 1060e18, 0);
        vm.expectPartialRevert(ProvideMaxCrossedOrdersExceeded.selector);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 1);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 2);
        assertGt(pool.balanceOf(borrower_A), 1050e18);
        assertLt(pool.balanceOf(borrower_A), 1060e18);
        assertEq(pool.balanceOf(provider_C) + pool.balanceOf(borrower_A), 1060e18);
    }

    function test_zero_fee_needs_no_fee_liquidity() public {
        _set_fee_for_new_market(0);
        _seed(1060e18, 1050e18, 0);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 1);
        // D = 1060*1.05 = 1113; X0 = 1113/1.06 = 1050; reward = 1060-1050 = 10; both fees = 0.
        assertEq(pool.balanceOf(provider_C), 10e18);
        assertEq(pool.loanOf(markets[0], address(this)), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 1113e18);
    }

    function test_positive_fee_target_rounds_up_from_less_than_one_wei() public {
        _set_fee_for_new_market(1);
        _seed(10600, 10500, 100);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 10600, 2);
        // In wei: D = 11130; S = 10600-10500 = 100; first-leg fee = floor(530/1e18) = 0.
        // v = 1e-18; N = ceil(100/1e18) = 1; K = floor(1.05/(1+0.05*(1-v))) = 1.
        // Y = ceil(1/1.05) = 1; reward = 100-1 = 99; owner loan = K = 1.
        assertEq(pool.balanceOf(provider_C), 99);
        assertEq(pool.balanceOf(borrower_B), 1);
        assertEq(pool.loanOf(markets[0], address(this)), 1);
    }

    function test_zero_spread_registers_owner_and_preserves_borrow_fee() public {
        _seed(1060e18, 1050e18, 0);
        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 6 * APR_PERCENT, type(uint128).max);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 5 * APR_PERCENT, 1060e18);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 1);
        // D = 1060*1.05 = 1113; X0 = 1113/1.05 = 1060; S = 0; owner loan = 53*10% = 5.3.
        assertEq(pool.balanceOf(provider_C), 0);
        assertEq(pool.loanOf(markets[0], address(this)), 5.3e18);
        assertEq(pool.getUserMarkets(address(this), 0, type(uint256).max).length, 1);
    }

    function test_owner_can_claim_and_withdraw_both_fees_after_repayment() public {
        _seed(1060e18, 1050e18, 10e18);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 2);
        // Interest to repay: A owes 1113-1050 = 63; B owes K-Y = 0.049999999999999999.
        // Repayment makes owner loan = 5.3+K and lender loan = 1113-5.3 claimable.
        _deposit(borrower_A, 63e18);
        _deposit(borrower_B, 0.05e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], type(uint128).max);
        vm.prank(borrower_B); pool.repay(borrower_B, borrower_B, markets[0], type(uint128).max);
        vm.warp(markets[0]);
        pool.claim(address(this), markets[0], type(uint128).max);
        pool.withdraw(address(this), address(this), type(uint128).max);
        assertEq(asset.balanceOf(address(this)), 6.349999999999999995e18);
        assertEq(pool.loanOf(markets[0], address(this)), 0);
        vm.prank(provider_A); pool.claim(provider_A, markets[0], type(uint128).max);
        assertEq(pool.balanceOf(provider_A), 1107.7e18);
    }

    function test_fuzz_sweep_fee_invariant_across_remaining_ticks(uint128 scale, uint256 protocolFee) public {
        scale = uint128(bound(scale, 1, 1e18) * 100);
        protocolFee = bound(protocolFee, 1, UNIT - 1);
        _set_fee_for_new_market(protocolFee);
        _seed(106 * scale, 105 * scale, scale / 4);
        _deposit_collateral(borrower_C, markets[0], 4 * scale);
        vm.prank(borrower_C); pool.placeBorrowOrder(borrower_C, markets[0], 0, scale);

        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 106 * scale, 3);

        uint256 debt = (uint256(106 * scale) * 105 + 99) / 100;
        uint256 primaryCash = (debt * 100 + 105) / 106;
        uint256 spread = 106 * scale - primaryCash;
        uint256 cash = pool.balanceOf(borrower_B) + pool.balanceOf(borrower_C);
        uint256 loan = pool.debtOf(markets[0], borrower_B) + pool.debtOf(markets[0], borrower_C);
        assertEq(pool.balanceOf(borrower_A), primaryCash);
        _assert_fee_invariant(106 * scale, debt, spread, protocolFee, cash, loan);
        assertEq(pool.balanceOf(provider_C), spread - cash);
        assertEq(pool.balanceOf(address(this)), 0);
        (uint128 totalAssets,) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, debt + loan);
        uint256 totalClaims = pool.loanOf(markets[0], provider_A) + pool.loanOf(markets[0], address(this));
        assertLe(totalClaims, totalAssets);
        assertEq_(totalClaims, totalAssets);
    }

    function _set_fee_for_new_market(uint256 protocolFee) private {
        pool.setProtocolFee(protocolFee);
        // Existing active markets keep their cached fee; use the next uncached market.
        vm.warp(markets[2]);
        markets[0] = markets[3];
        priceOracle.setPrice(1e18);
        assertEq(pool.getProtocolFee(markets[0]), protocolFee);
    }

    function test_fee_provide_skips_unhealthy_order_and_counts_its_visit() public {
        _seed(1060e18, 1050e18, 0);
        _deposit_collateral(borrower_B, markets[0], 24e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], 5 * APR_PERCENT, 10e18);
        _deposit_collateral(borrower_C, markets[0], 40e18);
        vm.prank(borrower_C); pool.placeBorrowOrder(borrower_C, markets[0], 4 * APR_PERCENT, 10e18);
        // Existing debt makes even a partial new fill unhealthy after the price change.
        _deposit(provider_D, 10e18);
        vm.prank(provider_D); pool.placeProvideOrder(provider_D, markets[0], 0, 10e18);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], 10e18, 10e18);
        priceOracle.setPrice(0.8e18);

        vm.expectPartialRevert(ProvideMaxCrossedOrdersExceeded.selector);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 2);
        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 3);
        assertEq(pool.balanceOf(borrower_B), 10e18);
        assertEq(pool.debtOf(markets[0], borrower_B), 10e18);
        assertGt(pool.balanceOf(borrower_C), 0);
        assertGt(pool.balanceOf(provider_C), 0);
    }

    function test_fee_provide_matches_reloan_after_bad_debt_without_extra_mint() public {
        _deposit(provider_B, 10e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 10e18);
        _deposit_collateral(borrower_C, markets[0], 40e18);
        vm.prank(borrower_C); pool.borrow(borrower_C, markets[0], 10e18, 10e18);
        pool.badDebt(markets[0], 5e18);
        vm.prank(provider_B); pool.placeReloanOrder(provider_B, markets[0], 5 * APR_PERCENT, 5e18);
        _seed(1060e18, 1050e18, 0);

        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 2);
        // K = 1.049999999999999995, Y = 0.999999999999999996 (same 10% fee, 5% fill as above).
        // Seller loan = 5-K; lender = 1113-5.3; owner = 5.3+K.
        // Reloan burns and reissues K: total assets = 5+1113-K+K = 1118.
        // Bad debt halved assets/share, so total shares = 1118*2*SCALE.
        assertEq(pool.balanceOf(provider_B), 0.999999999999999996e18);
        assertEq(pool.loanOf(markets[0], provider_B), 3.950000000000000005e18);
        assertEq(pool.loanOf(markets[0], provider_A), 1107.7e18);
        assertEq(pool.loanOf(markets[0], address(this)), 6.349999999999999995e18);
        (uint128 totalAssets, uint256 totalShares) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 1118e18);
        assertEq(totalShares, 2236e18 * SCALE);
    }

    function test_fee_provide_can_match_owner_reloan_order() public {
        _deposit(address(this), 10e18);
        pool.placeProvideOrder(address(this), markets[0], 0, 10e18);
        _deposit_collateral(borrower_C, markets[0], 40e18);
        vm.prank(borrower_C); pool.borrow(borrower_C, markets[0], 10e18, 10e18);
        pool.placeReloanOrder(address(this), markets[0], 5 * APR_PERCENT, 10e18);
        _seed(1060e18, 1050e18, 0);

        vm.prank(provider_C); pool.sweep(provider_C, markets[0], 1060e18, 2);
        // Owner sells K = 1.049999999999999995 for Y = 0.999999999999999996 cash.
        // Owner loan = 10+5.3-K+K = 15.3; reward = 10-Y; total assets = 10+1113-K+K = 1123.
        assertEq(pool.balanceOf(address(this)), 0.999999999999999996e18);
        assertEq(pool.loanOf(markets[0], address(this)), 15.3e18);
        assertEq(pool.balanceOf(provider_C), 9.000000000000000004e18);
        (uint128 totalAssets,) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssets, 1123e18);
    }

    function _assert_fee_invariant(uint256 amount, uint256 debt, uint256 spread, uint256 fee, uint256 cash, uint256 loan) private pure {
        uint256 denominator = (UNIT - fee) * amount + fee * debt;
        uint256 virtualFee = fee * debt * UNIT / denominator;
        uint256 target = (spread * virtualFee + UNIT - 1) / UNIT;
        assertLe(cash, target);
        assertLe(target, spread);
        assertGe(loan, cash);
        uint256 left = (UNIT - fee) * amount * loan + fee * debt * cash;
        uint256 right = fee * debt * spread;
        // At most two fee fills: target/inverse rounding adds two units of denominator;
        // fee floors add two more, and virtual-rate flooring adds denominator * (K-Y+S) / UNIT.
        uint256 tolerance = denominator * 4 + (denominator * (loan - cash + spread) + UNIT - 1) / UNIT;
        assertLe(left > right ? left - right : right - left, tolerance);
    }

    function test_public_provide_still_rejects_below_min_amount() public {
        vm.expectPartialRevert(AmountIsOutOfRange.selector);
        vm.prank(provider_A); pool.provideExactOut(provider_A, markets[0], MIN_AMOUNT - 1, 1, 1);
    }
}
