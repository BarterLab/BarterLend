// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

interface ICreditPoolExtension {
    /// @notice Returns the pool permissions an account must grant to this extension.
    /// @return Bitmask of required DELEGATE_* actions.
    function requiredActions() external pure returns (uint256);

    /// @notice Returns a human-readable description of this extension.
    /// @return Description of the extension.
    function description() external pure returns (string memory);
}
