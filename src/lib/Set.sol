// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

struct SetUint64 {
    uint64[] keys;
    mapping(uint64 key => uint256 indexPlusOne) indexByKey;
}

using SetUint64Lib for SetUint64 global;

library SetUint64Lib {
    function insert(SetUint64 storage set, uint64 key) internal returns (bool inserted) {
        if (set.indexByKey[key] != 0) return false;
        set.keys.push(key);
        set.indexByKey[key] = set.keys.length; // index + 1
        return true;
    }

    function remove(SetUint64 storage set, uint64 key) internal {
        uint256 indexPlusOne = set.indexByKey[key];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = set.keys.length - 1;

        if (index != lastIndex) {
            uint64 lastKey = set.keys[lastIndex];
            set.keys[index] = lastKey;
            set.indexByKey[lastKey] = indexPlusOne;
        }

        set.keys.pop();
        delete set.indexByKey[key];
    }

    function has(SetUint64 storage set, uint64 key) internal view returns (bool) {
        return set.indexByKey[key] > 0;
    }

    function count(SetUint64 storage set) internal view returns (uint256) {
        return set.keys.length;
    }

    function isEmpty(SetUint64 storage set) internal view returns (bool) {
        return set.keys.length == 0;
    }
}
struct SetUint256 {
    uint256[] keys;
    mapping(uint256 key => uint256 indexPlusOne) indexByKey;
}

using SetUint256Lib for SetUint256 global;

library SetUint256Lib {
    function insert(SetUint256 storage set, uint256 key) internal returns (bool inserted) {
        if (set.indexByKey[key] != 0) return false;
        set.keys.push(key);
        set.indexByKey[key] = set.keys.length; // index + 1
        return true;
    }

    function remove(SetUint256 storage set, uint256 key) internal {
        uint256 indexPlusOne = set.indexByKey[key];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = set.keys.length - 1;

        if (index != lastIndex) {
            uint256 lastKey = set.keys[lastIndex];
            set.keys[index] = lastKey;
            set.indexByKey[lastKey] = indexPlusOne;
        }

        set.keys.pop();
        delete set.indexByKey[key];
    }

    function has(SetUint256 storage set, uint256 key) internal view returns (bool) {
        return set.indexByKey[key] > 0;
    }

    function count(SetUint256 storage set) internal view returns (uint256) {
        return set.keys.length;
    }

    function isEmpty(SetUint256 storage set) internal view returns (bool) {
        return set.keys.length == 0;
    }
}
