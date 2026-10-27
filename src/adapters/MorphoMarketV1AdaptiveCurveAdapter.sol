// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Id,
    IMorpho,
    MarketParams,
    Position,
    Market
} from "lib/morpho-blue-irm/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue-irm/lib/morpho-blue/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "lib/morpho-blue-irm/lib/morpho-blue/src/libraries/SharesMathLib.sol";
import {IAdaptiveCurveIrm} from "lib/morpho-blue-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol";
import {AdaptiveCurveIrmLib} from "lib/morpho-blue-irm/src/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol";

import {IUnderlyingPool} from "src/interfaces/IUnderlyingPool.sol";

contract MorphoMarketV1AdaptiveCurveAdapter is IUnderlyingPool {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    address private constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant MIN_DEAD_SUPPLY_SHARES = 1e9;

    IMorpho public immutable MORPHO;
    IAdaptiveCurveIrm public immutable ADAPTIVE_CURVE_IRM;
    address private immutable SELF;

    error InvalidMorpho(address morpho);
    error InvalidAdaptiveCurveIrm(address irm);

    constructor(IMorpho morpho, IAdaptiveCurveIrm adaptiveCurveIrm) {
        if (address(morpho) == address(0) || address(morpho).code.length == 0) {
            revert InvalidMorpho(address(morpho));
        }
        if (address(adaptiveCurveIrm) == address(0) || address(adaptiveCurveIrm).code.length == 0) {
            revert InvalidAdaptiveCurveIrm(address(adaptiveCurveIrm));
        }

        try adaptiveCurveIrm.MORPHO() returns (address irmMorpho) {
            if (irmMorpho != address(morpho)) revert InvalidAdaptiveCurveIrm(address(adaptiveCurveIrm));
        } catch {
            revert InvalidAdaptiveCurveIrm(address(adaptiveCurveIrm));
        }

        // Immutables keep protocol routing outside CreditPool storage and make the adapter stateless.
        MORPHO = morpho;
        ADAPTIVE_CURVE_IRM = adaptiveCurveIrm;
        SELF = address(this);
    }

    modifier onlyDelegateCall() {
        _checkDelegateCall();
        _;
    }

    function validate(address asset, bytes32 config) external view {
        Id id = Id.wrap(config);
        MarketParams memory marketParams = MORPHO.idToMarketParams(id);
        Market memory market = MORPHO.market(id);
        if (
            asset == address(0) || asset.code.length == 0 || Id.unwrap(marketParams.id()) != config
                || marketParams.loanToken != asset || marketParams.irm != address(ADAPTIVE_CURVE_IRM)
                || market.lastUpdate == 0 || !_isSeeded(config, market)
        ) {
            revert InvalidUnderlyingPoolConfig(asset, config);
        }
    }

    function totalAssets(address account, bytes32 config) external view returns (uint256) {
        return _totalAssets(account, config);
    }

    function deposit(address asset, bytes32 config, uint256 assets)
        external
        onlyDelegateCall
        returns (uint256 totalAssetsAfter)
    {
        MarketParams memory marketParams = _marketParams(asset, config);
        _checkDepositMarketSeeded(asset, config);
        IERC20 underlying = IERC20(asset);
        uint256 balanceBefore = underlying.balanceOf(address(this));

        underlying.forceApprove(address(MORPHO), assets);
        (uint256 assetsSupplied,) = MORPHO.supply(marketParams, assets, 0, address(this), bytes(""));

        uint256 balanceAfter = underlying.balanceOf(address(this));
        uint256 deposited = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
        if (assetsSupplied != assets || deposited != assets) revert UnderlyingPoolDepositFailed(assets, deposited);

        return _totalAssets(address(this), config);
    }

    function withdraw(address asset, bytes32 config, uint256 assets, address receiver)
        external
        onlyDelegateCall
        returns (uint256 totalAssetsAfter)
    {
        MarketParams memory marketParams = _marketParams(asset, config);
        uint256 balanceBefore = IERC20(asset).balanceOf(receiver);
        (uint256 assetsWithdrawn,) = MORPHO.withdraw(marketParams, assets, 0, address(this), receiver);
        uint256 balanceAfter = IERC20(asset).balanceOf(receiver);

        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (assetsWithdrawn != assets || received != assets) revert UnderlyingPoolWithdrawFailed(assets, received);

        return _totalAssets(address(this), config);
    }

    function _totalAssets(address account, bytes32 config) private view returns (uint256) {
        Position memory position = MORPHO.position(Id.wrap(config), account);
        if (position.supplyShares == 0) return 0;

        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) =
            AdaptiveCurveIrmLib.expectedMarketBalances(address(MORPHO), config, address(ADAPTIVE_CURVE_IRM));
        return position.supplyShares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

    function _marketParams(address asset, bytes32 config) private view returns (MarketParams memory params) {
        params = MORPHO.idToMarketParams(Id.wrap(config));
        if (Id.unwrap(params.id()) != config || params.loanToken != asset || params.irm != address(ADAPTIVE_CURVE_IRM)) {
            revert InvalidUnderlyingPoolConfig(asset, config);
        }
    }

    function _checkDepositMarketSeeded(address asset, bytes32 config) private view {
        if (MORPHO.position(Id.wrap(config), address(this)).supplyShares != 0) return;

        Market memory market = MORPHO.market(Id.wrap(config));
        if (!_isSeeded(config, market)) {
            revert InvalidUnderlyingPoolConfig(asset, config);
        }
    }

    function _isSeeded(bytes32 config, Market memory market) private view returns (bool) {
        return market.totalSupplyAssets != 0 && market.totalSupplyShares >= MIN_DEAD_SUPPLY_SHARES
            && MORPHO.position(Id.wrap(config), DEAD_ADDRESS).supplyShares >= MIN_DEAD_SUPPLY_SHARES;
    }

    function _checkDelegateCall() private view {
        if (address(this) == SELF) revert UnderlyingPoolDelegateCallOnly();
    }
}
