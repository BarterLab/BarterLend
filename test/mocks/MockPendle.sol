// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { MockToken } from "test/mocks/MockToken.sol";

contract MockPendleToken is MockToken {
    uint8 private immutable tokenDecimals;

    constructor(uint8 decimals_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }
}

contract MockPendleSY is MockPendleToken {
    uint8 private assetType;
    address private asset;
    uint8 private assetDecimals;
    uint256 public exchangeRate = 1e18;

    constructor(address asset_, uint8 assetDecimals_, uint8 syDecimals_) MockPendleToken(syDecimals_) {
        asset = asset_;
        assetDecimals = assetDecimals_;
    }

    function assetInfo() external view returns (uint8, address, uint8) {
        return (assetType, asset, assetDecimals);
    }

    function setAssetInfo(uint8 type_, address asset_, uint8 decimals_) external {
        assetType = type_;
        asset = asset_;
        assetDecimals = decimals_;
    }

    function setExchangeRate(uint256 rate) external {
        exchangeRate = rate;
    }
}

contract MockPendlePT is MockPendleToken {
    address public SY;
    address public YT;
    uint256 public expiry;

    constructor(uint8 decimals_) MockPendleToken(decimals_) {
        expiry = block.timestamp + 30 days;
    }

    function setTokens(address sy_, address yt_) external {
        SY = sy_;
        YT = yt_;
    }
}

contract MockPendleYT {
    address public PT;
    address public SY;
    uint256 public pyIndexStored = 1e18;

    constructor(address pt_, address sy_) {
        PT = pt_;
        SY = sy_;
    }

    function setTokens(address pt_, address sy_) external {
        PT = pt_;
        SY = sy_;
    }

    function setIndex(uint256 index) external {
        pyIndexStored = index;
    }

    function pyIndexCurrent() external returns (uint256) {
        // A static call must not use Pendle's state-changing index path.
        pyIndexStored += 1;
        return pyIndexStored;
    }
}
