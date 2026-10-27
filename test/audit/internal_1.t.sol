// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { CreditPoolTestSuite, MockCreditPool } from "test/CreditPool/0_base.t.sol";

/*
FIXED: offset debts are no longer counted as cash repayments

### N-01 Loan-source rollover credits unfunded debt as claimable market cash

The scenario below describes the reported baseline; the current regression asserts the fixed accounting.

- **Severity**: high
- **Attack Scenario**: An attacker controls a source borrower and a source lender address. The lender address funds source debt, the borrower also holds a loan claim in the same source market, and only enough source market cash exists to pay the keeper fee. After maturity, the borrower enables rollover and executes a loan-source rollover with no reborrow. The rollover burns the borrower's loan claim, clears the borrower's source debt, pays the fee, and records the cleared debt as source-market claimable balance without funded asset backing. When another market later receives a real repayment, the source lender claims the overcredited source balance and withdraws those tokens. The later market keeps its accounting balance but lacks pool asset tokens for its lender claim.
- **Preconditions**: The source market is finalized. The borrower has rollover enabled with positive keeper fee. The borrower owns loan exposure of at least source debt plus fee. Source `loanPool.balance` is at least the keeper fee but below debt plus fee. The pool later receives asset cash for another market or liability bucket. A source lender has an outstanding claim in the overcredited source market.
- **Execution Feasibility**: The [rollover regression](internal_1.t.sol#L25) uses 1000 asset source debt, a 1010 asset borrower loan claim, and 10 asset source cash for a 1% keeper fee. On the reported baseline, rollover left source `loanPool.balance` at 1000 while the pool asset balance was zero. A later 1000 asset repayment in market 1 could then be claimed by the market 0 lender, leaving the market 1 lender's claim to revert with `InsufficientPoolBalance`. The current test requires zero unfunded source balance and rejects that cross-market claim.
- **Impact**: Cross-market asset theft and accounting insolvency. Source-market claimants withdraw tokens funded for another market, while the victim market retains a positive `loanPool.balance` with no asset tokens behind it. The attack also lets illiquid loan exposure settle source debt as if it were already funded cash.
- **Historical validation**: The loan-source cap `loanPool.balance * (UNIT + keeperFee) / keeperFee` proved fee liquidity rather than full claim liquidity. The old settlement path burned debt plus fee worth of loan claim, subtracted only `feeFromLoan` from the source balance, and then added the full covered debt as cash repayment. That overcredited balance could consume another market's tokens through a claim. The current [CreditPoolRolloverExtension._coverWithLoan](../../src/CreditPoolRolloverExtension.sol#L142) uses [CreditPoolBase._offset](../../src/CreditPoolBase.sol#L1537) for debt and [CreditPoolBase._claim](../../src/CreditPoolBase.sol#L1105) only for the fee. The regression [test_rollover_with_unfunded_loan_claim_steals_later_market_repayment](internal_1.t.sol#L25) requires zero unfunded source cash and rejects a source claim against the later market's repayment.
- **Remediation**: In the loan-cover branch, cap `moveFromLoan` by funded claimable market cash, not by fee cash. Debit source `loanPool.balance` by the full `moveFromLoan`, then add back only `debtFromLoan` as repayment and transfer `feeFromLoan`. Alternatively, exclude `debtFromLoan` from the shared `loanPool.balance += action.totalDebt` aggregation and handle each rollover source with source-specific cash accounting.
 */
contract TestAudit1_rollover_with_unfunded_loan_claim_steals_later_market_repayment is CreditPoolTestSuite {
    uint256 internal constant KEEPER_FEE = UNIT / 100;

    function test_rollover_with_unfunded_loan_claim_steals_later_market_repayment() public {
        address keeper = makeAddr("keeper");

        _deposit(provider_A, 1000e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 1000e18);

        _deposit_collateral(borrower_A, markets[0], 4000e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1000e18, 1000e18);
        _withdraw_and_burn(borrower_A, 1000e18);

        _deposit(borrower_A, 1010e18);
        vm.prank(borrower_A); pool.placeProvideOrder(borrower_A, markets[0], 0, 1010e18);

        _deposit_collateral(borrower_B, markets[0], 4040e18);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], 1010e18, 1010e18);
        _withdraw_and_burn(borrower_B, 1010e18);

        _deposit(borrower_B, 10e18);
        vm.prank(borrower_B); pool.repay(borrower_B, borrower_B, markets[0], 10e18);

        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, 0, KEEPER_FEE);
        _approve_rollover_extension(borrower_A);

        skip(YEAR); priceOracle.touch();

        assertEq(pool.debtOf(markets[0], borrower_A),  1000e18);
        assertEq(pool.loanOf(markets[0], borrower_A),  1010e18);
        assertEq(pool.getMarketBalance(markets[0]),      10e18);

        RolloverSolution memory solution;
        _rollover_extension(address(pool), markets[0], borrower_A, keeper, KEEPER_FEE, solution);
        vm.prank(keeper); rolloverExtension.withdrawFee(address(asset), keeper, type(uint128).max);

        assertEq(pool.debtOf(markets[0], borrower_A),  0);
        assertEq(pool.loanOf(markets[0], borrower_A),  0);
        assertEq(pool.getMarketBalance(markets[0]),    0);

        assertEq(asset.balanceOf(address(pool)), 0);
        assertEq(asset.balanceOf(keeper), 10e18);


        // next market

        _deposit(provider_C, 1000e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[1], 0, 1000e18);

        _deposit_collateral(borrower_C, markets[1], 4000e18);
        vm.prank(borrower_C); pool.borrow(borrower_C, markets[1], 1000e18, 1000e18);
        _withdraw_and_burn(borrower_C, 1000e18);

        _deposit(borrower_C, 1000e18);
        vm.prank(borrower_C); pool.repay(borrower_C, borrower_C, markets[1], 1000e18);

        assertEq(pool.getMarketBalance(markets[1]), 1000e18);
        assertEq(asset.balanceOf(address(pool)), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(InsufficientMarketLoanAvailable.selector, 0, 1000e18));
        vm.prank(provider_A); pool.claim(provider_A, markets[0], 1000e18);


        //

        _deposit(borrower_B, 1000e18);
        vm.prank(borrower_B); pool.repay(borrower_B, borrower_B, markets[0], 1000e18);

        vm.prank(provider_A); pool.claim(provider_A, markets[0], 1000e18);
    }
}


/*
FIXED: check HF for first reborrowed debt portion during rollover

### F-01 Rollover skips target-market health checks and creates instantly liquidatable debt

The scenario below describes the reported baseline; the current regression rejects the unhealthy target debt.

- **Severity**: medium
- **Attack Scenario**: A keeper targets a borrower whose source debt is inside the rollover grace period and whose `maxDebtFactor` accepts the target APR. The keeper supplies target-market liquidity, calls `rollover`, and moves all source debt into a target market. The source debt is not liquidatable before the call. The target debt is liquidatable immediately after the call because the target health factor is below `UNIT`.
- **Preconditions**: The borrower enabled rollover for the source market, the source position is healthy but close to the liquidation boundary, the grace-period factor has opened enough rollover factor, and active target liquidity exists at an APR that keeps `factor <= maxDebtFactor` while reducing target health below `UNIT`.
- **Execution Feasibility**: Verified with `test_rollover_can_create_immediately_liquidatable_target_debt`. The PoC uses 1000 asset debt, 2020 collateral, 1% keeper fee, 20% max rollover factor, and 10% target APR. During grace, source `isLiquidatable` is false; after rollover, target debt is `1110838584474885844749`, target health factor is `909223008739335312`, and target `isLiquidatable` is true.
- **Impact**: Borrower grace-period protection is bypassed. A public keeper can convert protected source debt into an immediately liquidatable active-market position and open discounted collateral seizure against the borrower before the source grace period expires.
- **Historical validation**: The old rollover path added target debt, moved collateral, checked the debt-growth factor, and checked health only in the source market. Current target debt and collateral allocation are handled by [CreditPoolBase._refinanceDebts](../../src/CreditPoolBase.sol#L1368), with [CreditPoolBase._requireHealthyRefinanceAndEmit](../../src/CreditPoolBase.sol#L1471) enforcing target health. Liquidatability is defined by [CreditPoolBase.__isLiquidatable](../../src/CreditPoolBase.sol#L2504).
- **Remediation**: After each target debt and collateral allocation is finalized, require `__getHealthFactor(reborrow.market, borrower_, _rate(), 0, 0) >= UNIT`. Run the check after collateral is moved and before source debt is cleared or fees are transferred. Keep the existing `maxDebtFactor` check as an additional debt-growth cap, not as a substitute for target solvency.
 */
contract TestAudit1_rollover_can_create_immediately_liquidatable_target_debt is CreditPoolTestSuite {
    uint256 internal constant KEEPER_FEE = UNIT / 100;

    function reconfigure(InitializationParams memory params) internal pure override {
        params.liquidationGracePeriod = 1 days;
        params.marketsConfig.active[0] = 5;
        params.marketsConfig.active[1] = 5;
        params.marketsConfig.active[2] = 5;
    }

    function test_rollover_can_create_immediately_liquidatable_target_debt() public {
        _deposit(provider_A, 1000e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 1000e18);

        _deposit_collateral(borrower_A, markets[0], 2020e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1000e18, type(uint128).max);
        _withdraw_and_burn(borrower_A, 1000e18);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), 1.01e18);

        skip(YEAR + 14 hours); priceOracle.touch();

        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, UNIT * 20 / 100, KEEPER_FEE);
        _approve_rollover_extension(borrower_A);
        assertEq(pool.isLiquidatable(markets[0], borrower_A), false);

        _deposit(provider_B, 1200e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[1], 10 * APR_PERCENT, 1200e18);

        ReborrowSolution[] memory reborrows = new ReborrowSolution[](1);
        reborrows[0] = ReborrowSolution({ market: markets[1], debtPercent: UNIT });
        RolloverSolution memory solution = RolloverSolution({ reborrows: reborrows });

        vm.expectRevert(abi.encodeWithSelector(UnhealthyDebt.selector, 0.909223008739335312e18));
        _rollover_extension(address(pool), markets[0], borrower_A, address(this), KEEPER_FEE, solution);

        _deposit_collateral(borrower_A, markets[0], 300e18);

        _rollover_extension(address(pool), markets[0], borrower_A, address(this), KEEPER_FEE, solution);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[1], borrower_A), 1110838584474885844749);
        assertEq(pool.collateralOf(markets[1], borrower_A), 2320e18);

        assertEq(pool.getHealthFactor(markets[0], borrower_A), UNIT);
        assertGt(pool.getHealthFactor(markets[1], borrower_A), UNIT);
    }
}


/*
FIXED: keeper fee should be in range (0.001%; 100%]

### F-02 Zero keeper fee configuration makes rollover revert for debt positions

The scenario below describes the reported baseline; the current regression rejects zero-fee configuration.

- **Severity**: low
- **Attack Scenario**: A liquidator monitors borrowers that enabled rollover with `keeperFee = 0`. Rollover execution for a debt position reverts before it covers debt or reborrows into active markets. The borrower loses the configured rollover path and becomes liquidatable when grace expires.
- **Preconditions**: The borrower set rollover enabled with zero keeper fee, the source market is finalized, and source debt remains above zero.
- **Execution Feasibility**: Verified with `test_zero_keeper_fee_reverts_rollover_with_debt`. The PoC configures zero keeper fee, provides target liquidity, builds a full reborrow solution, and observes `rollover` revert.
- **Impact**: A configuration accepted by the contract disables rollover settlement for the affected borrower. The loss mode is bounded to zero-fee rollover users and creates avoidable liquidation exposure after grace.
- **Historical validation**: The old configuration accepted a zero keeper fee that was later used as the denominator in `Math.mulDiv(..., keeperFee, ...)`. The current [CreditPoolRolloverExtension.setRolloverConfig](../../src/CreditPoolRolloverExtension.sol#L69) calls [CreditPoolRolloverExtension._checkKeeperFee](../../src/CreditPoolRolloverExtension.sol#L343) whenever rollover is enabled; [CreditPoolRolloverExtension._coverWithLoan](../../src/CreditPoolRolloverExtension.sol#L142) contains the fee-based liquidity cap.
- **Remediation**: Either reject zero keeper fee in `_checkKeeperFee` when rollover is enabled, or add an explicit zero-fee branch that covers debt with fee equal to zero and never divides by `keeperFee`.
 */
contract TestAudit1_zero_keeper_fee_reverts_rollover_with_debt is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.liquidationGracePeriod = 1 days;
        params.marketsConfig.active[0] = 5;
        params.marketsConfig.active[1] = 5;
        params.marketsConfig.active[2] = 5;
    }

    function test_zero_keeper_fee_reverts_rollover_with_debt() public {
        _deposit(provider_A, 1000e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 1000e18);

        _deposit_collateral(borrower_A, markets[0], 4000e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1000e18, type(uint128).max);
        _withdraw_and_burn(borrower_A, 1000e18);

        skip(YEAR);
        priceOracle.touch();

        vm.expectRevert(abi.encodeWithSelector(InvalidKeeperFee.selector, 0));
        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, 0, 0);

        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, 0, UNIT / 10000);
        _approve_rollover_extension(borrower_A);

        _deposit(provider_B, 1100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[1], 0, 1100e18);

        ReborrowSolution[] memory reborrows = new ReborrowSolution[](1);
        reborrows[0] = ReborrowSolution({ market: markets[1], debtPercent: UNIT });
        RolloverSolution memory solution = RolloverSolution({ reborrows: reborrows });

        vm.expectRevert(abi.encodeWithSelector(MaxRolloverFactorExceeded.selector, 0.0001e18, 0));
        _rollover_extension(address(pool), markets[0], borrower_A, address(this), 0, solution);

        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, UNIT / 1000, UNIT / 10000);

        vm.expectRevert(abi.encodeWithSelector(MaxRolloverFactorExceeded.selector, 0.0001e18, 0));
        _rollover_extension(address(pool), markets[0], borrower_A, address(this), 0, solution);

        skip(pool.getLiquidationGracePeriod(markets[0])); priceOracle.touch();

        _rollover_extension(address(pool), markets[0], borrower_A, address(this), 0, solution);
    }
}

// FIXED: rollover reborrow uses source market protocol fee instead of target market fee
contract TestAudit1_rollover_reborrow_uses_source_market_protocol_fee_instead_of_target_market_fee is CreditPoolTestSuite {
    function test_rollover_reborrow_uses_target_market_protocol_fee() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 100e18);

        pool.setProtocolFee(UNIT * 40 / 100);

        skip(3 * YEAR);
        priceOracle.touch();

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[3], 10 * APR_PERCENT, 100e18);

        RefinanceDebtParams[] memory refinances = new RefinanceDebtParams[](1);
        refinances[0] = RefinanceDebtParams({
            toMarket: markets[3],
            debtToRepay: 100e18,
            assetsToBorrow: 100e18
        });

        vm.prank(borrower_A); pool.refinanceDebts(borrower_A, markets[0], UNIT / 2, refinances);

        assertEq(pool.getProtocolFee(markets[0]), 0);
        assertEq(pool.getProtocolFee(markets[3]), UNIT * 40 / 100);
        assertEq(pool.debtOf(markets[3], borrower_A), 110e18);
        assertEq(pool.loanOf(markets[3], provider_B), 106e18);
        assertEq(pool.loanOf(markets[3], address(this)), 4e18);
    }
}

// FIXED: transferLoan cleanup borders with amount < min
contract TestAudit1_single_loan_can_create_multiple_stale_reloan_orders_that_block_provide_limits is CreditPoolTestSuite {
    function test_single_loan_can_create_multiple_stale_reloan_orders_that_block_provide_limits() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        _borrow(markets[0], borrower_A, 100e18);

        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_A); pool.transferLoan(markets[0], provider_B, 99.5e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], 0, provider_A), 0);
    }
}

// FIXED: reenable the same orders as were disabled
contract TestAudit1_stale_porder_set_entry_can_leave_own_liquidity_enabled_during_borrow is CreditPoolTestSuite {
    function test_stale_porder_set_entry_can_leave_own_liquidity_enabled_during_borrow() public {
        _deposit(provider_A, 200e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _borrow(markets[0], borrower_A, 100e18);

        _deposit(provider_C, 100e18);
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, markets[0], 0, 100e18);
        _borrow(markets[0], borrower_B, 100e18);

        _deposit_collateral(provider_A, markets[0], 220e18);

        assertEq(pool.loanOf(markets[0], provider_A), 100e18);
        assertEq(pool.loanOf(markets[0], provider_C), 100e18);

        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, provider_C), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 100e18);

        vm.expectRevert(abi.encodeWithSelector(BorrowAssetsNotReached.selector, 100e18, 0));
        vm.prank(provider_A); pool.borrow(provider_A, markets[0], 100e18, type(uint128).max);
    }
}

/*
NOT REPRODUCED: the reachability regression passes.

The historical report below records the rejected hypothesis, not a confirmed current vulnerability.

#### 5. CreditPoolBase._provide() — provider self-skip path corrupts the borrower queue length and leaves orphaned linked-list nodes

##### Description
Inside `_provide`'s matching loop, when the current borrower at the head of the FIFO queue equals the provider (`state.borrower == provider`), the code calls `border.queueNodeId = _queue_push(tick.borrowers, state.borrower);` to re-queue the provider's own borrow order to the tail, then advances `state.queueHead` to the old node's `next`. The in-memory `state.queueLength` is not incremented to account for the push.

After the per-APR loop exits, the code writes `tick.borrowers.length = state.queueLength;`, which overwrites the storage `length` field that `_queue_push` had just incremented (`queue.length += 1`). The net effect is that every self-push contributes a new queue node to storage but is invisible in the recorded length.

Current implementation references: [CreditPoolBase._provide](../../src/CreditPoolBase.sol#L689), [CreditPoolBase._queue_push](../../src/CreditPoolBase.sol#L3508), and [CreditPoolBase._queue_remove](../../src/CreditPoolBase.sol#L3526).

Compounding issue: the OLD node at `state.queueHead` is never removed from `tick.borrowers.nodes`, never has its `prev/next` rewired around itself, and is no longer reachable as `head` after the writeback. It remains in `mapping(uint48 => AddressQueueNode)` with its old neighbor pointers intact, but its position in the linked list is now inconsistent with `head/tail/length`. Subsequent provide calls walking from the new head can encounter this orphaned node's neighbors and read stale data.

Exploit / impact scenario:
1. A provider has an open borrow order at the head of tick APR X.
2. The provider calls `provideExactIn(market, ..., maxCrossedOrders)`. Their own borrow order at the head triggers the self-skip.
3. `_queue_push` adds a new node at the tail with the provider's address. Storage `length` is now N+1.
4. The provide loop completes. The queue writeback overwrites storage `length` back to N (or N-K where K borrowers were consumed).
5. Subsequent provide-side matching reads `tick.borrowers.length = N` but the actual node mapping contains N+1 nodes. The pushed node is at the tail; its `prev` points to the previous tail; the previous tail's `next` was updated to point to the pushed node. The OLD head node still has its `next` pointing to what was originally the second-in-queue, but that node's `prev` was rewritten to 0 when `head` was advanced.
6. A future provider walking the queue will traverse legitimately but the inconsistent `length` causes off-by-K errors in any external bookkeeping that depends on `tick.borrowers.length`.

The function [CreditPoolBase._isBOrderInactive](../../src/CreditPoolBase.sol#L2748) does test `tick.borrowers.head > order.queueNodeId` — this defends against using stale `queueNodeId` references when head has advanced. But the orphaned nodes themselves are still in storage and contribute gas waste forever.

This issue is classified High severity because the orderbook queue is load-bearing for matching, accounting, and the explorer APIs, and the inconsistency is reachable through any normal `provide` call where the provider happens to be at the head of a borrow tick.

##### Recommendation
Consider either removing the old node from the queue (via `_queue_remove(tick.borrowers, oldId)`) before issuing the `_queue_push`, or incrementing `state.queueLength` after the self-skip push so the storage writeback reflects the actual length.

This is the reachability check for the audit report. Pass means the pushed self-order remains reachable
and `borrowers.length` tracks the live FIFO queue; fail means the auditor's length-corruption claim is reproduced.
 */
contract TestAudit1_provider_self_skip_keeps_borrower_queue_length_consistent is CreditPoolTestSuite {
    function test_audit_provider_self_skip_keeps_borrower_queue_length_consistent() public {
        uint256 APR = 10 * APR_PERCENT;

        _deposit_collateral(borrower_A, markets[0], 300e18);
        _deposit_collateral(borrower_B, markets[0], 300e18);
        _deposit_collateral(borrower_C, markets[0], 300e18);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], APR, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], APR, 100e18);
        vm.prank(borrower_C); pool.placeBorrowOrder(borrower_C, markets[0], APR, 100e18);

        _deposit(borrower_A, 50e18);
        vm.prank(borrower_A); pool.provideExactIn(borrower_A, markets[0], 50e18, 0, 10);

        BorrowOrderbookTickView[] memory orderbook = pool.getBorrowOrderbook(markets[0]);
        assertEq(orderbook[APR / APR_TICK_SPACING].count, 3);
        assertEq(orderbook[APR / APR_TICK_SPACING].amount, 250e18);

        MockCreditPool.TickBorrowOrderView[] memory queue = pool.viewBorrowOrderbookForTick(markets[0], APR);
        assertEq(queue.length, 3);
        assertEq(queue[0].borrower, borrower_A);
        assertEq(queue[0].amount, 100e18);
        assertEq(queue[1].borrower, borrower_B);
        assertEq(queue[1].amount, 50e18);
        assertEq(queue[2].borrower, borrower_C);
        assertEq(queue[2].amount, 100e18);

        _deposit(provider_D, 250e18);
        vm.prank(provider_D); pool.provideExactIn(provider_D, markets[0], 250e18, 0, 10);

        orderbook = pool.getBorrowOrderbook(markets[0]);
        assertEq(orderbook[APR / APR_TICK_SPACING].count, 0);
        assertEq(orderbook[APR / APR_TICK_SPACING].amount, 0);

        queue = pool.viewBorrowOrderbookForTick(markets[0], APR);
        assertEq(queue.length, 0);
    }
}

/*
NOT REPRODUCED: the reachability regression passes.

The historical report below records the rejected hypothesis, not a confirmed current vulnerability.

#### 6. BitSetLib._prevValue() — reverse-bucket loop underflows uint256 when leftmost bucket equals zero

##### Description
`_prevValue(set, value)` walks backwards through bitmap buckets to find the previous set bit. The bucket-loop is:

```
for (uint256 bucket = (value >> 8) - 1; bucket >= leftmostBucket; --bucket)
```

If `leftmostBucket == 0` (which is the case whenever the set's `smallest` value is in the 0..255 range) and the search finds no earlier bit in any bucket, the loop iterates through `bucket = 0`, the body executes, and then `--bucket` runs in checked uint256 arithmetic. The underflow reverts. There is no defensive `if (bucket == 0) break;` after processing bucket zero.

Current implementation reference: [BitSet._prevValue](../../src/lib/BitSet.sol#L126).

Exploit / impact scenario:
1. The provide-side `BOrderbook.aprs` BitSet contains a non-trivial set of APR values, with the smallest active APR sitting in the lowest bucket (APR < 256 * APR_TICK_SPACING).
2. A caller invokes a function that traverses the BitSet backwards from a value near the largest bucket — for instance via `borderbook.aprs.prev(currentAPR)` inside [CreditPoolBase._provide](../../src/CreditPoolBase.sol#L689) matching.
3. If the search has to walk past bucket zero (because the actual smallest is at bucket zero but the function is called with a value at bucket > 0 and the bitmap at every intermediate bucket happens to be 0), the function reverts on the `--bucket` underflow.

The exploit requires a specific sparse-bitmap pattern where bucket zero has bits set but every higher bucket up to the query is empty. This is unusual in the active orderbook but possible if `setMaxActiveProvideOrders` shrinks active set caps or if a market migrates orders to a single low-APR tick. The regression [test_audit_sparse_reverse_bucket_walk_reaches_bucket_zero_without_revert](internal_1.t.sol#L404) now exercises this boundary case.

Secondary observation: [BitSet._nextValue](../../src/lib/BitSet.sol#L108) does not underflow because the loop variable is `(value >> 8) + 1 ... rightmostBucket`, which is monotonically increasing within a bounded range.

This issue is classified High severity because the BitSet underpins every borrow-side APR traversal in `_provide`/`_previewProvide`/`_cancelBorrowOrder`, and a revert in this primitive translates to a sustained DoS of the affected functions for any user attempting a provide-match while the bitmap is in the vulnerable pattern.

##### Recommendation
Consider adding an explicit `if (bucket == 0) break;` (or rewriting the loop as `do { ... } while (bucket-- > leftmostBucket);` with an explicit zero guard) so the reverse walk terminates safely once bucket zero has been inspected.

This is the reachability check for the audit report. Pass means a sparse reverse walk from a high APR
reaches bucket zero without reverting; fail means the auditor's underflow DoS claim is reproduced.
 */
contract TestAudit1_bitset_prev_value_sparse_bucket_zero_walk_does_not_revert is CreditPoolTestSuite {
    function test_audit_sparse_reverse_bucket_walk_reaches_bucket_zero_without_revert() public {
        uint256 LOW_APR = 0;
        uint256 HIGH_APR = 15 * APR_PERCENT;

        _deposit_collateral(borrower_A, markets[0], 300e18);
        _deposit_collateral(borrower_B, markets[0], 300e18);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], LOW_APR, 100e18);
        vm.prank(borrower_B); pool.placeBorrowOrder(borrower_B, markets[0], HIGH_APR, 100e18);

        (uint256 collectedLoan, uint256 consumedAssets, uint16 crossedOrders) =
            pool.previewProvideExactIn(markets[0], 50e18, 0, 10, provider_A);
        assertEq(collectedLoan, 57.5e18);
        assertEq(consumedAssets, 50e18);
        assertEq(crossedOrders, 1);

        _deposit(provider_A, 50e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 50e18, 0, 10);

        BorrowOrderbookTickView[] memory orderbook = pool.getBorrowOrderbook(markets[0]);
        assertEq(orderbook[LOW_APR / APR_TICK_SPACING].amount, 100e18);
        assertEq(orderbook[LOW_APR / APR_TICK_SPACING].count, 1);
        assertEq(orderbook[HIGH_APR / APR_TICK_SPACING].amount, 50e18);
        assertEq(orderbook[HIGH_APR / APR_TICK_SPACING].count, 1);
        // 50 assets at 15% APR over one year mints 57.5 loan assets.
        assertEq(pool.loanOf(markets[0], provider_A), 57.5e18);
    }
}

contract TestAudit1_liquidation_bad_debt_does_not_orphan_recovered_assets is CreditPoolTestSuite {
    address internal liquidator = makeAddr("Liquidator");

    struct LiquidationCase {
        uint128 debt;
        uint128 collateralAmount;
        uint128 liquidationAmount;
        uint256 totalSharesBefore;
    }

    function test_liquidation_bad_debt_keeps_recovered_repayment_claimable() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 220e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 220e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 110e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        (uint256 totalAssetsBefore, uint256 totalSharesBefore) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsBefore, 110e18);

        priceOracle.setPrice(0.1e18);
        assertEq(pool.isLiquidatable(markets[0], borrower_A), true);

        // HF = (220 * 0.1 * 0.5) / 110 = 0.1
        // discount = min(1 - 0.1 + 0.05, 0.2) = 0.2
        // repay = 220 * 0.1 * (1 - 0.2) = 17.6
        _mint(liquidator, 17.6e18);

        vm.expectEmit(true, true, false, true, address(pool));
        emit BadDebtIncurred(borrower_A, markets[0], 92.4e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 17.6e18, 0, type(uint256).max, "");

        (uint256 totalAssetsAfter, uint256 totalSharesAfter) = pool.viewLoanPool(markets[0]);

        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.getMarketBalance(markets[0]), 17.6e18);

        // totalAssets before socialization equals repaid debt plus residual bad debt: 110 = 17.6 + 92.4.
        assertEq(totalAssetsAfter, 17.6e18);
        assertEq(totalAssetsAfter, pool.getMarketBalance(markets[0]));
        assertEq(totalAssetsAfter, pool.loanOf(markets[0], provider_A));
        assertGt(totalAssetsAfter, 0);
        assertEq(totalSharesAfter, totalSharesBefore);

        skip(YEAR); priceOracle.touch();
        vm.prank(provider_A); pool.claim(provider_A, markets[0], type(uint128).max);

        (uint256 totalAssetsAfterClaim, uint256 totalSharesAfterClaim) = pool.viewLoanPool(markets[0]);
        assertEq(pool.balanceOf(provider_A), 17.6e18);
        assertEq(pool.getMarketBalance(markets[0]), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(totalAssetsAfterClaim, 0);
        assertEq(totalSharesAfterClaim, 0);
    }

    function test_liquidation_rejects_zero_discounted_recovery() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 100e18);

        (uint256 totalAssetsBefore, uint256 totalSharesBefore) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsBefore, 100e18);

        // The positive price is smaller than one asset unit for the borrower's entire collateral.
        priceOracle.setPriceFraction(1, type(uint256).max);
        assertEq(pool.getHealthFactor(markets[0], borrower_A), 0);

        _mint(liquidator, 1);
        vm.expectRevert(NoDebtToLiquidate.selector);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 1, 0, type(uint256).max, "");

        (uint256 totalAssetsAfter, uint256 totalSharesAfter) = pool.viewLoanPool(markets[0]);
        assertEq(pool.collateralOf(markets[0], borrower_A), 400e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 100e18);
        assertEq(totalAssetsAfter, 100e18);
        assertEq(totalSharesAfter, totalSharesBefore);
        assertEq(asset.balanceOf(liquidator), 1);
    }

    function test_fuzz_liquidation_bad_debt_keeps_recovered_assets_claimable(
        uint96 borrowRaw,
        uint96 collateralRaw,
        uint96 priceRaw
    ) public {
        LiquidationCase memory c = _open_liquidatable_position(
            borrowRaw,
            collateralRaw,
            priceRaw,
            provider_A,
            borrower_A
        );

        _mint(liquidator, c.liquidationAmount);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, type(uint128).max, 0, type(uint256).max, "");

        (uint256 totalAssetsAfter, uint256 totalSharesAfter) = pool.viewLoanPool(markets[0]);

        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(totalAssetsAfter, c.liquidationAmount);
        assertEq(totalAssetsAfter, pool.getMarketBalance(markets[0]));
        assertEq(totalAssetsAfter, pool.loanOf(markets[0], provider_A));
        assertGt(totalAssetsAfter, 0);
        assertEq(totalSharesAfter, c.totalSharesBefore);

        skip(YEAR); priceOracle.touch();
        vm.prank(provider_A); pool.claim(provider_A, markets[0], type(uint128).max);

        (uint256 totalAssetsAfterClaim, uint256 totalSharesAfterClaim) = pool.viewLoanPool(markets[0]);
        assertEq(pool.balanceOf(provider_A), c.liquidationAmount);
        assertEq(pool.getMarketBalance(markets[0]), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(totalAssetsAfterClaim, 0);
        assertEq(totalSharesAfterClaim, 0);
    }

    function test_fuzz_lender_entering_after_partial_bad_debt_receives_fresh_claim(uint16 newBorrowWhole) public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 220e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 220e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 110e18);

        priceOracle.setPrice(0.1e18);

        _mint(liquidator, 17.6e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 17.6e18, 0, type(uint256).max, "");

        assertEq(pool.loanOf(markets[0], provider_A), 17.6e18);

        uint128 newBorrowAmount = uint128(bound(uint256(newBorrowWhole), 100, 10_000)) * 1e18;
        priceOracle.setPrice(1e18);

        _deposit(provider_B, newBorrowAmount);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, newBorrowAmount);

        _deposit_collateral(borrower_B, markets[0], newBorrowAmount * 3);
        vm.prank(borrower_B); pool.borrow(borrower_B, markets[0], newBorrowAmount, type(uint128).max);

        (uint256 totalAssetsAfterEntry,) = pool.viewLoanPool(markets[0]);

        assertEq(pool.loanOf(markets[0], provider_A), 17.6e18);
        assertEq(pool.loanOf(markets[0], provider_B), newBorrowAmount);
        assertEq(totalAssetsAfterEntry, 17.6e18 + newBorrowAmount);
    }

    function _open_liquidatable_position(
        uint256 borrowRaw,
        uint256 collateralRaw,
        uint256 priceRaw,
        address provider,
        address borrower
    ) internal returns (LiquidationCase memory c) {
        uint128 borrowAmount = uint128(bound(borrowRaw, 100e18, 10_000e18));

        _deposit(provider, borrowAmount);
        vm.prank(provider); pool.placeProvideOrder(provider, markets[0], 0, borrowAmount);

        _deposit_collateral(borrower, markets[0], borrowAmount * 10);
        vm.prank(borrower); pool.borrow(borrower, markets[0], borrowAmount, type(uint128).max);

        c.debt = pool.debtOf(markets[0], borrower);
        c.collateralAmount = uint128(bound(collateralRaw, uint256(c.debt) * 2, uint256(c.debt) * 4));

        uint128 collateralBefore = pool.collateralOf(markets[0], borrower);
        vm.prank(borrower); pool.withdrawCollateral(borrower, markets[0], borrower, collateralBefore - c.collateralAmount);

        (uint256 totalAssetsBefore, uint256 totalSharesBefore) = pool.viewLoanPool(markets[0]);
        assertEq(totalAssetsBefore, c.debt);

        uint256 liquidationPrice = bound(priceRaw, UNIT / 100, UNIT / 5);
        priceOracle.setPrice(liquidationPrice);
        assertEq(pool.isLiquidatable(markets[0], borrower), true);

        // discount is maxed at 20%; repay enough to seize all collateral.
        c.liquidationAmount = uint128(Math.mulDiv(
            Math.mulDiv(c.collateralAmount, liquidationPrice, UNIT, Math.Rounding.Floor),
            8,
            10,
            Math.Rounding.Floor
        ));
        c.totalSharesBefore = totalSharesBefore;

        assertGt(c.liquidationAmount, 0);
        assertLt(c.liquidationAmount, c.debt);
        assertGe(c.debt - c.liquidationAmount, pool.getMinDebtRemainingAfterLiquidation());
    }
}
