// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { IERC20Metadata } from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { AggregatorV3Interface } from "lib/chainlink-local/src/data-feeds/interfaces/AggregatorV3Interface.sol";

import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";

using Math for uint256;
using SafeCast for int256;

contract ChainlinkPriceOracle is IPriceOracle {
    address public immutable source;
    address public immutable target;
    uint256 private immutable sourceDecimals;
    uint256 private immutable targetDecimals;
    mapping(address => AggregatorV3Interface) public feeds;

    error OracleAnswerNonPositive();
    error OracleUpdatedAtZero();
    error OracleRoundIncomplete();
    error OracleFractionOverflow();

    constructor(address _source, address _target, address _sourceFeed, address _targetFeed) {
        source = _source;
        target = _target;
        sourceDecimals = IERC20Metadata(_source).decimals();
        targetDecimals = IERC20Metadata(_target).decimals();
        feeds[_source] = AggregatorV3Interface(_sourceFeed);
        feeds[_target] = AggregatorV3Interface(_targetFeed);

        require(feeds[_source].decimals() == feeds[_target].decimals());
    }

    function getPrice() external view returns (Price memory price) {
        Rate memory sourceRate = _rate(source);
        Rate memory targetRate = _rate(target);

        (price.numerator, price.denominator) = _fraction(sourceRate.rate, targetRate.rate);
        price.updatedAt = Math.min(sourceRate.updatedAt, targetRate.updatedAt);
    }

    struct Rate {
        uint256 rate;
        uint256 updatedAt;
    }

    function _rate(address token) private view returns (Rate memory rate) {
        (uint80 roundId, int256 answer,, uint256 updatedAt_, uint80 answeredInRound) = feeds[token].latestRoundData();
        require(answer > 0, OracleAnswerNonPositive());
        require(updatedAt_ != 0, OracleUpdatedAtZero());
        require(answeredInRound >= roundId, OracleRoundIncomplete());

        return Rate({
            rate: answer.toUint256(),
            updatedAt: updatedAt_
        });
    }

    function _fraction(uint256 sourceRate, uint256 targetRate)
        private view
        returns (uint256 numerator, uint256 denominator)
    {
        numerator = sourceRate;
        denominator = targetRate;

        if (targetDecimals > sourceDecimals) {
            numerator = _mul(numerator, _pow10(targetDecimals - sourceDecimals));
        } else if (sourceDecimals > targetDecimals) {
            denominator = _mul(denominator, _pow10(sourceDecimals - targetDecimals));
        }
    }

    function _pow10(uint256 exponent) private pure returns (uint256) {
        if (exponent > 77) revert OracleFractionOverflow();
        return 10 ** exponent;
    }

    function _mul(uint256 left, uint256 right) private pure returns (uint256 result) {
        if (left != 0 && right > type(uint256).max / left) revert OracleFractionOverflow();
        return left * right;
    }

}
