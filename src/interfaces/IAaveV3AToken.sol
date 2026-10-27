// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {IPool} from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";

interface IAaveV3AToken {
    /// @notice Returns the Aave pool managing this aToken's reserve.
    /// @return Aave pool contract.
    function POOL() external view returns (IPool);

    /// @notice Returns the underlying token represented by this aToken.
    /// @return Underlying token address.
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
