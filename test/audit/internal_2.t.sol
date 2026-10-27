// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { CreditPoolTestSuite } from "test/CreditPool/0_base.t.sol";
import { Test } from "lib/forge-std/src/Test.sol";
import { MockV3Aggregator } from "lib/chainlink-local/src/data-feeds/MockV3Aggregator.sol";
import { IPermit2 } from "lib/permit2/src/interfaces/IPermit2.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { ChainlinkPriceOracle } from "src/ChainlinkPriceOracle.sol";
import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolRolloverExtension } from "src/CreditPoolRolloverExtension.sol";
import { CreditPoolFacet1 } from "src/facets/CreditPoolFacet1.sol";
import { CreditPoolFacet2 } from "src/facets/CreditPoolFacet2.sol";
import { CreditPoolFacet3 } from "src/facets/CreditPoolFacet3.sol";
import { CreditPoolFacet4 } from "src/facets/CreditPoolFacet4.sol";
import { ICreditPoolFactory } from "src/interfaces/ICreditPoolFactory.sol";
import { ICreditPoolErrors, ICreditPoolEvents, ICreditPoolTypes } from "src/interfaces/ICreditPool.sol";
import { ICreditPoolRolloverExtension } from "src/interfaces/ICreditPoolRolloverExtension.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";
import { MarketsConfigParams } from "src/lib/MarketsConfig.sol";

import { MockPriceOracle } from "test/mocks/MockPriceOracle.sol";
import { MockToken } from "test/mocks/MockToken.sol";
import {
    MockVariablePosition,
    MockVariableUnderlyingPoolAdapter
} from "test/mocks/MockVariableUnderlyingPoolAdapter.sol";

contract UnbackedRolloverPoolMock {
    address internal immutable _asset;
    uint128 internal immutable _debt;

    constructor(address asset_, uint128 debt_) {
        _asset = asset_;
        _debt = debt_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function debtOf(uint64, address) external view returns (uint128) {
        return _debt;
    }

    function loanOf(uint64, address) external view returns (uint128) {
        return _debt * 2;
    }

    function getMarketBalance(uint64) external view returns (uint128) {
        return _debt;
    }

    function balanceOf(address) external pure returns (uint128) {
        return 0;
    }

    function offset(address, uint64, uint128) external pure {}

    function claim(address, uint64, uint128) external pure {}

    function withdraw(address, address, uint128) external pure {}
}

contract AccountTransferRolloverPoolMock {
    address internal immutable _asset;
    uint128 internal immutable _debt;

    constructor(address asset_, uint128 debt_) {
        _asset = asset_;
        _debt = debt_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    function debtOf(uint64, address) external view returns (uint128) {
        return _debt;
    }

    function loanOf(uint64, address) external pure returns (uint128) {
        return 0;
    }

    function getMarketBalance(uint64) external pure returns (uint128) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint128) {
        return 0;
    }
}

contract NoOpPermit2Mock {
    function allowance(address, address, address) external pure returns (uint160 amount, uint48 expiration, uint48 nonce) {
        return (type(uint160).max, type(uint48).max, 0);
    }

    function transferFrom(address, address, uint160, address) external pure {}
}

contract TestAudit2_rollover is CreditPoolTestSuite {
    uint256 internal constant KEEPER_FEE = UNIT / 100;

    function reconfigure(InitializationParams memory params) internal pure override {
        params.liquidationGracePeriod = 0;
        params.marketsConfig.active[0] = 5;
        params.marketsConfig.active[1] = 5;
        params.marketsConfig.active[2] = 5;
    }

    function test_unregistered_rollover_pool_is_rejected() public {
        address untrustedAccount = makeAddr("Unregistered rollover account");
        UnbackedRolloverPoolMock unbackedPool = new UnbackedRolloverPoolMock(address(asset), 10e18);

        vm.expectRevert(abi.encodeWithSelector(InvalidPool.selector, address(unbackedPool)));
        vm.prank(untrustedAccount); rolloverExtension.setRolloverConfig(address(unbackedPool), 0, true, 0, UNIT);
    }

    function test_rollover_fee_claim_requires_backed_token_receipt() public {
        address honestRecipient = makeAddr("Honest fee recipient");
        address untrustedAccount = makeAddr("Untrusted rollover account");

        _seed_honest_fee(honestRecipient);

        assertEq(asset.balanceOf(address(rolloverExtension)), 10e18);
        assertEq(rolloverExtension.getCollectedFee(address(asset), honestRecipient), 10e18);

        UnbackedRolloverPoolMock unbackedPool = new UnbackedRolloverPoolMock(address(asset), 10e18);
        rolloverFactory.setPool(address(unbackedPool), true);
        vm.prank(untrustedAccount); rolloverExtension.setRolloverConfig(address(unbackedPool), 0, true, 0, UNIT);

        ICreditPoolRolloverExtension.RolloverSolution memory solution;
        vm.expectRevert(abi.encodeWithSelector(TokenReceiptMismatch.selector, address(asset), 10e18, 0));
        rolloverExtension.rollover(address(unbackedPool), 0, untrustedAccount, untrustedAccount, UNIT, solution);

        assertEq(asset.balanceOf(address(rolloverExtension)), 10e18);
        assertEq(rolloverExtension.getCollectedFee(address(asset), untrustedAccount), 0);
        assertEq(asset.balanceOf(untrustedAccount), 0);
        assertEq(rolloverExtension.getCollectedFee(address(asset), honestRecipient), 10e18);

        vm.prank(honestRecipient); rolloverExtension.withdrawFee(address(asset), honestRecipient, 10e18);

        assertEq(asset.balanceOf(honestRecipient), 10e18);
        assertEq(asset.balanceOf(address(rolloverExtension)), 0);
        assertEq(rolloverExtension.getCollectedFee(address(asset), honestRecipient), 0);
    }

    function test_fuzz_rollover_fee_liability_never_exceeds_received_backing(uint128 rawUnbackedFee) public {
        address honestRecipient = makeAddr("Honest fuzz fee recipient");
        address untrustedAccount = makeAddr("Fuzz untrusted rollover account");
        uint128 unbackedFee = uint128(bound(rawUnbackedFee, 1, 10e18));

        _seed_honest_fee(honestRecipient);

        UnbackedRolloverPoolMock unbackedPool = new UnbackedRolloverPoolMock(address(asset), unbackedFee);
        rolloverFactory.setPool(address(unbackedPool), true);
        bool configured = _try_configure_untrusted_pool(untrustedAccount, address(unbackedPool));
        if (configured) _try_rollover_untrusted_pool(untrustedAccount, address(unbackedPool));

        assertEq(rolloverExtension.getCollectedFee(address(asset), untrustedAccount), 0);
        assertEq(asset.balanceOf(address(rolloverExtension)), 10e18);
        assertEq(asset.balanceOf(untrustedAccount), 0);
        assertEq(rolloverExtension.getCollectedFee(address(asset), honestRecipient), 10e18);
    }

    function test_account_transfer_requires_exact_token_receipt_before_pool_allowance() public {
        address untrustedAccount = makeAddr("No-op Permit2 account");
        NoOpPermit2Mock noOpPermit2 = new NoOpPermit2Mock();
        CreditPoolRolloverExtension noOpPermitExtension =
            new CreditPoolRolloverExtension(IPermit2(address(noOpPermit2)), ICreditPoolFactory(address(rolloverFactory)));
        AccountTransferRolloverPoolMock unbackedPool = new AccountTransferRolloverPoolMock(address(asset), 10e18);
        rolloverFactory.setPool(address(unbackedPool), true);

        vm.prank(untrustedAccount); asset.mint(20e18);
        vm.prank(untrustedAccount); noOpPermitExtension.setRolloverConfig(address(unbackedPool), 0, true, 0, UNIT);

        ICreditPoolRolloverExtension.RolloverSolution memory solution;
        vm.expectRevert(abi.encodeWithSelector(TokenReceiptMismatch.selector, address(asset), 20e18, 0));
        noOpPermitExtension.rollover(address(unbackedPool), 0, untrustedAccount, untrustedAccount, UNIT, solution);

        assertEq(asset.balanceOf(address(noOpPermitExtension)), 0);
        assertEq(asset.allowance(address(noOpPermitExtension), address(unbackedPool)), 0);
    }

    function _try_configure_untrusted_pool(address account, address unbackedPool) private returns (bool configured) {
        bytes memory callData = abi.encodeWithSelector(
            rolloverExtension.setRolloverConfig.selector,
            unbackedPool,
            uint64(0),
            true,
            uint256(0),
            UNIT
        );
        vm.prank(account); (configured,) = address(rolloverExtension).call(callData);
    }

    function _try_rollover_untrusted_pool(address account, address unbackedPool) private {
        RolloverSolution memory solution;
        bytes memory callData = abi.encodeWithSelector(
            rolloverExtension.rollover.selector,
            unbackedPool,
            uint64(0),
            account,
            account,
            UNIT,
            solution
        );
        (bool succeeded,) = address(rolloverExtension).call(callData);
        if (!succeeded) return;
    }

    function _seed_honest_fee(address feeRecipient) internal {
        vm.prank(borrower_A); rolloverExtension.setRolloverConfig(address(pool), markets[0], true, 0, KEEPER_FEE);
        _approve_rollover_extension(borrower_A);

        _deposit(provider_A, 1000e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 1000e18);
        _deposit_collateral(borrower_A, markets[0], 4000e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 1000e18, type(uint128).max);
        _withdraw_and_burn(borrower_A, 1000e18);

        _deposit_collateral(borrower_A, markets[0], 4040e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 0, 1010e18);
        _deposit(provider_B, 1010e18);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 1010e18, 0, 10);
        _deposit(borrower_A, 1010e18);
        vm.prank(borrower_A); pool.repay(borrower_A, borrower_A, markets[0], 1010e18);

        skip(YEAR);
        priceOracle.touch();

        RolloverSolution memory solution;
        _rollover_extension(address(pool), markets[0], borrower_A, feeRecipient, KEEPER_FEE, solution);
    }
}

contract TestAudit2_reloan_cleanup is CreditPoolTestSuite {
    function test_offset_removes_reloan_orders_when_backing_is_burned() public {
        _deposit_collateral(provider_B, markets[0], 400e18);
        vm.prank(provider_B); pool.placeBorrowOrder(provider_B, markets[0], 0, 100e18);

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 100e18, 100e18, 1);

        _deposit_collateral(provider_A, markets[0], 400e18);
        vm.prank(provider_A); pool.placeBorrowOrder(provider_A, markets[0], 0, 100e18);
        vm.prank(provider_B); pool.provideExactIn(provider_B, markets[0], 100e18, 100e18, 1);

        vm.prank(provider_A); pool.placeReloanOrder(provider_A, markets[0], MAX_APR, 100e18);
        vm.prank(provider_B); pool.placeReloanOrder(provider_B, markets[0], MAX_APR, 100e18);

        vm.prank(provider_A); pool.offset(provider_A, markets[0], 100e18);
        vm.prank(provider_B); pool.offset(provider_B, markets[0], 100e18);
        vm.prank(provider_A); pool.withdrawCollateral(provider_A, markets[0], provider_A, 400e18);
        vm.prank(provider_B); pool.withdrawCollateral(provider_B, markets[0], provider_B, 400e18);
        vm.prank(provider_A); pool.withdraw(provider_A, provider_A, 100e18);

        assertEq(pool.debtOf(markets[0], provider_A), 0);
        assertEq(pool.debtOf(markets[0], provider_B), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_B), 0);
        assertEq(pool.collateralOf(markets[0], provider_A), 0);
        assertEq(pool.collateralOf(markets[0], provider_B), 0);
        assertEq(asset.balanceOf(provider_A), 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], MAX_APR, provider_A), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], MAX_APR, provider_B), 0);

        _deposit_collateral(borrower_C, markets[0], 400e18);
        vm.prank(borrower_C); pool.placeBorrowOrder(borrower_C, markets[0], 0, 100e18);
        _deposit(provider_D, 100e18);

        vm.prank(provider_D); pool.provideExactOut(provider_D, markets[0], 100e18, 100e18, 1);

        assertEq(pool.debtOf(markets[0], borrower_C), 100e18);
        assertEq(pool.getBorrowOrderBalance(markets[0], MAX_APR, provider_A), 0);
        assertEq(pool.getBorrowOrderBalance(markets[0], MAX_APR, provider_B), 0);
    }

    function test_fuzz_offset_removes_reloan_order_when_backing_is_burned(uint96 rawAmount) public {
        uint128 amount = uint128(bound(rawAmount, 2e18, 1e24));

        _deposit(provider_A, amount);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, amount);
        _deposit_collateral(borrower_A, markets[0], amount * 4);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], amount, amount);
        vm.prank(provider_A); pool.transferLoan(markets[0], borrower_A, amount);
        vm.prank(borrower_A); pool.placeReloanOrder(borrower_A, markets[0], MAX_APR, amount);

        vm.prank(borrower_A); pool.offset(borrower_A, markets[0], amount);
        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, amount * 4);
        vm.prank(borrower_A); pool.withdraw(borrower_A, borrower_A, amount);

        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], borrower_A), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 0);
        assertEq(asset.balanceOf(borrower_A), amount);
        assertEq(pool.getBorrowOrderBalance(markets[0], MAX_APR, borrower_A), 0);
    }
}

contract TestAudit2_provided_event is CreditPoolTestSuite {
    function reconfigure(InitializationParams memory params) internal pure override {
        params.protocolFee = UNIT / 10;
    }

    function test_provided_event_matches_provider_balance_debit() public {
        _deposit_collateral(borrower_A, markets[0], 400e18);
        vm.prank(borrower_A); pool.placeBorrowOrder(borrower_A, markets[0], 10 * APR_PERCENT, 100e18);
        _deposit(provider_A, 100e18);

        OrderFill[] memory fills = new OrderFill[](1);
        fills[0] = OrderFill(borrower_A, 10 * APR_PERCENT, 100e18, 110e18, false);
        vm.expectEmit(true, true, false, true, address(pool));
        emit Provided(provider_A, markets[0], 100e18, 109e18, fills, new InvalidatedBorrowOrder[](0), new ReconciledReloanOrder[](0));
        vm.prank(provider_A); pool.provideExactIn(provider_A, markets[0], 100e18, 109e18, 1);

        assertEq(pool.balanceOf(provider_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 109e18);
        assertEq(pool.loanOf(markets[0], address(this)), 1e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
    }
}

contract NemesisVariableUnderlyingPoolCreditPool is CreditPool {
    constructor(ICreditPoolTypes.InitializationParams memory params, address[] memory facets)
        CreditPool(params, facets)
    {}

    function underlyingPoolGeneration() external view returns (uint64) {
        return _underlyingPoolGeneration;
    }

    function underlyingPoolReserve() external view returns (uint256) {
        return _underlyingPoolReserve;
    }

    function underlyingPoolIndex() external view returns (uint256) {
        return _globalUnderlyingPoolIndex;
    }
}

// Problem: a near-total loss can leave a nonzero but precision-exhausted underlying index. Minting fresh
// liquidity in that generation lets a later partial loss round the index to zero and erase the fresh claim.
//
// Solution: after the actual underlying deposit and before minting porder shares, require the global index to
// cover all active underlying assets. An unsafe placement reverts atomically, so the provider keeps the funds on
// its internal balance. Once active assets reach zero, advance the generation and reset the index to SCALE. If
// exactly one raw asset unit remains, the owner can withdraw it as backed protocol fee before the reset; larger
// residuals cannot be confiscated and keep new placements frozen.
contract TestAudit2_underlying_index is Test, ICreditPoolEvents {
    uint64 private constant YEAR = 365 days;
    uint256 private constant UNIT = 1e18;

    MockToken private asset;
    MockVariablePosition private positionSource;
    MockVariableUnderlyingPoolAdapter private adapter;
    NemesisVariableUnderlyingPoolCreditPool private pool;

    uint64 private market;

    address private provider_A = makeAddr("Provider A");
    address private provider_B = makeAddr("Provider B");
    address private provider_C = makeAddr("Provider C");

    function setUp() public {
        vm.warp(1);

        asset = new MockToken();
        MockToken collateral = new MockToken();
        MockPriceOracle priceOracle = new MockPriceOracle(address(collateral), address(asset));
        positionSource = new MockVariablePosition(address(asset));
        adapter = new MockVariableUnderlyingPoolAdapter();

        address[] memory facets = new address[](4);
        facets[0] = address(new CreditPoolFacet1());
        facets[1] = address(new CreditPoolFacet2());
        facets[2] = address(new CreditPoolFacet3());
        facets[3] = address(new CreditPoolFacet4());

        ICreditPoolTypes.InitializationParams memory params = ICreditPoolTypes.InitializationParams({
            owner: address(this),
            permit2: address(1),
            asset: address(asset),
            underlyingPool: UnderlyingPoolConfig({
                adapter: address(adapter),
                config: bytes32(uint256(uint160(address(positionSource))))
            }),
            priceOracle: address(priceOracle),
            collateral: address(collateral),
            stalePriceWindow: 24 hours,
            protocolFee: 0,
            totalCollateralCap: type(uint128).max,
            provideOrderMinAmount: 1,
            borrowOrderMinAmount: 1,
            maxActiveProvideOrders: 8,
            maxActiveBorrowOrders: 1,
            borrowLTV: UNIT * 50 / 100,
            liquidationLTV: UNIT * 50 / 100,
            liquidationDiscountMin: UNIT * 5 / 100,
            liquidationDiscountMax: UNIT * 20 / 100,
            liquidationGracePeriod: 1 days,
            minDebtRemainingAfterLiquidation: 1,
            marketsConfig: MarketsConfigParams({
                durations: [YEAR, YEAR, YEAR],
                active: [uint8(3), 3, 3],
                extensions: [uint64(0), 0, 0]
            })
        });

        pool = new NemesisVariableUnderlyingPoolCreditPool(params, facets);
        market = uint64(block.timestamp + YEAR);
    }

    function test_recapitalized_liquidity_tracks_followup_loss_proportionally() public {
        _deposit_and_place(provider_A, 0, 1e27);

        positionSource.rebase(address(pool), -(1e27 - 1));
        _deposit(provider_B, 100e18);

        vm.expectRevert(abi.encodeWithSelector(
            ICreditPoolErrors.UnderlyingPoolIndexPrecisionExhausted.selector,
            1,
            100e18 + 1
        ));
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, 5, 100e18);

        assertEq(pool.balanceOf(provider_B), 100e18);
        assertEq(positionSource.position(address(pool)), 1);

        vm.expectEmit(false, false, false, true, address(pool));
        emit UnderlyingPoolDustSettled(1, 1);
        pool.settleUnderlyingPoolDust();

        assertEq(pool.balanceOf(address(this)), 1);
        assertEq(asset.balanceOf(address(pool)), 100e18 + 1);
        assertEq(positionSource.position(address(pool)), 0);
        assertEq(pool.underlyingPoolGeneration(), 1);
        assertEq(pool.underlyingPoolIndex(), 1e27);
        assertEq(pool.underlyingPoolReserve(), 0);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 0);

        pool.withdraw(address(this), address(this), 1);
        assertEq(pool.balanceOf(address(this)), 0);
        assertEq(asset.balanceOf(address(this)), 1);

        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, 5, 100e18);
        assertEq(pool.getProvideOrderBalance(market, 5, provider_B), 100e18);

        positionSource.rebase(address(pool), -1e18);

        assertEq(pool.getProvideOrderBalance(market, 5, provider_B), 99e18);

        _deposit_and_place(provider_C, 10, 1e18);

        assertEq(pool.getProvideOrderBalance(market, 5, provider_B), 99e18);
        assertEq(pool.getProvideOrderBalance(market, 10, provider_C), 1e18);
        assertEq(positionSource.position(address(pool)), 100e18);
    }

    function test_fuzz_recapitalized_liquidity_survives_partial_followup_loss(uint96 rawDeposit, uint96 rawLoss) public {
        uint128 depositAmount = uint128(bound(rawDeposit, 2, 1e24));
        uint128 lossAmount = uint128(bound(rawLoss, 1, depositAmount - 1));

        _deposit_and_place(provider_A, 0, 1e27);
        positionSource.rebase(address(pool), -(1e27 - 1));
        _deposit(provider_B, depositAmount);

        vm.expectRevert(abi.encodeWithSelector(
            ICreditPoolErrors.UnderlyingPoolIndexPrecisionExhausted.selector,
            1,
            uint256(depositAmount) + 1
        ));
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, 5, depositAmount);

        assertEq(pool.balanceOf(provider_B), depositAmount);

        pool.settleUnderlyingPoolDust();
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, 5, depositAmount);

        assertEq(pool.getProvideOrderBalance(market, 5, provider_B), depositAmount);

        positionSource.rebase(address(pool), -int256(uint256(lossAmount)));

        uint128 expectedBalance = depositAmount - lossAmount;
        uint128 previewBalance = pool.getProvideOrderBalance(market, 5, provider_B);
        // Flooring the index and then the claim can lose at most one raw unit for this bounded deposit range.
        assertLe(previewBalance, expectedBalance);
        assertGe(previewBalance, expectedBalance - 1);

        _deposit_and_place(provider_C, 10, 1);

        uint128 committedBalance = pool.getProvideOrderBalance(market, 5, provider_B);
        assertLe(committedBalance, expectedBalance);
        assertGe(committedBalance, expectedBalance - 1);
        assertEq(pool.getProvideOrderBalance(market, 10, provider_C), 1);
    }

    function test_representability_boundary_allows_equal_and_rejects_index_plus_one() public {
        _deposit_and_place(provider_A, 0, 1e27);
        _deposit(provider_B, 1);

        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 1e27);
        assertEq(pool.underlyingPoolIndex(), 1e27);

        vm.expectRevert(abi.encodeWithSelector(
            ICreditPoolErrors.UnderlyingPoolIndexPrecisionExhausted.selector,
            1e27,
            1e27 + 1
        ));
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, 5, 1);

        assertEq(pool.balanceOf(provider_B), 1);
        assertEq(positionSource.position(address(pool)), 1e27);
    }

    function test_dust_settlement_rejects_zero_and_more_than_one_active_asset() public {
        vm.expectRevert(abi.encodeWithSelector(
            ICreditPoolErrors.UnderlyingPoolDustSettlementUnavailable.selector,
            1e27,
            0,
            1
        ));
        pool.settleUnderlyingPoolDust();

        _deposit_and_place(provider_A, 0, 1e27);
        positionSource.rebase(address(pool), -(1e27 - 2));

        vm.expectRevert(abi.encodeWithSelector(
            ICreditPoolErrors.UnderlyingPoolDustSettlementUnavailable.selector,
            2,
            2,
            1
        ));
        pool.settleUnderlyingPoolDust();

        _deposit(provider_B, 1);
        vm.expectRevert(abi.encodeWithSelector(
            ICreditPoolErrors.UnderlyingPoolIndexPrecisionExhausted.selector,
            2,
            3
        ));
        vm.prank(provider_B); pool.placeProvideOrder(provider_B, market, 5, 1);

        assertEq(pool.balanceOf(provider_B), 1);
        assertEq(positionSource.position(address(pool)), 2);
    }

    function test_only_owner_can_settle_underlying_pool_dust() public {
        _deposit_and_place(provider_A, 0, 1e27);
        positionSource.rebase(address(pool), -(1e27 - 1));

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", provider_B));
        vm.prank(provider_B); pool.settleUnderlyingPoolDust();

        assertEq(positionSource.position(address(pool)), 1);
        assertEq(pool.balanceOf(address(this)), 0);
    }

    function _deposit(address provider, uint128 amount) private {
        vm.prank(provider); asset.mint(amount);
        vm.prank(provider); asset.approve(address(pool), amount);
        vm.prank(provider); pool.deposit(provider, amount);
    }

    function _deposit_and_place(address provider, uint256 APR, uint128 amount) private {
        _deposit(provider, amount);
        vm.prank(provider); pool.placeProvideOrder(provider, market, APR, amount);
    }
}

contract NemesisMockToken6 is MockToken {
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract TestAudit2_zero_rate is Test {
    uint64 private constant YEAR = 365 days;
    uint256 private constant UNIT = 1e18;

    NemesisMockToken6 private asset;
    MockToken private collateral;
    MockV3Aggregator private sourceFeed;
    MockV3Aggregator private targetFeed;
    ChainlinkPriceOracle private priceOracle;
    NemesisVariableUnderlyingPoolCreditPool private pool;

    uint64 private market;

    address private provider = makeAddr("Zero rate provider");
    address private borrower = makeAddr("Zero rate borrower");
    address private liquidator = makeAddr("Zero rate liquidator");

    function setUp() public {
        vm.warp(1);

        asset = new NemesisMockToken6();
        collateral = new MockToken();
        sourceFeed = new MockV3Aggregator(8, 2_000_000);
        targetFeed = new MockV3Aggregator(8, 2_000_000_000_000);
        priceOracle = new ChainlinkPriceOracle({
            _source: address(collateral),
            _target: address(asset),
            _sourceFeed: address(sourceFeed),
            _targetFeed: address(targetFeed)
        });

        MockVariablePosition positionSource = new MockVariablePosition(address(asset));
        MockVariableUnderlyingPoolAdapter adapter = new MockVariableUnderlyingPoolAdapter();

        address[] memory facets = new address[](4);
        facets[0] = address(new CreditPoolFacet1());
        facets[1] = address(new CreditPoolFacet2());
        facets[2] = address(new CreditPoolFacet3());
        facets[3] = address(new CreditPoolFacet4());

        ICreditPoolTypes.InitializationParams memory params = ICreditPoolTypes.InitializationParams({
            owner: address(this),
            permit2: address(1),
            asset: address(asset),
            underlyingPool: UnderlyingPoolConfig({
                adapter: address(adapter),
                config: bytes32(uint256(uint160(address(positionSource))))
            }),
            priceOracle: address(priceOracle),
            collateral: address(collateral),
            stalePriceWindow: 24 hours,
            protocolFee: 0,
            totalCollateralCap: type(uint128).max,
            provideOrderMinAmount: 1,
            borrowOrderMinAmount: 1,
            maxActiveProvideOrders: 8,
            maxActiveBorrowOrders: 1,
            borrowLTV: UNIT * 50 / 100,
            liquidationLTV: UNIT * 50 / 100,
            liquidationDiscountMin: UNIT * 5 / 100,
            liquidationDiscountMax: UNIT * 20 / 100,
            liquidationGracePeriod: 1 days,
            minDebtRemainingAfterLiquidation: 1,
            marketsConfig: MarketsConfigParams({
                durations: [YEAR, YEAR, YEAR],
                active: [uint8(3), 3, 3],
                extensions: [uint64(0), 0, 0]
            })
        });

        pool = new NemesisVariableUnderlyingPoolCreditPool(params, facets);
        market = uint64(block.timestamp + YEAR);
    }

    function test_fractional_price_preserves_full_position_value() public {
        _open_position();

        sourceFeed.updateAnswer(1_000_000);
        IPriceOracle.Price memory price = priceOracle.getPrice();

        assertEq(price.numerator, 1_000_000);
        assertEq(price.denominator, 2e24);
        assertEq(Math.mulDiv(4e24, price.numerator, price.denominator), 2e6);
        assertEq(pool.getHealthFactor(market, borrower), 1e18);
        assertEq(pool.isLiquidatable(market, borrower), false);

        vm.expectRevert(ICreditPoolErrors.NotLiquidatable.selector);
        vm.prank(liquidator); pool.liquidate(market, borrower, 1e6, 0, type(uint256).max, "");

        sourceFeed.updateAnswer(900_000);
        assertEq(pool.getHealthFactor(market, borrower), 0.9e18);
        assertEq(pool.isLiquidatable(market, borrower), true);

        vm.prank(liquidator); asset.mint(1e6);
        vm.prank(liquidator); asset.approve(address(pool), 1e6);
        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 1);
        vm.prank(liquidator); pool.liquidate(market, borrower, 1e6, 0, type(uint256).max, "");

        assertEq(pool.debtOf(market, borrower), 0);
        assertEq(pool.collateralOf(market, borrower), 1385620915032679738562090);
    }

    function test_fuzz_fractional_price_matches_full_position_value(uint64 rawAnswer) public {
        uint256 answer = bound(rawAnswer, 1, 1_999_999);

        _open_position();
        sourceFeed.updateAnswer(int256(answer));

        IPriceOracle.Price memory price = priceOracle.getPrice();
        uint256 collateralValue = Math.mulDiv(4e24, price.numerator, price.denominator);
        uint256 expectedHealthFactor = Math.mulDiv(0.5e18, collateralValue, 1e6);

        assertEq(pool.getHealthFactor(market, borrower), expectedHealthFactor);

        if (expectedHealthFactor >= UNIT) {
            assertEq(pool.isLiquidatable(market, borrower), false);
            return;
        }

        assertEq(pool.isLiquidatable(market, borrower), true);
        vm.prank(liquidator); asset.mint(1e6);
        vm.prank(liquidator); asset.approve(address(pool), 1e6);
        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 1);
        vm.prank(liquidator); pool.liquidate(market, borrower, 1e6, 0, type(uint256).max, "");

        uint256 expectedCollateralSeized = 4e24;
        if (collateralValue >= 1e6) {
            uint256 discount = Math.min(0.2e18, 0.05e18 + UNIT - expectedHealthFactor);
            expectedCollateralSeized = Math.mulDiv(1e6, price.denominator, price.numerator, Math.Rounding.Ceil);
            expectedCollateralSeized = Math.min(
                4e24,
                Math.mulDiv(expectedCollateralSeized, UNIT, UNIT - discount, Math.Rounding.Ceil)
            );
        }

        assertEq(pool.debtOf(market, borrower), 0);
        assertEq(pool.collateralOf(market, borrower), 4e24 - expectedCollateralSeized);
    }

    function test_full_position_quote_zero_rejects_liquidation() public {
        _open_position();
        sourceFeed.updateAnswer(1);
        targetFeed.updateAnswer(1e18);

        IPriceOracle.Price memory price = priceOracle.getPrice();
        assertEq(Math.mulDiv(4e24, price.numerator, price.denominator), 0);
        assertEq(pool.getHealthFactor(market, borrower), 0);
        assertEq(pool.isLiquidatable(market, borrower), true);

        vm.prank(liquidator); asset.mint(1e6);
        vm.prank(liquidator); asset.approve(address(pool), 1e6);
        vm.expectCall(address(priceOracle), abi.encodeCall(IPriceOracle.getPrice, ()), 1);
        vm.expectRevert(ICreditPoolErrors.NoDebtToLiquidate.selector);
        vm.prank(liquidator); pool.liquidate(market, borrower, 1e6, 0, type(uint256).max, "");

        assertEq(pool.debtOf(market, borrower), 1e6);
        assertEq(pool.collateralOf(market, borrower), 4e24);
    }

    function _open_position() private {
        vm.prank(provider); asset.mint(1e6);
        vm.prank(provider); asset.approve(address(pool), 1e6);
        vm.prank(provider); pool.deposit(provider, 1e6);
        vm.prank(provider); pool.placeProvideOrder(provider, market, 0, 1e6);

        vm.prank(borrower); collateral.mint(4e24);
        vm.prank(borrower); collateral.approve(address(pool), 4e24);
        vm.prank(borrower); pool.depositCollateral(borrower, market, 4e24);
        vm.prank(borrower); pool.borrow(borrower, market, 1e6, 1e6);

        assertEq(pool.getHealthFactor(market, borrower), 2e18);
    }

}
