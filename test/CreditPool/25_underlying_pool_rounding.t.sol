// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";

import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolFacet1 } from "src/facets/CreditPoolFacet1.sol";
import { CreditPoolFacet2 } from "src/facets/CreditPoolFacet2.sol";
import { CreditPoolFacet3 } from "src/facets/CreditPoolFacet3.sol";
import { CreditPoolFacet4 } from "src/facets/CreditPoolFacet4.sol";
import { ICreditPoolErrors, ICreditPoolTypes } from "src/interfaces/ICreditPool.sol";
import { UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";
import { MarketsConfigParams } from "src/lib/MarketsConfig.sol";

import { MockPriceOracle } from "test/mocks/MockPriceOracle.sol";
import { MockToken } from "test/mocks/MockToken.sol";
import {
    MockVariablePosition,
    MockVariableUnderlyingPoolAdapter
} from "test/mocks/MockVariableUnderlyingPoolAdapter.sol";

contract VariableUnderlyingPoolCreditPool is CreditPool {
    constructor(ICreditPoolTypes.InitializationParams memory params, address[] memory facets)
        CreditPool(params, facets)
    { }

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

contract TestCreditPool_underlying_pool_rounding is Test {
    uint64 private constant YEAR = 365 days;
    uint256 private constant UNIT = 1e18;

    MockToken private asset;
    MockVariablePosition private positionSource;
    MockVariableUnderlyingPoolAdapter private adapter;
    VariableUnderlyingPoolCreditPool private pool;

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

        pool = new VariableUnderlyingPoolCreditPool(params, facets);
        market = uint64(block.timestamp + YEAR);
    }

    function test_deposit_loss_credits_actual_position_increase() public {
        positionSource.setDepositLoss(1e18);

        _deposit_and_place(provider_A, 100e18);

        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 99e18);
        assertEq(pool.balanceOf(provider_A), 0);
        assertEq(asset.balanceOf(address(pool)), 0);
        assertEq(positionSource.position(address(pool)), 99e18);
    }

    function test_withdrawal_cost_is_socialized_to_remaining_idle_liquidity() public {
        positionSource.setDepositLoss(1e18);
        _deposit_and_place(provider_A, 100e18);
        positionSource.setWithdrawAdjustment(1e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, market, 0, 40e18);

        // floor(59e18 * floor(SCALE * 58 / 59) / SCALE)
        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 58e18 - 1);
        assertEq(pool.balanceOf(provider_A), 40e18);
        assertEq(positionSource.position(address(pool)), 58e18);
    }

    function test_withdrawal_gain_increases_remaining_idle_liquidity() public {
        _deposit_and_place(provider_A, 100e18);
        positionSource.setWithdrawAdjustment(-1e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, market, 0, 40e18);

        // The underlying index and virtual shares each round down by at most one asset unit.
        assertApproxEqAbs(pool.getProvideOrderBalance(market, 0, provider_A), 61e18, 2);
        assertEq(pool.balanceOf(provider_A), 40e18);
        assertEq(positionSource.position(address(pool)), 61e18);
    }

    function test_full_loss_recovery_stays_reserve_and_active_shares_receive_later_pnl() public {
        _deposit_and_place(provider_A, 100e18);
        positionSource.setWithdrawAdjustment(60e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, market, 0, 40e18);

        assertEq(pool.underlyingPoolGeneration(), 1);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 0);
        assertEq(positionSource.position(address(pool)), 0);

        positionSource.setWithdrawAdjustment(0);
        positionSource.rebase(address(pool), 30e18);
        _deposit_and_place(provider_B, 50e18);

        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_B), 50e18);
        assertEq(positionSource.position(address(pool)), 80e18);
        assertEq(pool.underlyingPoolReserve(), 30e18);

        positionSource.rebase(address(pool), 30e18);

        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 0);
        assertApproxEqAbs(pool.getProvideOrderBalance(market, 0, provider_B), 80e18, 1);
        assertEq(positionSource.position(address(pool)), 110e18);
        assertEq(pool.underlyingPoolReserve(), 30e18);

        positionSource.rebase(address(pool), -20e18);

        assertApproxEqAbs(pool.getProvideOrderBalance(market, 0, provider_B), 60e18, 1);
        assertEq(positionSource.position(address(pool)), 90e18);
        assertEq(pool.underlyingPoolReserve(), 30e18);
    }

    function test_full_cancel_to_zero_preserves_generation_and_next_deposit() public {
        _deposit_and_place(provider_A, 100e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, market, 0, 100e18);

        assertEq(pool.underlyingPoolGeneration(), 0);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 0);
        assertEq(positionSource.position(address(pool)), 0);

        _deposit_and_place(provider_B, 50e18);

        assertEq(pool.underlyingPoolGeneration(), 0);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_B), 50e18);
        assertEq(positionSource.position(address(pool)), 50e18);
    }

    function test_full_cancel_after_loss_starts_new_generation() public {
        _deposit_and_place(provider_A, 100e18);
        positionSource.rebase(address(pool), -50e18);

        vm.prank(provider_A); pool.cancelProvideOrder(provider_A, market, 0, 50e18);

        assertEq(pool.underlyingPoolGeneration(), 1);
        assertEq(pool.underlyingPoolIndex(), 1e27);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 0);
        assertEq(positionSource.position(address(pool)), 0);

        _deposit_and_place(provider_B, 50e18);

        assertEq(pool.underlyingPoolGeneration(), 1);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_B), 50e18);
        assertEq(positionSource.position(address(pool)), 50e18);
    }

    function test_near_total_loss_does_not_let_zero_value_shares_dilute_new_deposit() public {
        _deposit_and_place(provider_A, 0, 100e18);
        _deposit_and_place(provider_B, 5, 100e18);

        positionSource.rebase(address(pool), -(200e18 - 1));
        vm.prank(provider_C); asset.mint(100e18);
        vm.prank(provider_C); asset.approve(address(pool), 100e18);
        vm.prank(provider_C); pool.deposit(provider_C, 100e18);

        vm.expectRevert(abi.encodeWithSelector(
            ICreditPoolErrors.UnderlyingPoolIndexPrecisionExhausted.selector,
            5_000_000,
            100e18 + 1
        ));
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, market, 0, 100e18);

        assertEq(pool.balanceOf(provider_C), 100e18);
        assertEq(positionSource.position(address(pool)), 1);

        pool.settleUnderlyingPoolDust();
        vm.prank(provider_C); pool.placeProvideOrder(provider_C, market, 0, 100e18);

        assertEq(pool.underlyingPoolGeneration(), 1);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_A), 0);
        assertEq(pool.getProvideOrderBalance(market, 5, provider_B), 0);
        assertEq(pool.getProvideOrderBalance(market, 0, provider_C), 100e18);
        assertEq(positionSource.position(address(pool)), 100e18);
        assertEq(pool.balanceOf(address(this)), 1);
    }

    function _deposit_and_place(address provider, uint128 amount) private {
        _deposit_and_place(provider, 0, amount);
    }

    function _deposit_and_place(address provider, uint256 APR, uint128 amount) private {
        vm.prank(provider); asset.mint(amount);
        vm.prank(provider); asset.approve(address(pool), amount);
        vm.prank(provider); pool.deposit(provider, amount);
        vm.prank(provider); pool.placeProvideOrder(provider, market, APR, amount);
    }
}
