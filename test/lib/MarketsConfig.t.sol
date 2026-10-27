// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { MarketsConfig, MarketsConfigLib, WrongMarketTimestamp } from "src/lib/MarketsConfig.sol";

type NONE_T is uint256;
NONE_T constant NONE = NONE_T.wrap(0);

contract MarketsConfigHarness {
    function isValidSeed(MarketsConfig memory seed) external pure returns (bool) {
        return MarketsConfigLib.isValidSeed(seed);
    }

    function getActiveMarkets(MarketsConfig memory seed, uint64 now_) external pure returns (uint64[] memory activeMarkets) {
        return MarketsConfigLib.getActiveMarkets(seed, now_);
    }

    function isValidTimestamp(MarketsConfig memory seed, uint64 marketTimestamp) external pure returns (bool) {
        return MarketsConfigLib.isValidTimestamp(seed, marketTimestamp);
    }

    function isMarketActive(MarketsConfig memory seed, uint64 now_, uint64 marketTimestamp) external pure returns (bool) {
        return MarketsConfigLib.isMarketActive(seed, now_, marketTimestamp);
    }

    function isMarketFinalized(MarketsConfig memory seed, uint64 now_, uint64 marketTimestamp) external pure returns (bool) {
        return MarketsConfigLib.isMarketFinalized(seed, now_, marketTimestamp);
    }

    function getMarketStart(MarketsConfig memory seed, uint64 now_, uint64 marketTimestamp) external pure returns (uint64) {
        return MarketsConfigLib.getMarketStart(seed, now_, marketTimestamp);
    }

    function getNextNearestMarket(MarketsConfig memory seed, uint64 now_, uint64 marketTimestamp) external pure returns (uint64) {
        return MarketsConfigLib.getNextNearestMarket(seed, now_, marketTimestamp);
    }
}

contract TestMarketsConfig is Test {
    uint64 internal constant START = 100 days;

    MarketsConfigHarness internal harness;

    function setUp() public {
        harness = new MarketsConfigHarness();
    }

    function _seed() public pure returns (MarketsConfig memory seed_) {
        seed_.start = START;
    }

    function test_single_seed_is_encoded_by_three_identical_slots() public view {
        MarketsConfig memory seed = _seed();
        seed.durations[0] = 2 weeks; seed.active[0] = 1;
        seed.durations[1] = 2 weeks; seed.active[1] = 1;
        seed.durations[2] = 2 weeks; seed.active[2] = 1;

        assertEq(harness.isValidSeed(seed), true);
        assertActiveMarkets(seed, START, [START + 2 weeks]);
        assertEq(harness.isMarketActive(seed, START, START + 2 weeks), true);
        assertEq(harness.isMarketActive(seed, START, START + 4 weeks), false);
        assertEq(harness.getMarketStart(seed, START, START + 2 weeks), START);
        assertEq(harness.getNextNearestMarket(seed, START, START + 2 weeks), 0);
    }

    function test_single_seed_finalizes_the_old_maturity_at_rollover() public view {
        MarketsConfig memory seed = _seed();
        seed.durations[0] = 2 weeks; seed.active[0] = 1;
        seed.durations[1] = 2 weeks; seed.active[1] = 1;
        seed.durations[2] = 2 weeks; seed.active[2] = 1;

        assertEq(harness.isMarketActive(seed, START + 2 weeks - 1, START + 2 weeks), true);
        assertEq(harness.isMarketActive(seed, START + 2 weeks, START + 2 weeks), false);
        assertEq(harness.isMarketFinalized(seed, START + 2 weeks, START + 2 weeks), true);
        assertActiveMarkets(seed, START + 2 weeks, [START + 4 weeks]);

        assertEq(harness.isMarketActive(seed, START + 2 weeks, START + 4 weeks), true);
        assertEq(harness.getMarketStart(seed, START + 2 weeks, START + 4 weeks), START + 2 weeks);
        assertEq(harness.getNextNearestMarket(seed, START + 2 weeks, START + 4 weeks), 0);
    }

    function test_two_seed_config_is_encoded_by_one_unique_seed_plus_one_duplicate() public view {
        MarketsConfig memory seed = _seed();
        seed.durations[0] = 2 weeks; seed.active[1] = 1;
        seed.durations[1] = 4 weeks; seed.active[2] = 1;
        seed.durations[2] = 4 weeks; seed.active[0] = 1;

        assertEq(harness.isValidSeed(seed), true);
        assertEq(harness.isValidTimestamp(seed, START + 2 weeks), true);

        assertActiveMarkets(seed, START, [START + 2 weeks, START + 4 weeks]);
        assertEq(harness.isMarketActive(seed, START, START + 2 weeks), true);
        assertEq(harness.isMarketActive(seed, START, START + 4 weeks), true);
        assertEq(harness.isMarketActive(seed, START, START + 6 weeks), false);
        assertEq(harness.isMarketActive(seed, START, START + 8 weeks), false);

        assertEq(harness.getMarketStart(seed, START, START + 4 weeks), START);
        assertEq(harness.getNextNearestMarket(seed, START, START + 2 weeks), START + 4 weeks);
        assertEq(harness.getNextNearestMarket(seed, START, START + 4 weeks), 0);

        uint64 rolloverNow = START + 4 weeks;

        assertActiveMarkets(seed, rolloverNow, [START + 6 weeks, START + 8 weeks]);
        assertEq(harness.isMarketActive(seed, rolloverNow, START + 6 weeks), true);
        assertEq(harness.isMarketActive(seed, rolloverNow, START + 8 weeks), true);
        assertEq(harness.getNextNearestMarket(seed, rolloverNow, START + 6 weeks), START + 8 weeks);
        assertEq(harness.getNextNearestMarket(seed, rolloverNow, START + 8 weeks), 0);
    }

    function test_no_extension_schedule_collapses_duplicate_maturities_at_start() public view {
        MarketsConfig memory seed = _seed();
        seed.durations[0] = 2 weeks; seed.active[0] = 2;
        seed.durations[1] = 4 weeks; seed.active[1] = 2;
        seed.durations[2] = 8 weeks; seed.active[2] = 2;

        assertActiveMarkets(seed, START, [START + 2 weeks, START + 4 weeks, START + 8 weeks, START + 16 weeks]);
        assertEq(harness.isMarketActive(seed, START, START + 2 weeks), true);
        assertEq(harness.isMarketActive(seed, START, START + 4 weeks), true);
        assertEq(harness.isMarketActive(seed, START, START + 8 weeks), true);
        assertEq(harness.isMarketActive(seed, START, START + 16 weeks), true);

        assertEq(harness.isMarketActive(seed, START, START + 6 weeks), false);
        assertEq(harness.isMarketActive(seed, START, START + 12 weeks), false);

        assertEq(harness.getNextNearestMarket(seed, START, START + 2 weeks), START + 4 weeks);
        assertEq(harness.getNextNearestMarket(seed, START, START + 4 weeks), START + 8 weeks);
        assertEq(harness.getNextNearestMarket(seed, START, START + 8 weeks), START + 16 weeks);
        assertEq(harness.getNextNearestMarket(seed, START, START + 16 weeks), 0);
    }

    function test_no_extension_schedule_shifts_forward_after_rollover() public view {
        MarketsConfig memory seed = _seed();
        seed.durations[0] = 2 weeks; seed.active[0] = 2;
        seed.durations[1] = 4 weeks; seed.active[1] = 2;
        seed.durations[2] = 8 weeks; seed.active[2] = 2;

        uint64 now_ = START + 2 weeks;

        assertActiveMarkets(seed, now_, [START + 4 weeks, START + 6 weeks, START + 8 weeks, START + 16 weeks]);
        assertEq(harness.isMarketActive(seed, now_, START + 2 weeks), false);
        assertEq(harness.isMarketFinalized(seed, now_, START + 2 weeks), true);

        assertEq(harness.isMarketActive(seed, now_, START + 4 weeks), true);
        assertEq(harness.isMarketActive(seed, now_, START + 6 weeks), true);
        assertEq(harness.isMarketActive(seed, now_, START + 8 weeks), true);
        assertEq(harness.isMarketActive(seed, now_, START + 16 weeks), true);

        assertEq(harness.getMarketStart(seed, now_, START + 6 weeks), START + 2 weeks);
        assertEq(harness.getNextNearestMarket(seed, now_, START + 4 weeks), START + 6 weeks);
    }

    function test_duplicate_maturity_uses_the_earliest_start_among_contributing_seeds() public view {
        MarketsConfig memory seed = _seed();
        seed.durations[0] = 2 weeks; seed.active[0] = 3; seed.extensions[0] = 1 days;
        seed.durations[1] = 4 weeks; seed.active[1] = 2;
        seed.durations[2] = 4 weeks; seed.active[2] = 2;

        assertActiveMarkets(seed, START, [START + 2 weeks, START + 4 weeks, START + 6 weeks, START + 8 weeks]);
        assertEq(harness.isMarketActive(seed, START, START + 4 weeks), true);
        assertEq(harness.isMarketActive(seed, START, START + 8 weeks), true);

        assertEq(harness.getMarketStart(seed, START, START + 8 weeks), START);
    }

    function test_extension_opens_the_next_maturity_inside_the_extension_window() public view {
        MarketsConfig memory seed = _seed();
        seed.durations[0] = 2 weeks; seed.active[0] = 2; seed.extensions[0] = 1 days;
        seed.durations[1] = 2 weeks; seed.active[1] = 2; seed.extensions[1] = 1 days;
        seed.durations[2] = 2 weeks; seed.active[2] = 2; seed.extensions[2] = 1 days;

        uint64 now_ = START + 13 days;

        assertActiveMarkets(seed, START, [START + 2 weeks, START + 4 weeks]);
        assertEq(harness.isMarketActive(seed, START, START + 2 weeks), true);
        assertEq(harness.isMarketActive(seed, START, START + 4 weeks), true);
        assertEq(harness.isMarketActive(seed, START, START + 6 weeks), false);

        assertActiveMarkets(seed, now_, [START + 2 weeks, START + 4 weeks, START + 6 weeks]);
        assertEq(harness.isMarketActive(seed, now_, START + 2 weeks), true);
        assertEq(harness.isMarketFinalized(seed, now_, START + 2 weeks), false);
        assertEq(harness.isMarketActive(seed, now_, START + 4 weeks), true);
        assertEq(harness.isMarketActive(seed, now_, START + 6 weeks), true);
        assertEq(harness.getMarketStart(seed, now_, START + 6 weeks), START + 13 days);

        assertEq(harness.getNextNearestMarket(seed, now_, START + 2 weeks), START + 4 weeks);
        assertEq(harness.getNextNearestMarket(seed, now_, START + 4 weeks), START + 6 weeks);
        assertEq(harness.getNextNearestMarket(seed, now_, START + 6 weeks), 0);
    }

    function test_extension_boundary_finalizes_the_old_market_and_keeps_the_new_ones() public view {
        MarketsConfig memory seed = _seed();
        seed.durations[0] = 2 weeks; seed.active[0] = 2; seed.extensions[0] = 1 days;
        seed.durations[1] = 2 weeks; seed.active[1] = 2; seed.extensions[1] = 1 days;
        seed.durations[2] = 2 weeks; seed.active[2] = 2; seed.extensions[2] = 1 days;

        uint64 now_ = START + 2 weeks;

        assertActiveMarkets(seed, now_, [START + 4 weeks, START + 6 weeks]);
        assertEq(harness.isMarketActive(seed, now_, START + 2 weeks), false);
        assertEq(harness.isMarketFinalized(seed, now_, START + 2 weeks), true);
        assertEq(harness.isMarketActive(seed, now_, START + 4 weeks), true);
        assertEq(harness.isMarketActive(seed, now_, START + 6 weeks), true);
    }

    function test_invalid_market_timestamp_reverts_for_pre_start_and_off_grid_values() public {
        MarketsConfig memory seed = _seed();
        seed.durations[0] = 2 weeks; seed.active[0] = 1;
        seed.durations[1] = 2 weeks; seed.active[1] = 1;
        seed.durations[2] = 2 weeks; seed.active[2] = 1;

        assertEq(harness.isValidTimestamp(seed, START - 1 days), false);
        assertEq(harness.isValidTimestamp(seed, START + 1 days), false);

        vm.expectRevert(abi.encodeWithSelector(WrongMarketTimestamp.selector, START - 1 days));
        harness.isMarketFinalized(seed, START, START - 1 days);

        vm.expectRevert(abi.encodeWithSelector(WrongMarketTimestamp.selector, START + 1 days));
        harness.getNextNearestMarket(seed, START, START + 1 days);
    }


    // helper functions

    function assertActiveMarkets(MarketsConfig memory seed, uint64 now_, uint64[] memory expectedMarkets) internal view {
        uint64[] memory markets = harness.getActiveMarkets(seed, now_);
        assertEq(markets.length, expectedMarkets.length, "active markets length");

        for (uint256 i = 0; i < markets.length; ++i) {
            assertEq(markets[i], expectedMarkets[i], "active markets item");
        }
    }

    function assertActiveMarkets(MarketsConfig memory seed, uint64 now_, NONE_T) internal view {
        uint64[] memory e = new uint64[](0);
        assertActiveMarkets(seed, now_, e);
    }

    function assertActiveMarkets(MarketsConfig memory seed, uint64 now_, uint64[1] memory expectedMarkets) internal view {
        uint64[] memory e = new uint64[](expectedMarkets.length);
        for (uint256 i = 0; i < expectedMarkets.length; ++i) e[i] = expectedMarkets[i];
        assertActiveMarkets(seed, now_, e);
    }

    function assertActiveMarkets(MarketsConfig memory seed, uint64 now_, uint64[2] memory expectedMarkets) internal view {
        uint64[] memory e = new uint64[](expectedMarkets.length);
        for (uint256 i = 0; i < expectedMarkets.length; ++i) e[i] = expectedMarkets[i];
        assertActiveMarkets(seed, now_, e);
    }

    function assertActiveMarkets(MarketsConfig memory seed, uint64 now_, uint64[3] memory expectedMarkets) internal view {
        uint64[] memory e = new uint64[](expectedMarkets.length);
        for (uint256 i = 0; i < expectedMarkets.length; ++i) e[i] = expectedMarkets[i];
        assertActiveMarkets(seed, now_, e);
    }

    function assertActiveMarkets(MarketsConfig memory seed, uint64 now_, uint64[4] memory expectedMarkets) internal view {
        uint64[] memory e = new uint64[](expectedMarkets.length);
        for (uint256 i = 0; i < expectedMarkets.length; ++i) e[i] = expectedMarkets[i];
        assertActiveMarkets(seed, now_, e);
    }
}