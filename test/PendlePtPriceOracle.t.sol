// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { MockV3Aggregator } from "lib/chainlink-local/src/data-feeds/MockV3Aggregator.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { PriceMath } from "src/lib/PriceMath.sol";
import { ChainlinkPriceOracle } from "src/ChainlinkPriceOracle.sol";
import { PendlePtPriceOracle } from "src/PendlePtPriceOracle.sol";
import { MockPriceOracle } from "test/mocks/MockPriceOracle.sol";
import { MockPendleToken, MockPendlePT, MockPendleSY, MockPendleYT, MockPendleMarket, MockPendleOracle } from "test/mocks/MockPendle.sol";

contract PendlePtPriceOracleTest is Test {
    using PriceMath for IPriceOracle.Price;

    MockPendleToken internal accounting;
    MockPendlePT internal pt;
    MockPendleSY internal sy;
    MockPendleYT internal yt;
    MockPendleMarket internal pendleMarket;
    MockPendleOracle internal pendleOracle;
    PendlePtPriceOracle internal oracle;

    function setUp() public {
        vm.warp(100);
        accounting = new MockPendleToken(6);
        sy = new MockPendleSY(address(accounting), 6, 18);
        pt = new MockPendlePT(6);
        yt = new MockPendleYT(address(pt), address(sy));
        pt.setTokens(address(sy), address(yt));
        pendleMarket = new MockPendleMarket(address(sy), address(pt), address(yt));
        pendleOracle = new MockPendleOracle();
        oracle = _deployOracle(address(pt), address(0));
    }

    function test_derives_accounting_pair_from_pt() public view {
        assertEq(oracle.source(), address(pt));
        assertEq(oracle.target(), address(accounting));
        assertEq(oracle.accountingToken(), address(accounting));
        assertEq(address(oracle.sy()), address(sy));
        assertEq(address(oracle.yt()), address(yt));
        assertEq(address(oracle.conversionOracle()), address(0));
    }

    function test_prices_healthy_backing_at_nominal() public view {
        IPriceOracle.Price memory price = oracle.getPrice();
        assertEq(price.quoteSourceToTarget(12e6), 12e6);
        assertEq(price.numerator, 1);
        assertEq(price.denominator, 1);
        assertEq(price.updatedAt, 100);
    }

    function test_caps_appreciation_at_nominal() public {
        sy.setExchangeRate(1.3e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 12e6);
    }

    function test_blends_backing_with_twap_at_midpoint() public {
        oracle = _deployHybrid(address(0));
        sy.setExchangeRate(0.97e18);
        _setMarketPrice(0.90e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 935_000);
    }

    function test_does_not_read_twap_at_or_below_e0() public {
        oracle = _deployHybrid(address(0));
        vm.mockCallRevert(address(pendleOracle), abi.encodeWithSelector(MockPendleOracle.getPtToAssetRate.selector), abi.encodeWithSignature("TwapUnavailable()"));
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 1e6);
        sy.setExchangeRate(0.999e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 999_000);
        sy.setExchangeRate(0.99e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 990_000);
    }

    function test_returns_twap_at_e1() public {
        oracle = _deployHybrid(address(0));
        sy.setExchangeRate(0.95e18);
        _setMarketPrice(0.90e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 900_000);
    }

    function test_returns_twap_above_e1() public {
        oracle = _deployHybrid(address(0));
        sy.setExchangeRate(0.90e18);
        _setMarketPrice(0.80e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 800_000);
    }

    function test_rounds_blended_price_down() public {
        oracle = _deployHybrid(address(0));
        sy.setExchangeRate(0.97e18);
        _setMarketPrice(900000000000000001);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e18), 935000000000000000);
    }

    function test_reads_the_configured_twap_window() public {
        oracle = new PendlePtPriceOracle(address(pt), address(0), address(pendleOracle), address(pendleMarket), 900, 0.01e18, 0.05e18);
        sy.setExchangeRate(0.97e18);
        vm.mockCall(address(pendleOracle), abi.encodeCall(MockPendleOracle.getPtToAssetRate, (address(pendleMarket), uint32(900))), abi.encode(uint256(0.90e18)));
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 935_000);
    }

    function test_propagates_twap_failure_when_weight_is_positive() public {
        oracle = _deployHybrid(address(0));
        sy.setExchangeRate(0.97e18);
        vm.mockCallRevert(address(pendleOracle), abi.encodeWithSelector(MockPendleOracle.getPtToAssetRate.selector), abi.encodeWithSignature("TwapUnavailable()"));
        vm.expectRevert(bytes4(keccak256("TwapUnavailable()")));
        oracle.getPrice();
    }

    function test_rejects_twap_price_above_nominal() public {
        oracle = _deployHybrid(address(0));
        sy.setExchangeRate(0.97e18);
        _setMarketPrice(1e18 + 1);
        vm.expectRevert(PendlePtPriceOracle.InvalidMarketPrice.selector);
        oracle.getPrice();
    }

    function test_accepts_zero_twap_price() public {
        oracle = _deployHybrid(address(0));
        _setMarketPrice(0);
        sy.setExchangeRate(0.97e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 485_000);
        sy.setExchangeRate(0.90e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 0);
    }

    function test_zero_backing_does_not_read_twap() public {
        oracle = _deployHybrid(address(0));
        sy.setExchangeRate(0);
        vm.mockCallRevert(address(pendleOracle), abi.encodeWithSelector(MockPendleOracle.getPtToAssetRate.selector), abi.encodeWithSignature("TwapUnavailable()"));
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 0);
    }

    function test_rejects_unordered_or_out_of_range_thresholds() public {
        vm.expectRevert(PendlePtPriceOracle.InvalidDiscountThresholds.selector);
        new PendlePtPriceOracle(address(pt), address(0), address(pendleOracle), address(pendleMarket), 1800, 0.05e18, 0.05e18);
        vm.expectRevert(PendlePtPriceOracle.InvalidDiscountThresholds.selector);
        new PendlePtPriceOracle(address(pt), address(0), address(pendleOracle), address(pendleMarket), 1800, 0.05e18, 0.01e18);
        vm.expectRevert(PendlePtPriceOracle.InvalidDiscountThresholds.selector);
        new PendlePtPriceOracle(address(pt), address(0), address(pendleOracle), address(pendleMarket), 1800, 0.01e18, 1e18 + 1);
    }

    function test_rejects_zero_twap_duration() public {
        vm.expectRevert(PendlePtPriceOracle.InvalidTwapDuration.selector);
        new PendlePtPriceOracle(address(pt), address(0), address(pendleOracle), address(pendleMarket), 0, 0.01e18, 0.05e18);
    }

    function test_rejects_pendle_oracle_without_code() public {
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleOracle.selector);
        new PendlePtPriceOracle(address(pt), address(0), makeAddr("missing oracle"), address(pendleMarket), 1800, 0.01e18, 0.05e18);
    }

    function test_rejects_pendle_market_without_code() public {
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleMarket.selector);
        new PendlePtPriceOracle(address(pt), address(0), address(pendleOracle), makeAddr("missing market"), 1800, 0.01e18, 0.05e18);
    }

    function test_rejects_market_with_mismatched_tokens() public {
        vm.mockCall(address(pendleMarket), abi.encodeCall(MockPendleMarket.readTokens, ()), abi.encode(makeAddr("other SY"), address(pt), address(yt)));
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleMarket.selector);
        _deployHybrid(address(0));
        vm.mockCall(address(pendleMarket), abi.encodeCall(MockPendleMarket.readTokens, ()), abi.encode(address(sy), makeAddr("other PT"), address(yt)));
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleMarket.selector);
        _deployHybrid(address(0));
        vm.mockCall(address(pendleMarket), abi.encodeCall(MockPendleMarket.readTokens, ()), abi.encode(address(sy), address(pt), makeAddr("other YT")));
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleMarket.selector);
        _deployHybrid(address(0));
    }

    function test_requires_sufficient_twap_cardinality_before_expiry() public {
        vm.mockCall(address(pendleOracle), abi.encodeCall(MockPendleOracle.getOracleState, (address(pendleMarket), uint32(1800))), abi.encode(true, uint16(100), true));
        vm.expectRevert(PendlePtPriceOracle.OracleNotReady.selector);
        _deployHybrid(address(0));
    }

    function test_requires_old_enough_observations_before_expiry() public {
        vm.mockCall(address(pendleOracle), abi.encodeCall(MockPendleOracle.getOracleState, (address(pendleMarket), uint32(1800))), abi.encode(false, uint16(100), false));
        vm.expectRevert(PendlePtPriceOracle.OracleNotReady.selector);
        _deployHybrid(address(0));
    }

    function test_expired_market_does_not_require_twap_history() public {
        vm.warp(pt.expiry());
        vm.mockCallRevert(address(pendleOracle), abi.encodeWithSelector(MockPendleOracle.getOracleState.selector), abi.encodeWithSignature("HistoryUnavailable()"));
        oracle = _deployHybrid(address(0));
        sy.setExchangeRate(0.90e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e6), 900_000);
    }

    function test_fuzz_blended_price_stays_between_backing_and_market(uint128 syIndex, uint128 pyIndex, uint64 marketPrice) public {
        oracle = _deployHybrid(address(0));
        pyIndex = uint128(bound(pyIndex, 1, type(uint128).max));
        syIndex = uint128(bound(syIndex, 0, pyIndex));
        sy.setExchangeRate(syIndex);
        yt.setIndex(pyIndex);
        uint256 backing = Math.mulDiv(syIndex, 1e18, pyIndex);
        _setMarketPrice(bound(marketPrice, 0, backing));
        uint256 price = oracle.getPrice().quoteSourceToTarget(1e18);
        assertLe(price, backing);
        assertGe(price, bound(marketPrice, 0, backing));
    }

    function test_prices_loss_with_small_indices_and_different_sy_decimals() public {
        sy.setExchangeRate(1_100_000);
        yt.setIndex(1_200_000);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 11e6);
    }

    function test_preserves_fraction_precision_beyond_wad() public {
        sy.setExchangeRate(1);
        yt.setIndex(3);
        assertEq(oracle.getPrice().quoteSourceToTarget(3e6), 1e6);
        assertEq(oracle.getPrice().quoteTargetToSource(1e6), 3e6);
    }

    function test_recovers_to_nominal_without_exceeding_it() public {
        yt.setIndex(1.2e18);
        sy.setExchangeRate(1.1e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 11e6);
        sy.setExchangeRate(1.2e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 12e6);
        sy.setExchangeRate(1.3e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 12e6);
    }

    function test_keeps_loss_before_at_and_after_maturity() public {
        sy.setExchangeRate(1.1e18);
        yt.setIndex(1.2e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 11e6);
        vm.warp(pt.expiry());
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 11e6);
        vm.warp(pt.expiry() + 365 days);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 11e6);
        sy.setExchangeRate(0.6e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 6e6);
    }

    function test_returns_zero_for_total_backing_loss() public {
        sy.setExchangeRate(0);
        IPriceOracle.Price memory price = oracle.getPrice();
        assertEq(price.numerator, 0);
        assertEq(price.quoteSourceToTarget(12e6), 0);
    }

    function test_zero_stored_index_with_positive_sy_is_nominal() public {
        yt.setIndex(0);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 12e6);
    }

    function test_reverts_when_both_indices_are_zero() public {
        sy.setExchangeRate(0);
        yt.setIndex(0);
        vm.expectRevert(PendlePtPriceOracle.InvalidIndices.selector);
        oracle.getPrice();
    }

    function test_rejects_pt_without_code() public {
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleToken.selector);
        _deployOracle(makeAddr("not a PT"), address(0));
    }

    function test_rejects_missing_sy() public {
        pt.setTokens(address(0), address(yt));
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleToken.selector);
        _deployOracle(address(pt), address(0));
    }

    function test_rejects_missing_yt() public {
        pt.setTokens(address(sy), address(0));
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleToken.selector);
        _deployOracle(address(pt), address(0));
    }

    function test_rejects_mismatched_yt_pt() public {
        yt.setTokens(makeAddr("other PT"), address(sy));
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleToken.selector);
        _deployOracle(address(pt), address(0));
    }

    function test_rejects_mismatched_yt_sy() public {
        yt.setTokens(address(pt), makeAddr("other SY"));
        vm.expectRevert(PendlePtPriceOracle.InvalidPendleToken.selector);
        _deployOracle(address(pt), address(0));
    }

    function test_rejects_lp_accounting_asset() public {
        sy.setAssetInfo(1, address(accounting), 6);
        vm.expectRevert(PendlePtPriceOracle.UnsupportedAccountingAsset.selector);
        _deployOracle(address(pt), address(0));
    }

    function test_rejects_native_accounting_asset() public {
        sy.setAssetInfo(0, address(0), 6);
        vm.expectRevert(PendlePtPriceOracle.UnsupportedAccountingAsset.selector);
        _deployOracle(address(pt), address(0));
    }

    function test_rejects_remote_accounting_asset() public {
        sy.setAssetInfo(0, makeAddr("remote accounting"), 6);
        vm.expectRevert(PendlePtPriceOracle.UnsupportedAccountingAsset.selector);
        _deployOracle(address(pt), address(0));
    }

    function test_rejects_pt_decimal_mismatch() public {
        MockPendlePT wrongPt = new MockPendlePT(18);
        MockPendleYT wrongYt = new MockPendleYT(address(wrongPt), address(sy));
        wrongPt.setTokens(address(sy), address(wrongYt));
        vm.expectRevert(PendlePtPriceOracle.UnsupportedAccountingAsset.selector);
        _deployOracle(address(wrongPt), address(0));
    }

    function test_rejects_asset_decimal_mismatch() public {
        sy.setAssetInfo(0, address(accounting), 18);
        vm.expectRevert(PendlePtPriceOracle.UnsupportedAccountingAsset.selector);
        _deployOracle(address(pt), address(0));
    }

    function test_rejects_accounting_token_decimal_mismatch() public {
        MockPendleToken differentDecimals = new MockPendleToken(18);
        sy.setAssetInfo(0, address(differentDecimals), 6);
        vm.expectRevert(PendlePtPriceOracle.UnsupportedAccountingAsset.selector);
        _deployOracle(address(pt), address(0));
    }

    function test_accepts_exact_scaled_accounting_wrapper() public {
        MockPendleToken wrapper = new MockPendleToken(18);
        MockPendlePT wrappedPt = new MockPendlePT(18);
        MockPendleSY wrappedSy = new MockPendleSY(address(wrapper), 18, 18);
        MockPendleYT wrappedYt = new MockPendleYT(address(wrappedPt), address(wrappedSy));
        wrappedPt.setTokens(address(wrappedSy), address(wrappedYt));
        pendleMarket = new MockPendleMarket(address(wrappedSy), address(wrappedPt), address(wrappedYt));
        PendlePtPriceOracle wrappedOracle = _deployOracle(address(wrappedPt), address(0));
        assertEq(wrappedOracle.target(), address(wrapper));
        assertEq(wrappedOracle.getPrice().quoteSourceToTarget(12e18), 12e18);
    }

    function test_composes_chainlink_conversion_from_6_to_18_decimals() public {
        MockPendleToken loan = new MockPendleToken(18);
        MockV3Aggregator accountingFeed = new MockV3Aggregator(8, 98e6);
        MockV3Aggregator loanFeed = new MockV3Aggregator(8, 1e8);
        ChainlinkPriceOracle converter = new ChainlinkPriceOracle(address(accounting), address(loan), address(accountingFeed), address(loanFeed));
        oracle = _deployHybrid(address(converter));
        sy.setExchangeRate(1_164_000);
        yt.setIndex(1_200_000);
        _setMarketPrice(0.90e18);
        assertEq(oracle.target(), address(loan));
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 10.9956e18);
    }

    function test_composes_chainlink_conversion_from_18_to_6_decimals() public {
        MockPendleToken accounting18 = new MockPendleToken(18);
        MockPendleToken loan = new MockPendleToken(6);
        MockPendlePT pt18 = new MockPendlePT(18);
        MockPendleSY sy18 = new MockPendleSY(address(accounting18), 18, 6);
        MockPendleYT yt18 = new MockPendleYT(address(pt18), address(sy18));
        pt18.setTokens(address(sy18), address(yt18));
        MockV3Aggregator accountingFeed = new MockV3Aggregator(8, 98e6);
        MockV3Aggregator loanFeed = new MockV3Aggregator(8, 1e8);
        ChainlinkPriceOracle converter = new ChainlinkPriceOracle(address(accounting18), address(loan), address(accountingFeed), address(loanFeed));
        pendleMarket = new MockPendleMarket(address(sy18), address(pt18), address(yt18));
        oracle = new PendlePtPriceOracle(address(pt18), address(converter), address(pendleOracle), address(pendleMarket), 1800, 0.01e18, 0.05e18);
        sy18.setExchangeRate(97);
        yt18.setIndex(100);
        _setMarketPrice(0.90e18);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e18), 10.9956e6);
    }

    function test_does_not_cap_fx_above_one() public {
        MockPriceOracle converter = _conversion();
        converter.setPriceFraction(102, 100);
        assertEq(oracle.getPrice().quoteSourceToTarget(100e6), 102e6);
    }

    function test_preserves_oldest_conversion_timestamp() public {
        MockPriceOracle converter = _conversion();
        converter.setUpdatedAt(20);
        oracle = _deployHybrid(address(converter));
        sy.setExchangeRate(0.97e18);
        _setMarketPrice(0.90e18);
        vm.warp(200);
        IPriceOracle.Price memory price = oracle.getPrice();
        assertEq(price.updatedAt, 20);
    }

    function test_leaves_stale_conversion_age_to_consumer() public {
        MockPriceOracle converter = _conversion();
        converter.setUpdatedAt(1);
        vm.warp(365 days);
        assertEq(oracle.getPrice().updatedAt, 1);
    }

    function test_rejects_wrong_conversion_source() public {
        MockPriceOracle converter = new MockPriceOracle(address(pt), address(accounting));
        vm.expectRevert(PendlePtPriceOracle.InvalidConversionOracle.selector);
        _deployOracle(address(pt), address(converter));
    }

    function test_rejects_conversion_target_without_code() public {
        MockPriceOracle converter = new MockPriceOracle(address(accounting), makeAddr("invalid loan"));
        vm.expectRevert(PendlePtPriceOracle.InvalidConversionOracle.selector);
        _deployOracle(address(pt), address(converter));
    }

    function test_rejects_converter_without_code() public {
        vm.expectRevert(PendlePtPriceOracle.InvalidConversionOracle.selector);
        _deployOracle(address(pt), makeAddr("invalid converter"));
    }

    function test_rejects_conversion_target_without_erc20_metadata() public {
        MockPriceOracle nonToken = new MockPriceOracle(address(accounting), address(accounting));
        MockPriceOracle converter = new MockPriceOracle(address(accounting), address(nonToken));
        vm.expectRevert();
        _deployOracle(address(pt), address(converter));
    }

    function test_rejects_zero_conversion_denominator() public {
        MockPriceOracle converter = _conversion();
        converter.setPriceFraction(1, 0);
        vm.expectRevert(PendlePtPriceOracle.InvalidConversionPrice.selector);
        oracle.getPrice();
    }

    function test_rejects_zero_conversion_timestamp() public {
        MockPriceOracle converter = _conversion();
        converter.setUpdatedAt(0);
        vm.expectRevert(PendlePtPriceOracle.InvalidConversionPrice.selector);
        oracle.getPrice();
    }

    function test_rejects_future_conversion_timestamp() public {
        MockPriceOracle converter = _conversion();
        converter.setUpdatedAt(101);
        vm.expectRevert(PendlePtPriceOracle.InvalidConversionPrice.selector);
        oracle.getPrice();
    }

    function test_propagates_zero_conversion_numerator() public {
        MockPriceOracle converter = _conversion();
        converter.setPriceFraction(0, 1);
        assertEq(oracle.getPrice().quoteSourceToTarget(12e6), 0);
    }

    function test_zero_backing_keeps_conversion_timestamp() public {
        MockPriceOracle converter = _conversion();
        converter.setUpdatedAt(20);
        sy.setExchangeRate(0);
        IPriceOracle.Price memory price = oracle.getPrice();
        assertEq(price.numerator, 0);
        assertEq(price.updatedAt, 20);
    }

    function test_zero_backing_does_not_skip_conversion_validation() public {
        MockPriceOracle converter = _conversion();
        converter.setUpdatedAt(0);
        sy.setExchangeRate(0);
        vm.expectRevert(PendlePtPriceOracle.InvalidConversionPrice.selector);
        oracle.getPrice();
    }

    function test_rejects_numerator_product_overflow() public {
        MockPriceOracle converter = _conversion();
        sy.setExchangeRate(2);
        yt.setIndex(3);
        converter.setPriceFraction(type(uint256).max, 1);
        vm.expectRevert(PendlePtPriceOracle.OracleFractionOverflow.selector);
        oracle.getPrice();
    }

    function test_rejects_denominator_product_overflow() public {
        MockPriceOracle converter = _conversion();
        sy.setExchangeRate(1);
        yt.setIndex(2);
        converter.setPriceFraction(1, type(uint256).max);
        vm.expectRevert(PendlePtPriceOracle.OracleFractionOverflow.selector);
        oracle.getPrice();
    }

    function test_propagates_sy_failure_without_nominal_fallback() public {
        vm.mockCallRevert(address(sy), abi.encodeWithSignature("exchangeRate()"), abi.encodeWithSignature("BackingUnavailable()"));
        vm.expectRevert(bytes4(keccak256("BackingUnavailable()")));
        oracle.getPrice();
    }

    function test_propagates_yt_failure_without_nominal_fallback() public {
        vm.mockCallRevert(address(yt), abi.encodeWithSignature("pyIndexStored()"), abi.encodeWithSignature("IndexUnavailable()"));
        vm.expectRevert(bytes4(keccak256("IndexUnavailable()")));
        oracle.getPrice();
    }

    function test_propagates_conversion_failure_without_nominal_fallback() public {
        MockPriceOracle converter = _conversion();
        vm.mockCallRevert(address(converter), abi.encodeCall(IPriceOracle.getPrice, ()), abi.encodeWithSignature("ConversionUnavailable()"));
        vm.expectRevert(bytes4(keccak256("ConversionUnavailable()")));
        oracle.getPrice();
    }

    function test_fuzz_backing_never_exceeds_nominal(uint128 syIndex, uint128 pyIndex) public {
        if (syIndex == 0 && pyIndex == 0) pyIndex = 1;
        sy.setExchangeRate(syIndex);
        yt.setIndex(pyIndex);
        assertLe(oracle.getPrice().quoteSourceToTarget(1e18), 1e18);
    }

    function test_fuzz_backing_increases_with_sy_index(uint128 first, uint128 second, uint128 pyIndex) public {
        pyIndex = uint128(bound(pyIndex, 1, type(uint128).max));
        yt.setIndex(pyIndex);
        sy.setExchangeRate(Math.min(first, second));
        uint256 lower = oracle.getPrice().quoteSourceToTarget(1e18);
        sy.setExchangeRate(Math.max(first, second));
        assertGe(oracle.getPrice().quoteSourceToTarget(1e18), lower);
    }

    function test_fuzz_matches_pendle_same_block_correction(uint128 syIndex, uint128 pyIndex, bool cachedThisBlock) public {
        if (syIndex == 0 && pyIndex == 0) pyIndex = 1;
        sy.setExchangeRate(syIndex);
        yt.setIndex(pyIndex);
        // Pendle's current PY index uses the stored value in a cached block, otherwise max(SY, stored).
        uint256 currentPy = cachedThisBlock ? pyIndex : Math.max(syIndex, pyIndex);
        uint256 expected = syIndex >= currentPy ? 1e18 : Math.mulDiv(syIndex, 1e18, currentPy);
        assertEq(oracle.getPrice().quoteSourceToTarget(1e18), expected);
    }

    function _deployOracle(address pt_, address converter_) private returns (PendlePtPriceOracle) {
        return new PendlePtPriceOracle(pt_, converter_, address(pendleOracle), address(pendleMarket), 1800, 0.75e18, 0.90e18);
    }

    function _deployHybrid(address converter_) private returns (PendlePtPriceOracle) {
        return new PendlePtPriceOracle(address(pt), converter_, address(pendleOracle), address(pendleMarket), 1800, 0.01e18, 0.05e18);
    }

    function _setMarketPrice(uint256 rate) private {
        vm.mockCall(address(pendleOracle), abi.encodeCall(MockPendleOracle.getPtToAssetRate, (address(pendleMarket), uint32(1800))), abi.encode(rate));
    }

    function _conversion() internal returns (MockPriceOracle converter) {
        MockPendleToken loan = new MockPendleToken(6);
        converter = new MockPriceOracle(address(accounting), address(loan));
        oracle = _deployOracle(address(pt), address(converter));
    }
}
