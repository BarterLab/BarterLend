// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { IERC20Metadata } from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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

contract PendlePtPriceOracle is IPriceOracle {
    address public immutable source;
    address public immutable target;
    address public immutable accountingToken;
    address public immutable sy;
    address public immutable yt;
    IPriceOracle public immutable conversionOracle;

    error InvalidPendleToken();
    error UnsupportedAccountingAsset();
    error InvalidConversionOracle();
    error InvalidIndices();
    error InvalidConversionPrice();
    error OracleFractionOverflow();

    constructor(address pt, address conversionOracle_) {
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

        source = pt;
        target = target_;
        accountingToken = accountingToken_;
        sy = sy_;
        yt = yt_;
        conversionOracle = IPriceOracle(conversionOracle_);
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

    function _mul(uint256 left, uint256 right) private pure returns (uint256) {
        if (left != 0 && right > type(uint256).max / left) revert OracleFractionOverflow();
        return left * right;
    }
}
