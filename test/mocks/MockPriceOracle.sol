// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 public price;
    uint256 public denominator;
    uint256 public updatedAt;

    address public immutable source;
    address public immutable target;

    uint256 public constant SCALE = 1e18;

    constructor(address _source, address _target) {
        source = _source;
        target = _target;
        price = 1 * SCALE;
        denominator = SCALE;
        updatedAt = block.timestamp;
    }

    function setPrice(uint256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function setPriceFraction(uint256 _price, uint256 _denominator) external {
        price = _price;
        denominator = _denominator;
        updatedAt = block.timestamp;
    }

    function touch() external {
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function getPrice() external view returns (Price memory) {
        return Price({ numerator: price, denominator: denominator, updatedAt: updatedAt });
    }
}
