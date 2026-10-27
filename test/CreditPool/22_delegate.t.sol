// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "./0_base.t.sol";

abstract contract DelegateTestHelpers is CreditPoolTestSuite {
    address internal delegate = makeAddr("Delegate");
    address internal recipient = makeAddr("Delegate Recipient");

    function _create_provider_loan() internal {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _borrow(markets[0], borrower_A, 100e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
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

contract TestCreditPool_delegate is DelegateTestHelpers {
    function test_set_delegate_updates_exact_mask_and_revokes() public {
        vm.expectEmit(true, true, false, true, address(pool));
        emit DelegateUpdated(provider_A, delegate, 0, DELEGATE_PROVIDE | DELEGATE_WITHDRAW);
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_PROVIDE | DELEGATE_WITHDRAW);

        assertEq(pool.getDelegateActions(provider_A, delegate), DELEGATE_PROVIDE | DELEGATE_WITHDRAW);
        assertEq(pool.isDelegateApproved(provider_A, delegate, DELEGATE_PROVIDE), true);
        assertEq(pool.isDelegateApproved(provider_A, delegate, DELEGATE_WITHDRAW), true);
        assertEq(pool.isDelegateApproved(provider_A, delegate, DELEGATE_BORROW), false);

        vm.expectEmit(true, true, false, true, address(pool));
        emit DelegateUpdated(provider_A, delegate, DELEGATE_PROVIDE | DELEGATE_WITHDRAW, DELEGATE_WITHDRAW);
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_WITHDRAW);

        assertEq(pool.getDelegateActions(provider_A, delegate), DELEGATE_WITHDRAW);
        assertEq(pool.isDelegateApproved(provider_A, delegate, DELEGATE_PROVIDE), false);
        assertEq(pool.isDelegateApproved(provider_A, delegate, DELEGATE_WITHDRAW), true);

        vm.expectEmit(true, true, false, true, address(pool));
        emit DelegateUpdated(provider_A, delegate, DELEGATE_WITHDRAW, 0);
        vm.prank(provider_A); pool.setDelegate(delegate, 0);

        assertEq(pool.getDelegateActions(provider_A, delegate), 0);
        assertEq(pool.isDelegateApproved(provider_A, delegate, DELEGATE_WITHDRAW), false);
        assertEq(pool.isDelegateApproved(provider_A, provider_A, DELEGATE_ALL), true);
        assertEq(pool.isDelegateApproved(provider_A, delegate, DELEGATE_ALL + 1), false);
    }

    function test_set_delegate_reverts_for_invalid_delegate_and_mask() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidDelegate.selector, address(0)));
        vm.prank(provider_A); pool.setDelegate(address(0), DELEGATE_WITHDRAW);

        vm.expectRevert(abi.encodeWithSelector(InvalidDelegate.selector, provider_A));
        vm.prank(provider_A); pool.setDelegate(provider_A, DELEGATE_WITHDRAW);

        vm.expectRevert(abi.encodeWithSelector(InvalidDelegateActions.selector, DELEGATE_ALL + 1));
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_ALL + 1);
    }

    function test_partial_mask_allows_only_selected_actions() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_WITHDRAW);

        vm.expectRevert(abi.encodeWithSelector(DelegateNotApproved.selector, provider_A, delegate, DELEGATE_PROVIDE));
        vm.prank(delegate); pool.provideExactIn(provider_A, markets[0], 100e18, 0, 10);

        vm.prank(delegate); pool.withdraw(provider_A, recipient, 40e18);

        assertEq(pool.balanceOf(provider_A), 60e18);
        assertEq(asset.balanceOf(recipient), 40e18);

        vm.prank(provider_A); pool.setDelegate(delegate, 0);

        vm.expectRevert(abi.encodeWithSelector(DelegateNotApproved.selector, provider_A, delegate, DELEGATE_WITHDRAW));
        vm.prank(delegate); pool.withdraw(provider_A, recipient, 1e18);

        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        vm.prank(delegate); pool.withdraw(address(0), recipient, 1e18);
    }

    function test_delegate_can_place_and_cancel_provide_order() public {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_PLACE_PROVIDE_ORDER | DELEGATE_CANCEL_PROVIDE_ORDER);

        vm.prank(delegate); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        assertEq(pool.balanceOf(provider_A), 0);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 100e18);

        vm.prank(delegate); pool.cancelProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 40e18);

        assertEq(pool.balanceOf(provider_A), 40e18);
        assertEq(pool.getProvideOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 60e18);
    }

    function test_delegate_can_provide_exact_in_and_withdraw_to_any_recipient() public {
        _deposit(provider_A, 150e18);
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_PROVIDE | DELEGATE_WITHDRAW);

        _place_borrow_order(markets[0], borrower_A, 10 * APR_PERCENT, 100e18);

        vm.prank(delegate); pool.provideExactIn(provider_A, markets[0], 100e18, 110e18, 10);
        vm.prank(delegate); pool.withdraw(provider_A, recipient, 50e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.balanceOf(provider_A), 0);
        assertEq(asset.balanceOf(recipient), 50e18);
    }

    function test_delegate_can_place_and_cancel_borrow_order() public {
        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_PLACE_BORROW_ORDER | DELEGATE_CANCEL_BORROW_ORDER);

        vm.prank(delegate); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 100e18);
        assertEq(uint256(pool.getBorrowOrderType(markets[0], 10 * APR_PERCENT, borrower_A)), uint256(BOrderType.Borrow));

        vm.prank(delegate); pool.cancelBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 40e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, borrower_A), 60e18);
    }

    function test_delegate_can_place_and_cancel_reloan_order() public {
        _create_provider_loan();
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_PLACE_RELOAN_ORDER | DELEGATE_CANCEL_RELOAN_ORDER);

        vm.prank(delegate); pool.placeReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 50e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 50e18);
        assertEq(uint256(pool.getBorrowOrderType(markets[0], 10 * APR_PERCENT, provider_A)), uint256(BOrderType.Reloan));

        vm.prank(delegate); pool.cancelReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 20e18);

        assertEq(pool.getBorrowOrderBalance(markets[0], 10 * APR_PERCENT, provider_A), 30e18);
    }

    function test_cancel_reloan_order_requires_explicit_reloan_cancel_role() public {
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_CANCEL_BORROW_ORDER);

        vm.expectRevert(abi.encodeWithSelector(DelegateNotApproved.selector, provider_A, delegate, DELEGATE_CANCEL_RELOAN_ORDER));
        vm.prank(delegate); pool.cancelReloanOrder(provider_A, markets[0], 10 * APR_PERCENT, 1e18);
    }

    function test_delegate_can_borrow_and_repay_from_account_balance() public {
        _place_provide_order(markets[0], provider_A, 10 * APR_PERCENT, 100e18);
        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_BORROW | DELEGATE_REPAY);

        vm.prank(delegate); pool.borrow(borrower_A, markets[0], 100e18, 110e18);

        assertEq(pool.balanceOf(borrower_A), 100e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);

        _deposit(borrower_A, 10e18);
        vm.prank(delegate); pool.repay(borrower_A, borrower_A, markets[0], 110e18);

        assertEq(pool.balanceOf(borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
    }

    function test_repay_another_borrower_from_own_balance() public {
        _create_provider_loan();
        _deposit(recipient, 110e18);

        vm.prank(recipient); pool.repay(recipient, borrower_A, markets[0], 40e18);

        assertEq(pool.balanceOf(recipient), 70e18);
        assertEq(pool.balanceOf(borrower_A), 100e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 70e18);
        assertEq(pool.getAvailableToClaim(markets[0]), 40e18);

        vm.prank(recipient); pool.repay(recipient, borrower_A, markets[0], type(uint128).max);

        assertEq(pool.balanceOf(recipient), 0);
        assertEq(pool.balanceOf(borrower_A), 100e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 400e18);
        assertEq(pool.getAvailableToClaim(markets[0]), 110e18);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
    }

    function test_delegate_can_repay_another_borrower_from_account_balance() public {
        _create_provider_loan();
        _deposit(recipient, 110e18);
        vm.prank(recipient); pool.setDelegate(delegate, DELEGATE_REPAY_ANY);

        vm.expectEmit(true, true, true, true, address(pool));
        emit DebtRepaid(recipient, borrower_A, markets[0], 110e18);
        vm.prank(delegate); pool.repay(recipient, borrower_A, markets[0], type(uint128).max);

        assertEq(pool.balanceOf(recipient), 0);
        assertEq(pool.balanceOf(borrower_A), 100e18);
        assertEq(pool.balanceOf(delegate), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.getAvailableToClaim(markets[0]), 110e18);
    }

    function test_repay_requires_permission_from_payer_not_borrower() public {
        _create_provider_loan();
        _deposit(recipient, 110e18);
        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_REPAY_ANY);

        vm.expectRevert(abi.encodeWithSelector(DelegateNotApproved.selector, recipient, delegate, DELEGATE_REPAY_ANY));
        vm.prank(delegate); pool.repay(recipient, borrower_A, markets[0], 110e18);

        vm.prank(recipient); pool.setDelegate(delegate, DELEGATE_BORROW);
        vm.expectRevert(abi.encodeWithSelector(DelegateNotApproved.selector, recipient, delegate, DELEGATE_REPAY_ANY));
        vm.prank(delegate); pool.repay(recipient, borrower_A, markets[0], 110e18);

        assertEq(pool.balanceOf(recipient), 110e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.getAvailableToClaim(markets[0]), 0);
    }

    function test_repay_permission_cannot_spend_account_balance_on_another_borrower() public {
        _create_provider_loan();
        _deposit(recipient, 110e18);
        vm.prank(recipient); pool.setDelegate(delegate, DELEGATE_REPAY);

        vm.expectRevert(abi.encodeWithSelector(DelegateNotApproved.selector, recipient, delegate, DELEGATE_REPAY_ANY));
        vm.prank(delegate); pool.repay(recipient, borrower_A, markets[0], 110e18);

        assertEq(pool.balanceOf(recipient), 110e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.getAvailableToClaim(markets[0]), 0);
    }

    function test_legacy_all_permissions_do_not_allow_repaying_another_borrower() public {
        _create_provider_loan();
        _deposit(recipient, 110e18);
        vm.prank(recipient); pool.setDelegate(delegate, (1 << 15) - 1);

        vm.expectRevert(abi.encodeWithSelector(DelegateNotApproved.selector, recipient, delegate, DELEGATE_REPAY_ANY));
        vm.prank(delegate); pool.repay(recipient, borrower_A, markets[0], 110e18);

        assertEq(pool.balanceOf(recipient), 110e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
    }

    function test_repay_any_permission_can_be_restricted_to_own_debt() public {
        _create_provider_loan();
        _deposit(borrower_A, 10e18);
        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_REPAY_ANY);

        vm.prank(delegate); pool.repay(borrower_A, borrower_A, markets[0], 40e18);
        assertEq(pool.balanceOf(borrower_A), 70e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 70e18);

        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_REPAY);

        vm.expectRevert(abi.encodeWithSelector(DelegateNotApproved.selector, borrower_A, delegate, DELEGATE_REPAY_ANY));
        vm.prank(delegate); pool.repay(borrower_A, recipient, markets[0], 1);

        vm.prank(delegate); pool.repay(borrower_A, borrower_A, markets[0], type(uint128).max);
        assertEq(pool.balanceOf(borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.getAvailableToClaim(markets[0]), 110e18);
    }

    function test_repay_cannot_use_borrower_balance_when_payer_has_insufficient_funds() public {
        _create_provider_loan();
        _deposit(recipient, 1e18);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 40e18, 1, 1e18));
        vm.prank(recipient); pool.repay(recipient, borrower_A, markets[0], 40e18);

        assertEq(pool.balanceOf(recipient), 1e18);
        assertEq(pool.balanceOf(borrower_A), 100e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.getAvailableToClaim(markets[0]), 0);
    }

    function test_repay_another_borrower_clears_expired_dust_without_oracle() public {
        _create_provider_loan();
        _deposit(borrower_A, 10e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 110e18 - 1);
        _deposit(recipient, 1);
        skip(YEAR + 1 days);

        vm.prank(recipient); pool.repay(recipient, borrower_A, markets[0], type(uint128).max);

        assertEq(pool.balanceOf(recipient), 0);
        assertEq(pool.balanceOf(borrower_A), 1);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 400e18);
        assertEq(pool.getAvailableToClaim(markets[0]), 110e18);
        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
    }

    function test_repay_rejects_zero_payer_and_borrower() public {
        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        vm.prank(recipient); pool.repay(address(0), borrower_A, markets[0], 1);

        vm.expectRevert(abi.encodeWithSelector(InvalidAccount.selector, address(0)));
        vm.prank(recipient); pool.repay(recipient, address(0), markets[0], 1);
    }

    function test_delegate_can_claim_finalized_loan() public {
        _create_provider_loan();

        _deposit(borrower_A, 10e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 110e18);

        skip(YEAR);

        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_CLAIM);
        vm.prank(delegate); pool.claim(provider_A, markets[0], type(uint128).max);

        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.balanceOf(provider_A), 110e18);
        assertEq(pool.balanceOf(delegate), 0);
    }

    function test_delegate_can_reloan_owned_loan() public {
        _create_provider_loan();

        _place_provide_order(markets[0], provider_B, 5 * APR_PERCENT, 100e18);
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_RELOAN);

        vm.prank(delegate); pool.reloan(provider_A, markets[0], 52.5e18, 50e18);

        assertEq(pool.loanOf(markets[0], provider_A), 57.5e18);
        assertEq(pool.balanceOf(provider_A), 50e18);
        assertEq(pool.loanOf(markets[0], provider_B), 52.5e18);
        assertEq(pool.balanceOf(delegate), 0);
    }

    function test_delegate_can_offset_owned_loan_against_debt() public {
        _create_provider_loan();
        vm.prank(provider_A); pool.transferLoan(markets[0], borrower_A, 55e18);
        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_OFFSET);

        vm.prank(delegate); pool.offset(borrower_A, markets[0], type(uint128).max);

        assertEq(pool.loanOf(markets[0], borrower_A), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 55e18);
    }

    function test_delegate_can_withdraw_collateral_to_any_recipient() public {
        _deposit_collateral(borrower_A, markets[0], 300e18);
        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_WITHDRAW_COLLATERAL);

        vm.prank(delegate); pool.withdrawCollateral(borrower_A, markets[0], recipient, 75e18);

        assertEq(pool.collateralOf(markets[0], borrower_A), 225e18);
        assertEq(collateral.balanceOf(recipient), 75e18);
    }

    function test_move_collateral_has_dedicated_delegate_action() public {
        _deposit_collateral(borrower_A, markets[0], 100e18);
        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_WITHDRAW_COLLATERAL);

        vm.expectRevert(abi.encodeWithSelector(
            DelegateNotApproved.selector,
            borrower_A,
            delegate,
            DELEGATE_MOVE_COLLATERAL
        ));
        vm.prank(delegate); pool.moveCollateral(borrower_A, markets[0], markets[1], 40e18);

        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_MOVE_COLLATERAL);
        vm.prank(delegate); pool.moveCollateral(borrower_A, markets[0], markets[1], 40e18);

        vm.expectRevert(abi.encodeWithSelector(
            DelegateNotApproved.selector,
            borrower_A,
            delegate,
            DELEGATE_WITHDRAW_COLLATERAL
        ));
        vm.prank(delegate); pool.withdrawCollateral(borrower_A, markets[0], recipient, 1e18);

        assertEq(pool.collateralOf(markets[0], borrower_A), 60e18);
        assertEq(pool.collateralOf(markets[1], borrower_A), 40e18);
        assertEq(collateral.balanceOf(recipient), 0);
    }

    function test_permissionless_deposit_and_deposit_collateral_credit_target() public {
        _mint(delegate, 25e18);
        vm.prank(delegate); pool.deposit(provider_A, 25e18);

        _mint_collateral(delegate, 50e18);
        vm.prank(delegate); pool.depositCollateral(borrower_A, markets[0], 50e18);

        assertEq(pool.balanceOf(provider_A), 25e18);
        assertEq(pool.balanceOf(delegate), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 50e18);
        assertEq(pool.collateralOf(markets[0], delegate), 0);
    }

    function test_transfer_loan_is_self_only_even_with_all_delegate_actions() public {
        _create_provider_loan();
        vm.prank(provider_A); pool.setDelegate(delegate, DELEGATE_ALL);

        vm.expectRevert(abi.encodeWithSelector(AmountIsOutOfRange.selector, 1e18, 1, 0));
        vm.prank(delegate); pool.transferLoan(markets[0], recipient, 1e18);

        assertEq(pool.loanOf(markets[0], provider_A), 110e18);
        assertEq(pool.loanOf(markets[0], recipient), 0);
    }

    function test_rollover_config_is_personal_not_delegated() public {
        vm.prank(borrower_A); pool.setDelegate(delegate, DELEGATE_ALL);
        vm.prank(delegate); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, UNIT / 2, UNIT / 100);

        (bool borrowerEnabled, uint256 borrowerMaxDebtFactor, uint256 borrowerKeeperFee) =
            rolloverExtension.getRolloverConfig(address(pool), markets[0], borrower_A);
        (bool delegateEnabled, uint256 delegateMaxDebtFactor, uint256 delegateKeeperFee) =
            rolloverExtension.getRolloverConfig(address(pool), markets[0], delegate);

        assertEq(borrowerEnabled, false);
        assertEq(borrowerMaxDebtFactor, 0);
        assertEq(borrowerKeeperFee, 0);
        assertEq(delegateEnabled, true);
        assertEq(delegateMaxDebtFactor, UNIT / 2);
        assertEq(delegateKeeperFee, UNIT / 100);
    }
}

contract TestCreditPool_delegate_sweep is DelegateTestHelpers {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT / 200; // 0.5%
    }

    function test_sweep_is_permissionless_and_credits_target_account() public {
        _place_provide_order(markets[0], provider_B, 6 * APR_PERCENT, 200e18);
        _place_provide_order(markets[0], provider_A, 5 * APR_PERCENT, 150e18);

        _place_borrow_order(markets[0], borrower_A, 6 * APR_PERCENT, 130e18);
        _place_borrow_order(markets[0], borrower_B, 4 * APR_PERCENT, 200e18);

        vm.prank(delegate); pool.sweep(provider_C, markets[0], 106e18, 10);

        // D = 106*1.05 = 111.3; X0 = D/1.06 = 105; S = 1; first-leg fee = 5.3*0.5% = 0.0265.
        // v = floor(0.005*111.3/(0.995*106+0.005*111.3), 18 decimals) = 0.005248687828042989.
        // N = ceil(S*v, wei); K = floor(N*1.06/(1+0.06*(1-v)), wei) = 0.005250247653191188.
        // Y = ceil(K/1.06, wei) = 0.004953063823765272; reward = 1-Y; owner loan = 0.0265+K.
        assertEq(pool.balanceOf(provider_C), 0.995046936176234728e18);
        assertEq(pool.balanceOf(address(this)), 0);
        assertEq(pool.loanOf(markets[0], address(this)), 0.031750247653191188e18);
        assertEq(pool.balanceOf(delegate), 0);
    }
}
