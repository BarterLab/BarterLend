// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";

library PriceMath {
    function quoteSourceToTarget(IPriceOracle.Price memory price, uint256 sourceAmount)
        internal pure
        returns (uint256)
    {
        return Math.mulDiv(sourceAmount, price.numerator, price.denominator, Math.Rounding.Floor);
    }

    function quoteTargetToSource(IPriceOracle.Price memory price, uint256 targetAmount)
        internal pure
        returns (uint256)
    {
        return Math.mulDiv(targetAmount, price.denominator, price.numerator, Math.Rounding.Ceil);
    }
}
