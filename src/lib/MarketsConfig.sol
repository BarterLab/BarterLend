// SPDX-License-Identifier: BUSL-1.1 AND GPL-2.0-or-later
// Public declarations SEEDS, MarketsConfigParams and MarketsConfig are GPL-2.0-or-later;
// the remaining implementation is BUSL-1.1. See LICENSE.md for the exact scope.
pragma solidity ^0.8.29;

uint256 constant SEEDS = 3;

struct MarketsConfigParams {
    // how long each market lasts (without extension)
    uint64[SEEDS] durations;

    // how many markets are active in same time
    uint8[SEEDS] active;

    // market #i will start extensions[i] earlier
    uint64[SEEDS] extensions;
}

struct MarketsConfig {
    uint64 start;

    // how long each market lasts (without extension)
    uint64[SEEDS] durations;

    // how many markets are active in same time
    uint8[SEEDS] active;

    // market #i will start extensions[i] earlier
    uint64[SEEDS] extensions;
}

using MarketsConfigLib for MarketsConfig global;

error WrongMarketTimestamp(uint64 timestamp);

library MarketsConfigLib {
    function isValidSeed(MarketsConfig memory seed) internal pure returns (bool) {
        if (seed.start == 0) return false;

        for (uint256 i = 0; i < SEEDS; ++i) {
            if (seed.durations[i] == 0) return false;
            if (seed.active[i] == 0) return false;
            if (seed.extensions[i] >= seed.durations[i]) return false;
        }

        for (uint256 i = 1; i < SEEDS; ++i) {
            if (seed.durations[i] < seed.durations[i - 1]) return false;
            if (seed.durations[i] % seed.durations[i - 1] != 0) return false;
        }

        return true;
    }

    function isValidTimestamp(MarketsConfig memory seed, uint64 marketTimestamp) internal pure returns (bool) {
        if (marketTimestamp <= seed.start) return false;

        // All valid seeds expose the shortest duration tier, while 1- and 2-seed
        // schedules are encoded by duplicating identical tiers instead of zeroing
        // out unused slots. That makes the base grid sufficient for validation.
        return (marketTimestamp - seed.start) % seed.durations[0] == 0;
    }

    function checkMarketTimestamp(MarketsConfig memory seed, uint64 marketTimestamp) internal pure {
        require(isValidTimestamp(seed, marketTimestamp), WrongMarketTimestamp(marketTimestamp));
    }

    // A maturity M from a tier is visible while now is inside
    // [max(seed.start, M - active * duration - extension), M).
    function _tierStartsAt(
        MarketsConfig memory seed,
        uint64 duration,
        uint64 activeMarkets,
        uint64 extension,
        uint64 marketTimestamp
    ) private pure returns (uint64 startTimestamp) {
        startTimestamp = seed.start;

        uint64 activeWindow = activeMarkets * duration + extension;
        if (marketTimestamp <= activeWindow) return startTimestamp;
            
        uint64 shiftedStart = marketTimestamp - activeWindow;
        if (shiftedStart <= startTimestamp) return startTimestamp;
        
        return shiftedStart;
    }

    function _getNextNearestMarketAfter(
        MarketsConfig memory seed,
        uint64 now_,
        uint64 threshold
    ) private pure returns (uint64 nextMarketTimestamp) {
        for (uint256 i = 0; i < SEEDS; ++i) {
            uint64 duration = seed.durations[i];

            uint64 candidateTimestamp = threshold - ((threshold - seed.start) % duration) + duration;
            uint64 activeWindow = seed.active[i] * duration + seed.extensions[i];

            if (candidateTimestamp - now_ <= activeWindow) {
                if (nextMarketTimestamp == 0 || candidateTimestamp < nextMarketTimestamp) {
                    nextMarketTimestamp = candidateTimestamp;
                }
            }
        }
    }

    function getActiveMarkets(MarketsConfig memory seed, uint64 now_) internal pure returns (uint64[] memory activeMarkets) {
        if (now_ < seed.start) return new uint64[](0);

        uint256 count;
        uint64 nextMarketTimestamp = _getNextNearestMarketAfter(seed, now_, now_);

        while (nextMarketTimestamp != 0) {
            ++count;
            nextMarketTimestamp = _getNextNearestMarketAfter(seed, now_, nextMarketTimestamp);
        }

        activeMarkets = new uint64[](count);
        nextMarketTimestamp = _getNextNearestMarketAfter(seed, now_, now_);

        for (uint256 i = 0; i < count; ++i) {
            activeMarkets[i] = nextMarketTimestamp;
            nextMarketTimestamp = _getNextNearestMarketAfter(seed, now_, nextMarketTimestamp);
        }
    }

    function isMarketActive(MarketsConfig memory seed, uint64 now_, uint64 marketTimestamp) internal pure returns (bool) {
        checkMarketTimestamp(seed, marketTimestamp);

        if (now_ < seed.start || marketTimestamp <= now_) return false;

        uint256 elapsed = marketTimestamp - seed.start;
        for (uint256 i = 0; i < SEEDS; ++i) {
            uint8 activeMarkets = seed.active[i];
            uint64 duration = seed.durations[i];

            if (elapsed % duration == 0) {
                uint64 activeWindow = activeMarkets * duration + seed.extensions[i];
                if (marketTimestamp - now_ <= activeWindow) return true;
            }
        }

        return false;
    }

    function isMarketFinalized(MarketsConfig memory seed, uint64 now_, uint64 marketTimestamp) internal pure returns (bool) {
        checkMarketTimestamp(seed, marketTimestamp);
        return marketTimestamp <= now_;
    }

    function getMarketStart(MarketsConfig memory seed, uint64, uint64 marketTimestamp) internal pure returns (uint64) {
        checkMarketTimestamp(seed, marketTimestamp);

        uint64 earliestStart = type(uint64).max;
        uint64 elapsed = marketTimestamp - seed.start;

        for (uint256 i = 0; i < SEEDS; ++i) {
            uint8 activeMarkets = seed.active[i];
            uint64 duration = seed.durations[i];

            if (activeMarkets != 0 && elapsed % duration == 0) {
                uint64 startTimestamp = _tierStartsAt(seed, duration, activeMarkets, seed.extensions[i], marketTimestamp);
                if (startTimestamp == seed.start) {
                    return startTimestamp;
                }

                if (startTimestamp < earliestStart) {
                    earliestStart = startTimestamp;
                }
            }
        }

        return earliestStart;
    }

    function getNextNearestMarket(MarketsConfig memory seed, uint64 now_, uint64 marketTimestamp) internal pure returns (uint64) {
        checkMarketTimestamp(seed, marketTimestamp);

        if (now_ < seed.start) return 0;

        uint64 threshold = marketTimestamp;
        if (now_ > threshold) threshold = now_;

        return _getNextNearestMarketAfter(seed, now_, threshold);
    }
}
