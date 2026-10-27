// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

interface ILiquidator {
    function liquidateCallback(
        uint128 amountToLiquidate,
        uint128 collateralToSeize,
        bytes calldata data
    ) external;
}
