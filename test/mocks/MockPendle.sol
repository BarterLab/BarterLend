// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { MockToken } from "test/mocks/MockToken.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

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

contract MockPendleMarket {
    address private sy;
    address private pt;
    address private yt;

    constructor(address sy_, address pt_, address yt_) {
        sy = sy_;
        pt = pt_;
        yt = yt_;
    }

    function readTokens() external view returns (address, address, address) {
        return (sy, pt, yt);
    }

    function expiry() external view returns (uint256) {
        return MockPendlePT(pt).expiry();
    }
}

contract MockPendleOracle {
    function getOracleState(address, uint32) external pure returns (bool, uint16, bool) {
        return (false, 0, true);
    }

    function getPtToAssetRate(address market, uint32) external view returns (uint256) {
        (address sy,, address yt) = MockPendleMarket(market).readTokens();
        uint256 syIndex = MockPendleSY(sy).exchangeRate();
        uint256 pyIndex = MockPendleYT(yt).pyIndexStored();
        return syIndex >= pyIndex ? 1e18 : Math.mulDiv(syIndex, 1e18, pyIndex);
    }
}
