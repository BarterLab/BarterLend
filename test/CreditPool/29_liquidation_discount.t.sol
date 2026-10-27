// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { CreditPool } from "src/CreditPool.sol";

import { CreditPoolTestSuite } from "./0_base.t.sol";

contract TestCreditPool_liquidation_discount is CreditPoolTestSuite {
    address internal liquidator = makeAddr("Liquidator");

    function reconfigure(InitializationParams memory params) internal pure override {
        params.minDebtRemainingAfterLiquidation = 1;
    }

    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 0, 100e18);
        _deposit_collateral(borrower_A, markets[0], 250e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 100e18);
        _mint(liquidator, 100e18);
    }

    function test_collateral_exhaustion_caps_repayment_and_socializes_discount_shortfall() public {
        priceOracle.setPrice(0.44e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 100e18, 0, type(uint256).max, "");
        assertEq(asset.balanceOf(liquidator), 12e18);
        assertEq(collateral.balanceOf(liquidator), 250e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
        assertEq(pool.loanOf(markets[0], provider_A), 88e18);
        assertEq(pool.getMarketBalance(markets[0]), 88e18);
    }

    function test_exhausted_collateral_caps_payment_even_when_value_is_below_debt() public {
        priceOracle.setPrice(0.36e18);
        vm.expectEmit(true, true, true, true, address(pool));
        emit Liquidated(liquidator, borrower_A, markets[0], 72e18, 250e18);
        vm.expectEmit(true, true, false, true, address(pool));
        emit BadDebtIncurred(borrower_A, markets[0], 28e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, type(uint128).max, 0.2e18, block.timestamp, "");
        assertEq(asset.balanceOf(liquidator), 28e18);
        assertEq(pool.loanOf(markets[0], provider_A), 72e18);
    }

    function test_deadline_is_inclusive_and_expired_liquidation_reverts() public {
        priceOracle.setPrice(0.44e18);
        vm.expectRevert(abi.encodeWithSelector(LiquidationExpired.selector, block.timestamp - 1));
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 100e18, 0, block.timestamp - 1, "");
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 100e18, 0, block.timestamp, "");
        assertEq(asset.balanceOf(liquidator), 12e18);
    }

    function test_minimum_discount_rejects_improved_health_factor() public {
        priceOracle.setPrice(0.72e18);
        vm.expectRevert(abi.encodeWithSelector(LiquidationDiscountTooLow.selector, 0.15e18, 0.2e18));
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 100e18, 0.2e18, block.timestamp, "");
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 100e18, 0.15e18, block.timestamp, "");
        assertEq(asset.balanceOf(liquidator), 0);
        assertEq(pool.debtOf(markets[0], borrower_A), 0);
    }

    function test_partial_liquidation_keeps_requested_payment_and_rounded_seizure() public {
        priceOracle.setPrice(0.44e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 44e18, 0.2e18, block.timestamp, "");
        assertEq(asset.balanceOf(liquidator), 56e18);
        assertEq(collateral.balanceOf(liquidator), 125e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 56e18);
        assertEq(pool.loanOf(markets[0], provider_A), 100e18);
    }

    function test_collateral_exhaustion_rounds_payment_down() public {
        priceOracle.setPriceFraction(6, 250e18);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 5, 0.2e18, block.timestamp, "");
        assertEq(asset.balanceOf(liquidator), 100e18 - 4);
        assertEq(collateral.balanceOf(liquidator), 250e18);
        assertEq(pool.loanOf(markets[0], provider_A), 4);
    }

    function test_equal_rounded_recovery_cannot_leave_unrecoverable_collateral() public {
        priceOracle.setPriceFraction(6, 250e18);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidationAmount.selector, 100e18 - 4, 0, 1));
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 4, 0.2e18, block.timestamp, "");
        assertEq(asset.balanceOf(liquidator), 100e18);
        assertEq(collateral.balanceOf(liquidator), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 250e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 100e18);
    }

    function test_fractional_value_cannot_leave_unrecoverable_collateral() public {
        priceOracle.setPriceFraction(69, 2500e18);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidationAmount.selector, 100e18 - 5, 0, 1));
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 5, 0.2e18, block.timestamp, "");
        assertEq(asset.balanceOf(liquidator), 100e18);
        assertEq(collateral.balanceOf(liquidator), 0);
        assertEq(pool.collateralOf(markets[0], borrower_A), 250e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 100e18);
        assertEq(pool.loanOf(markets[0], provider_A), 100e18);
    }

    function test_rounding_exhaustion_never_increases_requested_payment() public {
        priceOracle.setPriceFraction(400e18, 1);
        vm.prank(borrower_A); pool.withdrawCollateral(borrower_A, markets[0], borrower_A, 250e18 - 1);
        priceOracle.setPriceFraction(100e18, 1);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 1, 0.2e18, block.timestamp, "");
        assertEq(asset.balanceOf(liquidator), 100e18 - 1);
        assertEq(collateral.balanceOf(liquidator), 1);
        assertEq(pool.loanOf(markets[0], provider_A), 1);
    }

    function test_zero_discounted_recovery_reverts_without_charging_one_raw_unit() public {
        priceOracle.setPriceFraction(1, 250e18);
        vm.expectRevert(NoDebtToLiquidate.selector);
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, 1, 0, block.timestamp, "");
        assertEq(asset.balanceOf(liquidator), 100e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 250e18);
        assertEq(pool.debtOf(markets[0], borrower_A), 100e18);
    }

    function test_callback_receives_actual_payment_and_seizure() public {
        LiquidationDiscountCallback receiver = new LiquidationDiscountCallback(pool);
        _mint(address(receiver), 100e18);
        priceOracle.setPrice(0.44e18);
        receiver.execute(markets[0], borrower_A);
        assertEq(receiver.debtAmount(), 88e18);
        assertEq(receiver.collateralAmount(), 250e18);
        assertEq(asset.balanceOf(address(receiver)), 12e18);
        assertEq(collateral.balanceOf(address(receiver)), 250e18);
    }

    function test_fuzz_discount_and_loss_accounting(uint80 numeratorSeed, uint80 denominatorSeed, uint128 repaymentSeed) public {
        uint256 denominator = bound(denominatorSeed, 100, 1e24);
        uint256 numerator = bound(numeratorSeed, 1, denominator * 79 / 100);
        uint128 requested = uint128(bound(repaymentSeed, 1, 100e18));
        priceOracle.setPriceFraction(numerator, denominator);
        uint256 discount = Math.min(0.2e18, 1.05e18 - pool.getHealthFactor(markets[0], borrower_A));
        uint256 recovery = Math.mulDiv(Math.mulDiv(250e18, numerator, denominator), UNIT - discount, UNIT);
        if (recovery == 0) {
            vm.expectRevert(NoDebtToLiquidate.selector);
            vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, requested, discount, block.timestamp, "");
            return;
        }
        uint256 requestedCollateral = Math.mulDiv(
            Math.mulDiv(requested, denominator, numerator, Math.Rounding.Ceil), UNIT, UNIT - discount, Math.Rounding.Ceil
        );
        // At a 20% maximum discount, at least 2 raw asset units are needed to recover 1.
        if (requested < 100e18 && requestedCollateral < 250e18 && Math.mulDiv(250e18 - requestedCollateral, numerator, denominator) < 2) {
            uint256 remainingCollateralValue = Math.mulDiv(250e18 - requestedCollateral, numerator, denominator);
            vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidationAmount.selector, 100e18 - requested, remainingCollateralValue, 1));
            vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, requested, discount, block.timestamp, "");
            return;
        }
        vm.prank(liquidator); pool.liquidate(markets[0], borrower_A, requested, discount, block.timestamp, "");
        uint256 paid = 100e18 - asset.balanceOf(liquidator);
        uint256 seized = collateral.balanceOf(liquidator);
        // Exact rational oracle value; bounded inputs keep both cross-products within uint256.
        assertLe(paid * denominator * UNIT, seized * numerator * (UNIT - discount));
        assertEq(pool.getMarketBalance(markets[0]), paid);
        if (seized == 250e18) {
            assertEq(paid, Math.min(requested, recovery));
            assertEq(pool.debtOf(markets[0], borrower_A), 0);
            assertEq(pool.loanOf(markets[0], provider_A), paid);
        } else {
            assertEq(paid, requested);
            assertEq(pool.debtOf(markets[0], borrower_A), 100e18 - paid);
            assertEq(pool.loanOf(markets[0], provider_A), 100e18);
        }
    }
}

contract LiquidationDiscountCallback {
    CreditPool internal immutable pool;
    uint128 public debtAmount;
    uint128 public collateralAmount;

    constructor(CreditPool pool_) { pool = pool_; }

    function execute(uint64 market, address borrower) external {
        pool.liquidate(market, borrower, 100e18, 0.2e18, block.timestamp, "callback");
    }

    function liquidateCallback(uint128 debtAmount_, uint128 collateralAmount_, bytes calldata) external {
        require(msg.sender == address(pool));
        debtAmount = debtAmount_;
        collateralAmount = collateralAmount_;
    }
}
