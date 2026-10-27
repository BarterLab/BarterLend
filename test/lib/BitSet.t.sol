// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { BitSet } from "src/lib/BitSet.sol";

contract BitSetHarness {
    BitSet internal set;

    function insert(uint256 value) external returns (bool added) {
        return set.insert(value);
    }

    function remove(uint256 value) external returns (bool removed) {
        return set.remove(value);
    }

    function has(uint256 value) external view returns (bool) {
        return set.has(value);
    }

    function count() external view returns (uint256) {
        return set.count;
    }

    function smallest() external view returns (uint256) {
        return set.smallest;
    }

    function largest() external view returns (uint256) {
        return set.largest;
    }

    function bitmap(uint256 bucket) external view returns (uint256) {
        return set.bitmaps[bucket];
    }

    function isEmpty() external view returns (bool) {
        return set.isEmpty();
    }

    function first() external view returns (bool exists, uint256 value) {
        return set.first();
    }

    function last() external view returns (bool exists, uint256 value) {
        return set.last();
    }

    function next(uint256 value) external view returns (bool exists, uint256 nextValue) {
        return set.next(value);
    }

    function prev(uint256 value) external view returns (bool exists, uint256 prevValue) {
        return set.prev(value);
    }
}

contract TestBitSet is Test {
    BitSetHarness internal harness;
    uint256 cursor; uint256 done;

    function setUp() public {
        harness = new BitSetHarness();
    }

    function assertFirst(uint256 expectedValue) internal {
        (bool exists, uint256 value) = harness.first();
        assertEq(exists, true);
        assertEq(value, expectedValue);
        cursor = value;
    }

    function assertNext(uint256 expectedNext) internal {
        (bool exists, uint256 nextValue) = harness.next(cursor);
        assertEq(exists, true);
        assertEq(nextValue, expectedNext);
        cursor = nextValue;
    }

    function assertDone() internal view {
        (bool exists,) = harness.next(cursor);
        assertEq(exists, false);
    }

    function test_first_and_count_changes() public {
        assertEq(harness.count(), 0);

        assertEq(harness.insert(513), true);
        assertEq(harness.count(), 1);
        assertFirst(513);

        assertEq(harness.insert(7), true);
        assertEq(harness.count(), 2);
        assertFirst(7);

        assertEq(harness.insert(513), false);
        assertEq(harness.count(), 2);
        assertFirst(7);

        assertEq(harness.has(7), true);
        assertEq(harness.has(513), true);
        assertEq(harness.has(8), false);
    }

    function test_iter() public {
        harness.insert(500);
        harness.insert(1);
        harness.insert(260);
        harness.insert(5);
        harness.insert(100_00);

        assertFirst(1);
        assertNext(5);
        assertNext(260);
        assertNext(500);
        assertNext(100_00);
        assertDone();

        harness.remove(1);

        assertFirst(5);
        assertNext(260);
        assertNext(500);
        assertNext(100_00);
        assertDone();

        harness.remove(100_00);

        assertFirst(5);
        assertNext(260);
        assertNext(500);
        assertDone();

        harness.insert(2);

        assertFirst(2);
        assertNext(5);
        assertNext(260);
        assertNext(500);
        assertDone();
    }

    function test_smallest_moves_when_leftmost_bucket_becomes_empty() public {
        harness.insert(0);
        harness.insert(10);
        harness.insert(511);
        harness.insert(1024);

        assertEq(harness.smallest(), 0);
        assertEq(harness.bitmap(0), (1 << 0) | (1 << 10));

        harness.remove(0);

        assertEq(harness.smallest(), 10);
        assertEq(harness.bitmap(0), 1 << 10);

        harness.remove(10);

        assertEq(harness.bitmap(0), 0);
        assertEq(harness.smallest(), 511);
        assertEq(harness.smallest() >> 8, 1);
        assertEq(harness.bitmap(harness.smallest() >> 8), 1 << 255);

        harness.remove(511);

        assertEq(harness.bitmap(1), 0);
        assertEq(harness.smallest(), 1024);
        assertEq(harness.smallest() >> 8, 4);
        assertEq(harness.bitmap(harness.smallest() >> 8), 1);
    }

    function testFuzz_smallest_and_largest_stay_on_existing_bits(uint256 seed) public {
        for (uint256 i = 0; i < 64; i++) {
            uint256 value = uint256(keccak256(abi.encode(seed, i))) % 4096;

            if (((seed >> (i % 256)) & 1) == 0) {
                harness.insert(value);
            } else {
                harness.remove(value);
            }

            if (harness.count() == 0) {
                assertEq(harness.smallest(), 0);
                assertEq(harness.largest(), 0);
            } else {
                assertEq(harness.has(harness.smallest()), true);
                assertEq(harness.has(harness.largest()), true);
                assertGt(harness.bitmap(harness.smallest() >> 8), 0);
                assertGt(harness.bitmap(harness.largest() >> 8), 0);
            }
        }
    }

    function test_many() public {
        for (uint i = 0; i < 10000; i++) {
            harness.insert(i);
        }

        uint256 next = 0;
        for((bool e, uint256 x) = harness.first(); e; (e, x) = harness.next(x)) assertEq(x, next++);
        assertEq(next, 10000);
        for((bool e, uint256 x) = harness.last(); e; (e, x) = harness.prev(x)) assertEq(x, --next);
        // assertEq(next, 0);
    }
}
