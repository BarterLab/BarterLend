// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

abstract contract Delegator {
    address internal _facet1;
    address internal _facet2;
    address internal _facet3;
    address internal _facet4;

    constructor(address[] memory facets) {
        _facet1 = facets[0];
        _facet2 = facets[1];
        _facet3 = facets[2];
        _facet4 = facets[3];
    }

    function _delegate(address facet) internal {
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())

            let result := delegatecall(gas(), facet, ptr, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(ptr, 0, size)

            if iszero(result) { revert(ptr, size) }
        }
    }

    function _delegateReturn(address facet) internal returns (bytes memory data) {
        (bool success, bytes memory result) = facet.delegatecall(msg.data);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }

    function _delegateView(address facet) internal view virtual {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x78f37afa))
            mstore(add(ptr, 0x04), facet)
            mstore(add(ptr, 0x24), 0x40)
            mstore(add(ptr, 0x44), calldatasize())
            calldatacopy(add(ptr, 0x64), 0, calldatasize())

            let success := staticcall(gas(), address(), ptr, add(0x64, calldatasize()), 0, 0)
            let size := returndatasize()
            returndatacopy(ptr, 0, size)

            switch success
            case 0 { revert(ptr, size) }
            default { return(ptr, size) }
        }
    }

    function _delegateCall(address facet, bytes calldata data) external {
        if (msg.sender != address(this)) revert();

        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, data.offset, data.length)

            let result := delegatecall(gas(), facet, ptr, data.length, 0, 0)
            let size := returndatasize()
            returndatacopy(ptr, 0, size)

            switch result
            case 0 { revert(ptr, size) }
            default { return(ptr, size) }
        }
    }
}
