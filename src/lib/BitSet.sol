// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

struct BitSet {
	uint256 smallest;
	uint256 largest;
    uint256 count;
    mapping(uint256 index => uint256 bitmap) bitmaps;
}

using BitSetLib for BitSet global;

library BitSetLib {
	function insert(BitSet storage set, uint256 value) internal returns (bool added) {
        uint256 mask = 1 << (value & 0xFF);
        uint256 prev_ = set.bitmaps[value >> 8];
        set.bitmaps[value >> 8] = prev_ | mask;
        added = (prev_ & mask) == 0;

        if (added) {
            if (set.count == 0) {
                set.smallest = value;
                set.largest = value;
            } else {
                if (value < set.smallest) {
                    set.smallest = value;
                }

                if (value > set.largest) {
                    set.largest = value;
                }
            }

            set.count += 1;
        }
	}

    // TODO: add remove in batch to optimize iterations
	function remove(BitSet storage set, uint256 value) internal returns (bool removed) {
        uint256 mask = 1 << (value & 0xFF);
        uint256 prev_ = set.bitmaps[value >> 8];
        set.bitmaps[value >> 8] = prev_ & ~mask;
        removed = (prev_ & mask) != 0;

        if (removed) {
            set.count -= 1;

            if (set.count == 0) {
                set.smallest = 0;
                set.largest = 0;
            } else {
                if (value == set.smallest) {
                    set.smallest = _nextValue(set, value);
                }

                if (value == set.largest) {
                    set.largest = _prevValue(set, value);
                }
            }
        }
	}

	function has(BitSet storage set, uint256 value) internal view returns (bool) {
        uint256 mask = 1 << (value & 0xFF);
        return (set.bitmaps[value >> 8] & mask) != 0;
	}

	function isEmpty(BitSet storage set) internal view returns (bool) {
        return set.count == 0;
	}

	function first(BitSet storage set) internal view returns (bool exists, uint256 value) {
        if (set.count == 0) {
            return (false, 0);
        } else {
            return (true, set.smallest);
        }
	}

    function last(BitSet storage set) internal view returns (bool exists, uint256 value) {
        if (set.count == 0) {
            return (false, 0);
        } else {
            return (true, set.largest);
        }
    }

    function prev(BitSet storage set, uint256 value) internal view returns (bool exists, uint256 prevValue) {
        if (set.count == 0 || value <= set.smallest) {
            return (false, 0);
        } else if (value > set.largest) {
            return (true, set.largest);
        } else {
            return (true, _prevValue(set, value));
        }
    }

	function next(BitSet storage set, uint256 value) internal view returns (bool exists, uint256 nextValue) {
        if (set.count == 0 || value >= set.largest) {
            return (false, 0);
        } else if (value < set.smallest) {
            return (true, set.smallest);
        } else {
            return (true, _nextValue(set, value));
        }
	}

    function _nextValue(BitSet storage set, uint256 value) private view returns (uint256) {
        // current bitmap with bits after the value masked out

        uint256 indexInBucket = value & 0xFF;
        if (indexInBucket < 0xFF) {
            uint256 bitmap = set.bitmaps[value >> 8] & ~((1 << (indexInBucket + 1)) - 1);
            if (bitmap != 0) return (value & ~uint256(0xFF)) + _leastSignificantBit(bitmap);
        }

        uint256 rightmostBucket = set.largest >> 8;
        for (uint256 bucket = (value >> 8) + 1; bucket <= rightmostBucket; ++bucket) {
            uint256 bitmap = set.bitmaps[bucket];
            if (bitmap != 0) return (bucket << 8) + _leastSignificantBit(bitmap);
        }

        return 0;
    }

    function _prevValue(BitSet storage set, uint256 value) private view returns (uint256) {
        // current bitmap with bits before the value masked out

        uint256 indexInBucket = value & 0xFF;
        if (indexInBucket > 0) {
            uint256 bitmap = set.bitmaps[value >> 8] & ((1 << indexInBucket) - 1);
            if (bitmap != 0) return (value & ~uint256(0xFF)) + _mostSignificantBit(bitmap);
        }

        uint256 leftmostBucket = set.smallest >> 8;
        for (uint256 bucket = (value >> 8) - 1; bucket >= leftmostBucket; --bucket) {
            uint256 bitmap = set.bitmaps[bucket];
            if (bitmap != 0) return (bucket << 8) + _mostSignificantBit(bitmap);
        }

        return 0;
    }

    function _mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);
        assembly ("memory-safe") {
            r := or(shl(8, iszero(x)), shl(7, lt(0xffffffffffffffffffffffffffffffff, x)))
            r := or(r, shl(6, lt(0xffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffff, shr(r, x))))
            r := or(r, shl(3, lt(0xff, shr(r, x))))
            r := or(r, byte(and(0x1f, shr(shr(r, x), 0x8421084210842108cc6318c6db6d54be)),
                0x0706060506020504060203020504030106050205030304010505030400000000))
        }
    }

    function _leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);
        assembly ("memory-safe") {
            x := and(x, add(not(x), 1))
            r := shl(5, shr(252, shl(shl(2, shr(250, mul(x,
                0xb6db6db6ddddddddd34d34d349249249210842108c6318c639ce739cffffffff))),
                0x8040405543005266443200005020610674053026020000107506200176117077)))
            r := or(r, byte(and(div(0xd76453e0, shr(r, x)), 0x1f),
                0x001f0d1e100c1d070f090b19131c1706010e11080a1a141802121b1503160405))
        }
    }
}
