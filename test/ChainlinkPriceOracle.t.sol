// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { MockV3Aggregator } from "lib/chainlink-local/src/data-feeds/MockV3Aggregator.sol";

import { ChainlinkPriceOracle } from "src/ChainlinkPriceOracle.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";

import { MockToken } from "test/mocks/MockToken.sol";

contract OracleMockToken is MockToken {
    uint8 private _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract ChainlinkPriceOracleTest is Test {
    function setUp() public {
        vm.warp(1);
    }

    function test_get_price_for_18_to_6_decimals() public {
        ChainlinkPriceOracle oracle = _oracle(18, 6, 1_000_000, 2_000_000_000_000);

        IPriceOracle.Price memory price = oracle.getPrice();

        assertEq(price.numerator, 1_000_000);
        assertEq(price.denominator, 2e24);
        assertEq(price.updatedAt, 1);
    }

    function test_get_price_for_6_to_18_decimals() public {
        ChainlinkPriceOracle oracle = _oracle(6, 18, 2_000_000_000_000, 1_000_000);

        IPriceOracle.Price memory price = oracle.getPrice();

        assertEq(price.numerator, 2e24);
        assertEq(price.denominator, 1_000_000);
        assertEq(price.updatedAt, 1);
    }

    function test_get_price_keeps_equal_decimals_answers() public {
        ChainlinkPriceOracle oracle = _oracle(18, 18, 12e8, 8e8);

        IPriceOracle.Price memory price = oracle.getPrice();

        assertEq(price.numerator, 12e8);
        assertEq(price.denominator, 8e8);
    }

    function test_get_price_uses_oldest_timestamp() public {
        OracleMockToken source = new OracleMockToken(18);
        OracleMockToken target = new OracleMockToken(6);
        MockV3Aggregator sourceFeed = new MockV3Aggregator(8, 1e8);
        MockV3Aggregator targetFeed = new MockV3Aggregator(8, 2e8);
        sourceFeed.updateRoundData(2, 1e8, 10, 10);
        targetFeed.updateRoundData(2, 2e8, 20, 20);
        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(
            address(source),
            address(target),
            address(sourceFeed),
            address(targetFeed)
        );

        IPriceOracle.Price memory price = oracle.getPrice();

        assertEq(price.updatedAt, 10);
    }

    function test_get_price_reverts_for_non_positive_answer() public {
        ChainlinkPriceOracle oracle = _oracle(18, 6, 0, 1e8);

        vm.expectRevert(ChainlinkPriceOracle.OracleAnswerNonPositive.selector);
        oracle.getPrice();
    }

    function test_get_price_reverts_when_fraction_overflows() public {
        ChainlinkPriceOracle oracle = _oracle(78, 0, 1e8, 1e8);

        vm.expectRevert(ChainlinkPriceOracle.OracleFractionOverflow.selector);
        oracle.getPrice();
    }

    function test_get_price_reverts_when_fraction_multiplication_overflows() public {
        ChainlinkPriceOracle oracle = _oracle(0, 77, type(int256).max, 1);

        vm.expectRevert(ChainlinkPriceOracle.OracleFractionOverflow.selector);
        oracle.getPrice();
    }

    function _oracle(uint8 sourceDecimals, uint8 targetDecimals, int256 sourceAnswer, int256 targetAnswer)
        private returns (ChainlinkPriceOracle)
    {
        OracleMockToken source = new OracleMockToken(sourceDecimals);
        OracleMockToken target = new OracleMockToken(targetDecimals);
        MockV3Aggregator sourceFeed = new MockV3Aggregator(8, sourceAnswer);
        MockV3Aggregator targetFeed = new MockV3Aggregator(8, targetAnswer);
        return new ChainlinkPriceOracle(
            address(source),
            address(target),
            address(sourceFeed),
            address(targetFeed)
        );
    }
}
