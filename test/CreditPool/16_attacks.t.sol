// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_explorer is CreditPoolTestSuite {
    // Attack Scenario: an attacker first calls borrow() or reloan() while holding a live provide order. That call
    // runs _disableAllPOrders() and stores the order’s current assets in order.disabledAssets. After another
    // borrower fully consumes the attacker’s order, the attacker calls borrow() again. The stale disabledAssets
    // value is re-enabled as fresh active liquidity even though the order was already settled into loan shares. The
    // attacker then calls cancelProvideOrder() and withdraws real Aave backing that belongs to other lenders.
    //
    // Preconditions: the attacker needs one live provide order, one earlier self-triggered borrow() or reloan() that
    // seeded disabledAssets, a later third-party borrow that fully consumes the attacker’s order, and some
    // remaining Aave-backed liquidity in the pool from honest providers. No privilege is required.
    //
    // Execution Feasibility: Verified. I reproduced the issue with a targeted Foundry PoC. The sequence was:
    // attacker seeds disabledAssets with a self-borrow, another borrower fully consumes the attacker’s order,
    // attacker self-borrows again, stale liquidity reappears, attacker cancels the resurrected order, and honest
    // provider backing is withdrawn by the attacker.
    //
    // Impact: this breaks the core invariant that a fully consumed provide order is gone and only its realized loan
    // claim remains. The attacker converts an already-settled claim back into live Aave-backed liquidity, erases
    // their fixed-term lender claim, drains backing supplied by other lenders, and leaves honest providers with
    // unbacked orderbook balances. This is market-level theft plus accounting corruption.
    //
    // Validation: Verified. The root cause is the call order in _disablePOrder() at src/
    // CreditPoolBase.sol:894-910. The function calls _syncPOrder(account, market, APR) before
    // _syncPOrderbookTick(market, APR). If the order was fully consumed and the tick generation already
    // advanced, _syncPOrder() snapshots the old generation first. _syncPOrderbookTick() then advances the tick,
    // so _porderBalance() returns zero and the stale order.disabledAssets value survives. _enablePOrder() at
    // src/CreditPoolBase.sol:912-930 later trusts order.disabledAssets and re-mints that stale balance into the
    // active tick and bucket. The vulnerable disable/re-enable cycle is reachable from _borrow() at
    // src/CreditPoolBase.sol:321-332 and from reloan() at src/facets/CreditPoolFacet3.sol:39-50. The stolen
    // backing is realized through cancelProvideOrder() at src/facets/CreditPoolFacet1.sol:42-64.
    //
    // Remediation: reorder _disablePOrder() so the tick is synchronized before the user order is synchronized,
    // and clear order.disabledAssets on every enable path and every path where the order resolves to zero live
    // liquidity. The safety invariant must be strict: once an order is fully consumed, it can only remain as loan
    // shares or become zero, never become active Aave-backed liquidity again.
    function test_selfborrow_attack() public {
        address ATTACKER = makeAddr("attacker");

        _deposit(ATTACKER, 100e18);
        vm.prank(ATTACKER); pool.placeProvideOrder(ATTACKER, markets[0], 0, 100e18);

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        _borrow(markets[0], ATTACKER, 100e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, ATTACKER), 100e18);

        _borrow(markets[0], borrower_A, 100e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, ATTACKER), 0);

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);

        _borrow(markets[0], ATTACKER, 100e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 0, ATTACKER), 0 /* was 100e18 before fix */);
    }
}
