// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

type NONE_T is uint256;
NONE_T constant NONE = NONE_T.wrap(0);

contract TestCreditPool_getAllProvideOrders is CreditPoolTestSuite {
    function test_place_and_yield() public {
        _deposit(provider_A, 60e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 1 * APR_PERCENT, 10e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 2 * APR_PERCENT, 20e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[1], 3 * APR_PERCENT, 30e18);

        assertAllProvideOrders(markets[0], provider_A, [
            ProvideOrderView({APR: 1 * APR_PERCENT, amount: 10e18}),
            ProvideOrderView({APR: 2 * APR_PERCENT, amount: 20e18})
        ]);

        assertAllProvideOrders(markets[1], provider_A, [
            ProvideOrderView({APR: 3 * APR_PERCENT, amount: 30e18})
        ]);

        skip(YEAR);

        assertAllProvideOrders(markets[0], provider_A, [
            ProvideOrderView({APR: 1 * APR_PERCENT, amount: 11e18}),
            ProvideOrderView({APR: 2 * APR_PERCENT, amount: 22e18})
        ]);

        assertAllProvideOrders(markets[1], provider_A, [
            ProvideOrderView({APR: 3 * APR_PERCENT, amount: 33e18})
        ]);
    }

    function test_cancel() public {
        _deposit(provider_A, 60e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 1 * APR_PERCENT, 10e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 2 * APR_PERCENT, 20e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[0], 2 * APR_PERCENT, type(uint128).max);

        assertAllProvideOrders(markets[0], provider_A, [
            ProvideOrderView({APR: 1 * APR_PERCENT, amount: 10e18})
        ]);
    }

    function test_borrow() public {
        _deposit(provider_A, 60e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 1 * APR_PERCENT, 10e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 2 * APR_PERCENT, 20e18);

        _borrow(markets[0], borrower_A, 5e18);

        assertAllProvideOrders(markets[0], provider_A, [
            ProvideOrderView({APR: 1 * APR_PERCENT, amount: 5e18}),
            ProvideOrderView({APR: 2 * APR_PERCENT, amount: 20e18})
        ]);

        _borrow(markets[0], borrower_A, 5e18);

        assertAllProvideOrders(markets[0], provider_A, [
            ProvideOrderView({APR: 2 * APR_PERCENT, amount: 20e18})
        ]);

        _borrow(markets[0], borrower_A, 10e18);

        assertAllProvideOrders(markets[0], provider_A, [
            ProvideOrderView({APR: 2 * APR_PERCENT, amount: 10e18})
        ]);

        _borrow(markets[0], borrower_A, 10e18);

        assertAllProvideOrders(markets[0], provider_A, NONE);
    }

    function test_reloan() public {
        _deposit(provider_A, 60e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 1 * APR_PERCENT, 10e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 2 * APR_PERCENT, 20e18);

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 3 * APR_PERCENT, 11e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 4 * APR_PERCENT, 8.625e18);

        _borrow(markets[0], borrower_A, 20e18);

        assertEq(pool.loanOf(markets[0], provider_A), 20.3e18);
        assertAllProvideOrders(markets[0], provider_A, [
            ProvideOrderView({APR: 2 * APR_PERCENT, amount: 10e18})
        ]);

        assertAllProvideOrders(markets[0], provider_B, [
            ProvideOrderView({APR: 3 * APR_PERCENT, amount: 11e18}),
            ProvideOrderView({APR: 4 * APR_PERCENT, amount: 8.625e18})
        ]);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 1.03e18, 0);

        assertAllProvideOrders(markets[0], provider_B, [
            ProvideOrderView({APR: 3 * APR_PERCENT, amount: 10e18}),
            ProvideOrderView({APR: 4 * APR_PERCENT, amount: 8.625e18})
        ]);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], 10.3e18, 0);

        assertAllProvideOrders(markets[0], provider_B, [
            ProvideOrderView({APR: 4 * APR_PERCENT, amount: 8.625e18})
        ]);

        vm.prank(provider_A); pool.reloan(provider_A, markets[0], type(uint128).max, 0);

        // (20.3 - 1.03 - 10.3) / 1.04 = 8.625
        assertAllProvideOrders(markets[0], provider_B, NONE);
    }


    // helpers

    function assertEq(ProvideOrderView memory expected, ProvideOrderView memory actual) internal pure {
        assertEq(actual.APR, expected.APR, "ProvideOrderView.APR");
        assertApproxEqAbs(actual.amount, expected.amount, 1, "ProvideOrderView.amount");
    }

    function assertAllProvideOrders(uint64 market, address account, ProvideOrderView[] memory expectedOrders) internal view {
        ProvideOrderView[] memory orders = pool.getAllProvideOrders(market, account);
        assertEq(orders.length, expectedOrders.length);

        for (uint256 i = 0; i < orders.length; i++) {
            assertEq(orders[i], expectedOrders[i]);
        }
    }

    function assertAllProvideOrders(uint64 market, address account, NONE_T) internal view {
        ProvideOrderView[] memory e = new ProvideOrderView[](0);
        assertAllProvideOrders(market, account, e);
    }

    function assertAllProvideOrders(uint64 market, address account, ProvideOrderView[1] memory expectedOrders) internal view {
        ProvideOrderView[] memory e = new ProvideOrderView[](expectedOrders.length);
        for (uint256 i = 0; i < expectedOrders.length; i++) e[i] = expectedOrders[i];
        assertAllProvideOrders(market, account, e);
    }

    function assertAllProvideOrders(uint64 market, address account, ProvideOrderView[2] memory expectedOrders) internal view {
        ProvideOrderView[] memory e = new ProvideOrderView[](expectedOrders.length);
        for (uint256 i = 0; i < expectedOrders.length; i++) e[i] = expectedOrders[i];
        assertAllProvideOrders(market, account, e);
    }

    function assertAllProvideOrders(uint64 market, address account, ProvideOrderView[3] memory expectedOrders) internal view {
        ProvideOrderView[] memory e = new ProvideOrderView[](expectedOrders.length);
        for (uint256 i = 0; i < expectedOrders.length; i++) e[i] = expectedOrders[i];
        assertAllProvideOrders(market, account, e);
    }
}

contract TestCreditPool_getAllBorrowOrders is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.maxActiveBorrowOrders = 5;
    }

    function beforeEach() public override {
        _deposit(borrower_A, 1000e18);
        vm.prank(borrower_A); pool.placeProvideOrder(borrower_A, markets[0], 0, 1000e18);
        _borrow(markets[0], borrower_C, 1000e18);

        assertEq(pool.loanOf(markets[0], borrower_A), 1000e18);
    }

    function test_place() public {
        _deposit_collateral(borrower_A, markets[0], 400e18);
        _deposit_collateral(borrower_A, markets[1], 400e18);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 1 * APR_PERCENT, 10e18);
        vm.prank(borrower_A); pool.placeReloanOrder(borrower_A, markets[0], 2 * APR_PERCENT, 20e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[1], 3 * APR_PERCENT, 30e18);

        assertAllBorrowOrders(markets[0], borrower_A, [
            BorrowOrderView({APR: 1 * APR_PERCENT, amount: 10e18, orderType: BOrderType.Borrow}),
            BorrowOrderView({APR: 2 * APR_PERCENT, amount: 20e18, orderType: BOrderType.Reloan})
        ]);

        assertAllBorrowOrders(markets[1], borrower_A, [
            BorrowOrderView({APR: 3 * APR_PERCENT, amount: 30e18, orderType: BOrderType.Borrow})
        ]);
    }

    function test_cancel() public {
        _deposit_collateral(borrower_A, markets[0], 400e18);

        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 1 * APR_PERCENT, 10e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 2 * APR_PERCENT, 20e18);

        vm.prank(borrower_A); pool.cancelBorrowOrder(borrower_A, markets[0], 2 * APR_PERCENT, type(uint128).max);

        assertAllBorrowOrders(markets[0], borrower_A, [
            BorrowOrderView({APR: 1 * APR_PERCENT, amount: 10e18, orderType: BOrderType.Borrow})
        ]);
    }

    function test_provide() public {
        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.placeReloanOrder(borrower_A, markets[0], 0 * APR_PERCENT, 10e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 2 * APR_PERCENT, 20e18);

        _provide(markets[0], provider_A, 5e18);

        assertAllBorrowOrders(markets[0], borrower_A, [
            BorrowOrderView({APR: 0 * APR_PERCENT, amount: 10e18, orderType: BOrderType.Reloan}),
            BorrowOrderView({APR: 2 * APR_PERCENT, amount: 15e18, orderType: BOrderType.Borrow})
        ]);

        _provide(markets[0], provider_A, 15e18);

        assertAllBorrowOrders(markets[0], borrower_A, [
            BorrowOrderView({APR: 0 * APR_PERCENT, amount: 10e18, orderType: BOrderType.Reloan})
        ]);

        _provide(markets[0], provider_A, 5e18);

        assertAllBorrowOrders(markets[0], borrower_A, [
            BorrowOrderView({APR: 0 * APR_PERCENT, amount: 5e18, orderType: BOrderType.Reloan})
        ]);

        _provide(markets[0], provider_A, 5e18);

        assertAllBorrowOrders(markets[0], borrower_A, NONE);
    }


    // helpers

    function assertEq(BorrowOrderView memory expected, BorrowOrderView memory actual) internal pure {
        assertEq(actual.APR, expected.APR, "BorrowOrderView.APR");
        assertEq(actual.amount, expected.amount, "BorrowOrderView.amount");
        assertEq(actual.orderType, expected.orderType, "BorrowOrderView.orderType");
    }

    function assertAllBorrowOrders(uint64 market, address account, BorrowOrderView[] memory expectedOrders) internal view {
        BorrowOrderView[] memory orders = pool.getAllBorrowOrders(market, account);
        assertEq(orders.length, expectedOrders.length);

        for (uint256 i = 0; i < orders.length; i++) {
            assertEq(orders[i], expectedOrders[i]);
        }
    }

    function assertAllBorrowOrders(uint64 market, address account, NONE_T) internal view {
        BorrowOrderView[] memory e = new BorrowOrderView[](0);
        assertAllBorrowOrders(market, account, e);
    }

    function assertAllBorrowOrders(uint64 market, address account, BorrowOrderView[1] memory expectedOrders) internal view {
        BorrowOrderView[] memory e = new BorrowOrderView[](expectedOrders.length);
        for (uint256 i = 0; i < expectedOrders.length; i++) e[i] = expectedOrders[i];
        assertAllBorrowOrders(market, account, e);
    }

    function assertAllBorrowOrders(uint64 market, address account, BorrowOrderView[2] memory expectedOrders) internal view {
        BorrowOrderView[] memory e = new BorrowOrderView[](expectedOrders.length);
        for (uint256 i = 0; i < expectedOrders.length; i++) e[i] = expectedOrders[i];
        assertAllBorrowOrders(market, account, e);
    }

    function assertAllBorrowOrders(uint64 market, address account, BorrowOrderView[3] memory expectedOrders) internal view {
        BorrowOrderView[] memory e = new BorrowOrderView[](expectedOrders.length);
        for (uint256 i = 0; i < expectedOrders.length; i++) e[i] = expectedOrders[i];
        assertAllBorrowOrders(market, account, e);
    }
}

contract TestCreditPool_getUserMarkets is CreditPoolTestSuite {
    function test_tracks_and_paginates_user_markets() public {
        _deposit(provider_A, 100e18);

        assertUserMarkets(provider_A, NONE);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[1], 1 * APR_PERCENT, 10e18);
        assertUserMarkets(provider_A, [markets[1]]);

        _deposit_collateral(provider_A, markets[0], 100e18);
        assertUserMarkets(provider_A, [markets[1], markets[0]]);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, markets[1], 1 * APR_PERCENT, type(uint128).max);
        assertUserMarkets(provider_A, [markets[1], markets[0]]);

        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[1], 0 * APR_PERCENT, 10e18);
        _borrow(markets[1], borrower_A, 10e18);
        assertUserMarkets(provider_A, [markets[1], markets[0]]);

        vm.prank(provider_A); pool.transferLoan(markets[1], provider_B, 10e18);

        assertUserMarkets(provider_A, [markets[1], markets[0]]);
        assertUserMarkets(provider_B, [markets[1]]);

        uint64[] memory page = pool.getUserMarkets(provider_A, 0, 1);
        assertEq(page.length, 1);
        assertEq(page[0], markets[1]);

        page = pool.getUserMarkets(provider_A, 1, 10);
        assertEq(page.length, 1);
        assertEq(page[0], markets[0]);

        assertEq(pool.getUserMarkets(provider_A, 2, 1).length, 0);
        assertEq(pool.getUserMarkets(provider_A, type(uint256).max, 1).length, 0);
        assertEq(pool.getUserMarkets(provider_A, 0, 0).length, 0);
    }

    function test_rollover_registers_target_market() public {
        _deposit(provider_A, 1000e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[1], 0, 200e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[2], 0, 200e18);

        _borrow(markets[0], borrower_A, 100e18);
        vm.prank(borrower_A); pool.withdraw(borrower_A, borrower_A, 100e18);
        vm.prank(borrower_A); asset.burn(100e18);
        assertUserMarkets(borrower_A, [markets[0]]);

        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(
            address(pool), markets[0], true,
            UNIT / 100,
            UNIT / 100
        );
        _approve_rollover_extension(borrower_A);

        skip(YEAR + pool.getLiquidationGracePeriod(markets[0])); priceOracle.touch();

        RolloverSolution memory solution;
        solution.reborrows = new ReborrowSolution[](2);
        solution.reborrows[0] = ReborrowSolution({ market: markets[1], debtPercent: UNIT / 2 });
        solution.reborrows[1] = ReborrowSolution({ market: markets[2], debtPercent: UNIT / 2 });

        _rollover_extension(address(pool), markets[0], borrower_A, address(this), UNIT / 100, solution);

        assertUserMarkets(borrower_A, [markets[0], markets[1], markets[2]]);
    }



    // helpers

    function assertUserMarkets(address account, uint64[] memory expectedMarkets) internal view {
        uint64[] memory markets = pool.getUserMarkets(account, 0, type(uint256).max);
        assertEq(markets.length, expectedMarkets.length);

        for (uint256 i = 0; i < markets.length; i++) {
            assertEq(markets[i], expectedMarkets[i]);
        }
    }

    function assertUserMarkets(address account, NONE_T) internal view {
        uint64[] memory e = new uint64[](0);
        assertUserMarkets(account, e);
    }

    function assertUserMarkets(address account, uint64[1] memory expectedMarkets) internal view {
        uint64[] memory e = new uint64[](expectedMarkets.length);
        for (uint256 i = 0; i < expectedMarkets.length; i++) e[i] = expectedMarkets[i];
        assertUserMarkets(account, e);
    }

    function assertUserMarkets(address account, uint64[2] memory expectedMarkets) internal view {
        uint64[] memory e = new uint64[](expectedMarkets.length);
        for (uint256 i = 0; i < expectedMarkets.length; i++) e[i] = expectedMarkets[i];
        assertUserMarkets(account, e);
    }

    function assertUserMarkets(address account, uint64[3] memory expectedMarkets) internal view {
        uint64[] memory e = new uint64[](expectedMarkets.length);
        for (uint256 i = 0; i < expectedMarkets.length; i++) e[i] = expectedMarkets[i];
        assertUserMarkets(account, e);
    }
}

contract TestCreditPool_getMarketUsers is CreditPoolTestSuite {
    function test_returns_market_users_slice() public {
        _deposit_collateral(provider_A, markets[0], 100e18);
        _deposit_collateral(provider_B, markets[0], 200e18);
        _deposit_collateral(borrower_A, markets[0], 300e18);

        assertMarketUsers(markets[0], 0, 10, [provider_A, provider_B, borrower_A]);
        assertMarketUsers(markets[0], 1, 2, [provider_B, borrower_A]);
        assertMarketUsers(markets[0], 2, 10, [borrower_A]);
        assertMarketUsers(markets[0], 3, 1, NONE);
    }

    function test_deduplicates_market_users() public {
        _deposit_collateral(provider_A, markets[0], 100e18);

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 10e18);

        _deposit(provider_B, 100e18);
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, markets[0], 0, 10e18);
        _borrow(markets[0], borrower_A, 10e18);

        vm.prank(provider_A); pool.transferLoan(markets[0], provider_B, 5e18);

        assertMarketUsers(markets[0], 0, 10, [provider_A, provider_B, borrower_A]);
    }


    // helpers

    function assertMarketUsers(uint64 market, uint256 offset, uint256 limit, address[] memory expectedUsers) internal view {
        address[] memory users = pool.getMarketUsers(market, offset, limit);
        assertEq(users.length, expectedUsers.length);

        for (uint256 i = 0; i < users.length; i++) {
            assertEq(users[i], expectedUsers[i]);
        }
    }

    function assertMarketUsers(uint64 market, uint256 offset, uint256 limit, NONE_T) internal view {
        address[] memory e = new address[](0);
        assertMarketUsers(market, offset, limit, e);
    }

    function assertMarketUsers(uint64 market, uint256 offset, uint256 limit, address[1] memory expectedUsers) internal view {
        address[] memory e = new address[](expectedUsers.length);
        for (uint256 i = 0; i < expectedUsers.length; i++) e[i] = expectedUsers[i];
        assertMarketUsers(market, offset, limit, e);
    }

    function assertMarketUsers(uint64 market, uint256 offset, uint256 limit, address[2] memory expectedUsers) internal view {
        address[] memory e = new address[](expectedUsers.length);
        for (uint256 i = 0; i < expectedUsers.length; i++) e[i] = expectedUsers[i];
        assertMarketUsers(market, offset, limit, e);
    }

    function assertMarketUsers(uint64 market, uint256 offset, uint256 limit, address[3] memory expectedUsers) internal view {
        address[] memory e = new address[](expectedUsers.length);
        for (uint256 i = 0; i < expectedUsers.length; i++) e[i] = expectedUsers[i];
        assertMarketUsers(market, offset, limit, e);
    }
}
