// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

interface ICreditPoolFactory {
    /// @notice Returns whether an address is a pool deployed by this factory.
    /// @param pool Address to check.
    /// @return True if the pool was deployed by this factory.
    function isPool(address pool) external view returns (bool);
}
