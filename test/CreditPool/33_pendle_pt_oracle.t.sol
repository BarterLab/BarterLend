// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { ICreditPool, ICreditPoolTypes, ICreditPoolErrors, ICreditPoolBotAPI } from "src/interfaces/ICreditPool.sol";
import { UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";
import { MarketsConfigParams } from "src/lib/MarketsConfig.sol";
import { AaveV3Adapter } from "src/adapters/AaveV3Adapter.sol";
import { PendlePtPriceOracle } from "src/PendlePtPriceOracle.sol";
import { MockToken } from "test/mocks/MockToken.sol";
import { MockAaveToken } from "test/mocks/MockAaveToken.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";
import { MockPriceOracle } from "test/mocks/MockPriceOracle.sol";
import { MockPendleToken, MockPendlePT, MockPendleSY, MockPendleYT, MockPendleMarket, MockPendleOracle } from "test/mocks/MockPendle.sol";

contract TestCreditPool_pendle_pt_oracle is Test {
    ICreditPool internal pool;
    MockToken internal loan;
    MockPendlePT internal pt;
    MockPendleSY internal sy;
    MockPriceOracle internal conversion;
    MockPendleMarket internal pendleMarket;
    MockPendleOracle internal pendleOracle;
    uint64 internal market;

    address internal lender = makeAddr("Lender");
    address internal borrower = makeAddr("Borrower");
    address internal liquidator = makeAddr("Liquidator");

    function setUp() public {
        vm.warp(1);
        market = uint64(block.timestamp + 365 days);
        loan = new MockToken();
        MockPendleToken accounting = new MockPendleToken(18);
        sy = new MockPendleSY(address(accounting), 18, 6);
        pt = new MockPendlePT(18);
        MockPendleYT yt = new MockPendleYT(address(pt), address(sy));
        pt.setTokens(address(sy), address(yt));
        conversion = new MockPriceOracle(address(accounting), address(loan));
        pendleMarket = new MockPendleMarket(address(sy), address(pt), address(yt));
        pendleOracle = new MockPendleOracle();
        PendlePtPriceOracle oracle = new PendlePtPriceOracle(address(pt), address(conversion), address(pendleOracle), address(pendleMarket), 1800, 0.01e18, 0.05e18);

        MockAaveToken aToken = new MockAaveToken(loan, 0);
        new MockAavePool(loan, aToken);
        AaveV3Adapter adapter = new AaveV3Adapter();
        address[] memory facets = new address[](4);
        facets[0] = deployCode("src/facets/CreditPoolFacet1.sol:CreditPoolFacet1");
        facets[1] = deployCode("src/facets/CreditPoolFacet2.sol:CreditPoolFacet2");
        facets[2] = deployCode("src/facets/CreditPoolFacet3.sol:CreditPoolFacet3");
        facets[3] = deployCode("src/facets/CreditPoolFacet4.sol:CreditPoolFacet4");
        ICreditPoolTypes.InitializationParams memory params = ICreditPoolTypes.InitializationParams({
            owner: address(this),
            permit2: makeAddr("Unused Permit2"),
            asset: address(loan),
            underlyingPool: UnderlyingPoolConfig(address(adapter), bytes32(uint256(uint160(address(aToken))))),
            priceOracle: address(oracle),
            collateral: address(pt),
            stalePriceWindow: 1 days,
            protocolFee: 0,
            totalCollateralCap: type(uint128).max,
            provideOrderMinAmount: 1e18,
            borrowOrderMinAmount: 1e18,
            maxActiveProvideOrders: 8,
            maxActiveBorrowOrders: 1,
            borrowLTV: 0.9e18,
            liquidationLTV: 0.95e18,
            liquidationDiscountMin: 0.005e18,
            liquidationDiscountMax: 0.02e18,
            liquidationGracePeriod: 1 days,
            minDebtRemainingAfterLiquidation: 1e18,
            marketsConfig: MarketsConfigParams({
                durations: [uint64(365 days), uint64(365 days), uint64(365 days)],
                active: [uint8(3), 3, 3],
                extensions: [uint64(0), 0, 0]
            })
        });
        pool = ICreditPool(deployCode("src/CreditPool.sol:CreditPool", abi.encode(params, facets)));
        _deposit(lender, 1000e18);
        vm.prank(lender); pool.placeProvideOrder(lender, market, 2000, 1000e18);
        vm.prank(borrower); pt.mint(100e18);
        vm.prank(borrower); pt.approve(address(pool), 100e18);
        vm.prank(borrower); pool.depositCollateral(borrower, market, 100e18);
    }

    function test_face_value_limit_caps_full_debt_including_interest() public {
        (uint128 principal, uint128 debt) = pool.previewBorrow(market, 75e18, borrower);
        assertEq(principal, 75e18);
        assertEq(debt, 90e18);
        vm.expectRevert(abi.encodeWithSelector(ICreditPoolErrors.UnhealthyDebt.selector, uint256(986842105263157894)));
        vm.prank(borrower); pool.borrow(borrower, market, 76e18, 92e18);
        vm.prank(borrower); pool.borrow(borrower, market, 75e18, 90e18);
        assertEq(pool.balanceOf(borrower), 75e18);
        assertEq(pool.debtOf(market, borrower), 90e18);
        assertEq(pool.loanOf(market, lender), 90e18);
        assertEq(pool.getHealthFactor(market, borrower), 1055555555555555555);
    }

    function test_backing_decline_triggers_liquidation_before_pt_maturity() public {
        vm.prank(borrower); pool.borrow(borrower, market, 75e18, 90e18);
        assertEq(pool.isLiquidatable(market, borrower), false);
        sy.setExchangeRate(0.9e18);
        assertEq(pool.getHealthFactor(market, borrower), 0.95e18);
        assertEq(pool.isLiquidatable(market, borrower), true);
        assertLt(block.timestamp, pt.expiry());
    }

    function test_fx_decline_reduces_health_factor() public {
        vm.prank(borrower); pool.borrow(borrower, market, 75e18, 90e18);
        conversion.setPriceFraction(9, 10);
        assertEq(pool.getHealthFactor(market, borrower), 0.95e18);
        assertEq(pool.isLiquidatable(market, borrower), true);
    }

    function test_hybrid_price_is_used_to_seize_collateral() public {
        vm.prank(borrower); pool.borrow(borrower, market, 75e18, 90e18);
        sy.setExchangeRate(0.9e18);
        vm.mockCall(address(pendleOracle), abi.encodeCall(MockPendleOracle.getPtToAssetRate, (address(pendleMarket), uint32(1800))), abi.encode(uint256(0.8e18)));
        vm.prank(liquidator); loan.mint(100e18);
        vm.prank(liquidator); loan.approve(address(pool), 100e18);
        vm.prank(liquidator); ICreditPoolBotAPI(address(pool)).liquidate(market, borrower, 90e18, 0, type(uint256).max, "");
        assertEq(pt.balanceOf(liquidator), 100e18);
        assertEq(loan.balanceOf(liquidator), 21.6e18);
        assertEq(pool.debtOf(market, borrower), 0);
        assertEq(pool.collateralOf(market, borrower), 0);
        assertEq(pool.loanOf(market, lender), 78.4e18);
    }

    function test_core_rejects_stale_conversion_timestamp() public {
        vm.prank(borrower); pool.borrow(borrower, market, 75e18, 90e18);
        vm.warp(1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ICreditPoolErrors.StaleOraclePrice.selector, uint256(1)));
        pool.getHealthFactor(market, borrower);
    }

    function test_core_rejects_zero_backing_price() public {
        vm.prank(borrower); pool.borrow(borrower, market, 75e18, 90e18);
        sy.setExchangeRate(0);
        vm.expectRevert(abi.encodeWithSelector(ICreditPoolErrors.InvalidOraclePrice.selector, uint256(0), uint256(1e36)));
        pool.getHealthFactor(market, borrower);
        vm.expectRevert(abi.encodeWithSelector(ICreditPoolErrors.InvalidOraclePrice.selector, uint256(0), uint256(1e36)));
        ICreditPoolBotAPI(address(pool)).liquidate(market, borrower, 90e18, 0, type(uint256).max, "");
    }

    function test_repayment_and_collateral_withdrawal_remain_available_at_zero_price() public {
        vm.prank(borrower); pool.borrow(borrower, market, 75e18, 90e18);
        sy.setExchangeRate(0);
        _deposit(borrower, 15e18);
        vm.prank(borrower); pool.repay(borrower, borrower, market, 90e18);
        vm.prank(borrower); pool.withdrawCollateral(borrower, market, borrower, 100e18);
        assertEq(pool.debtOf(market, borrower), 0);
        assertEq(pool.collateralOf(market, borrower), 0);
        assertEq(pt.balanceOf(borrower), 100e18);
    }

    function _deposit(address account, uint128 amount) internal {
        vm.prank(account); loan.mint(amount);
        vm.prank(account); loan.approve(address(pool), amount);
        vm.prank(account); pool.deposit(account, amount);
    }
}
