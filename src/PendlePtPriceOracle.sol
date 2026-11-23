// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { IERC20Metadata } from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

interface IPendlePrincipalToken {
    function SY() external view returns (address);
    function YT() external view returns (address);
}

interface IPendleYieldToken {
    function PT() external view returns (address);
    function SY() external view returns (address);
    function pyIndexStored() external view returns (uint256);
}

interface IPendleStandardizedYield {
    function assetInfo() external view returns (uint8 assetType, address assetAddress, uint8 assetDecimals);
    function exchangeRate() external view returns (uint256);
}

interface IPendleMarket {
    function readTokens() external view returns (address sy, address pt, address yt);
    function expiry() external view returns (uint256);
}

interface IPendleOracle {
    function getPtToAssetRate(address market, uint32 duration) external view returns (uint256);
    function getOracleState(address market, uint32 duration) external view returns (bool, uint16, bool);
}

contract PendlePtPriceOracle is IPriceOracle {
    // https://docs.pendle.finance/pendle-v2-dev/Contracts/Oracle/PYLpOracle#overview
    // All rates are expressed as 1e18-scaled fixed-point numbers.
    // A return value of 0.95e18 means 1 unit of the queried token is
    // worth 0.95 units of the denominator token.
    uint256 private constant PENDLE_RATE_UNIT = 1e18;

    address public immutable source;
    address public immutable target;
    address public immutable accountingToken;
    address public immutable sy;
    address public immutable yt;
    IPriceOracle public immutable conversionOracle;
    IPendleOracle public immutable pendleOracle;
    address public immutable market;
    uint32 public immutable twapDuration;
    uint256 public immutable e0;
    uint256 public immutable e1;

    error InvalidPendleToken();
    error UnsupportedAccountingAsset();
    error InvalidConversionOracle();
    error InvalidIndices();
    error InvalidConversionPrice();
    error OracleFractionOverflow();
    error InvalidPendleOracle();
    error InvalidPendleMarket();
    error InvalidTwapDuration();
    error InvalidDiscountThresholds();
    error OracleNotReady();
    error InvalidMarketPrice();

    constructor(
        address pt,
        address conversionOracle_,
        address pendleOracle_,
        address market_,
        uint32 twapDuration_,
        uint256 e0_,
        uint256 e1_
    ) {
        if (pt.code.length == 0) revert InvalidPendleToken();

        address sy_ = IPendlePrincipalToken(pt).SY();
        address yt_ = IPendlePrincipalToken(pt).YT();
        if (
            sy_.code.length == 0 || yt_.code.length == 0 ||
            IPendleYieldToken(yt_).PT() != pt || IPendleYieldToken(yt_).SY() != sy_
        ) revert InvalidPendleToken();

        (uint8 assetType, address accountingToken_, uint8 assetDecimals) = IPendleStandardizedYield(sy_).assetInfo();
        if (
            assetType != 0 || accountingToken_.code.length == 0 ||
            IERC20Metadata(pt).decimals() != assetDecimals || IERC20Metadata(accountingToken_).decimals() != assetDecimals
        ) revert UnsupportedAccountingAsset();

        address target_ = accountingToken_;
        if (conversionOracle_ != address(0)) {
            if (conversionOracle_.code.length == 0) revert InvalidConversionOracle();
            IPriceOracle converter = IPriceOracle(conversionOracle_);
            target_ = converter.target();
            if (converter.source() != accountingToken_ || target_.code.length == 0) revert InvalidConversionOracle();
            IERC20Metadata(target_).decimals();
        }

        if (pendleOracle_.code.length == 0) revert InvalidPendleOracle();
        if (market_.code.length == 0) revert InvalidPendleMarket();
        if (twapDuration_ == 0) revert InvalidTwapDuration();
        if (e0_ >= e1_ || e1_ > PENDLE_RATE_UNIT) revert InvalidDiscountThresholds();
        {
            (address marketSy, address marketPt, address marketYt) = IPendleMarket(market_).readTokens();
            if (marketSy != sy_ || marketPt != pt || marketYt != yt_) revert InvalidPendleMarket();
        }
        if (block.timestamp < IPendleMarket(market_).expiry()) {
            (bool increaseRequired,, bool oldestSatisfied) = IPendleOracle(pendleOracle_).getOracleState(market_, twapDuration_);
            if (increaseRequired || !oldestSatisfied) revert OracleNotReady();
        }

        source = pt;
        target = target_;
        accountingToken = accountingToken_;
        sy = sy_;
        yt = yt_;
        conversionOracle = IPriceOracle(conversionOracle_);
        pendleOracle = IPendleOracle(pendleOracle_);
        market = market_;
        twapDuration = twapDuration_;
        e0 = e0_;
        e1 = e1_;
    }

    function getPrice() external view returns (Price memory price) {
        uint256 syIndex = IPendleStandardizedYield(sy).exchangeRate();
        uint256 pyIndex = IPendleYieldToken(yt).pyIndexStored();
        if (syIndex == 0 && pyIndex == 0) revert InvalidIndices();

        // Capping at nominal makes s / max(s, stored PY) independent of same-block PY index caching.
        if (syIndex >= pyIndex) {
            price.numerator = 1;
            price.denominator = 1;
        } else {
            price.numerator = syIndex;
            price.denominator = pyIndex;
        }
        _applyMarketDiscount(price);
        price.updatedAt = block.timestamp;

        if (address(conversionOracle) != address(0)) {
            Price memory conversion = conversionOracle.getPrice();
            if (
                conversion.denominator == 0 || conversion.updatedAt == 0 || conversion.updatedAt > block.timestamp
            ) revert InvalidConversionPrice();

            price.numerator = _mul(price.numerator, conversion.numerator);
            price.denominator = _mul(price.denominator, conversion.denominator);
            price.updatedAt = conversion.updatedAt;
        }
    }

    function _applyMarketDiscount(Price memory price) private view {
        if (price.numerator == 0) return;
        uint256 backing = Math.mulDiv(price.numerator, PENDLE_RATE_UNIT, price.denominator);
        uint256 loss = PENDLE_RATE_UNIT - backing;
        if (loss <= e0) return;

        uint256 weight = loss >= e1 ? PENDLE_RATE_UNIT : Math.mulDiv(loss - e0, PENDLE_RATE_UNIT, e1 - e0);
        uint256 marketPrice = pendleOracle.getPtToAssetRate(market, twapDuration);
        if (marketPrice > PENDLE_RATE_UNIT) revert InvalidMarketPrice();

        // P = (1 - w) * F + w * M; Pendle's M already includes the backing loss.
        price.numerator = (backing * (PENDLE_RATE_UNIT - weight) + marketPrice * weight) / PENDLE_RATE_UNIT;
        price.denominator = PENDLE_RATE_UNIT;
    }

    function _mul(uint256 left, uint256 right) private pure returns (uint256) {
        if (left != 0 && right > type(uint256).max / left) revert OracleFractionOverflow();
        return left * right;
    }
}
