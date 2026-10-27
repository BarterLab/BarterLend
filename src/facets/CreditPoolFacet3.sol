// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import { CreditPoolBase } from "src/CreditPoolBase.sol";

contract CreditPoolFacet3 is CreditPoolBase {
    function collateralOf(uint64 market, address account) external view returns (uint128) {
        return _collateralOf(market, account);
    }

    function reloan(address account, uint64 market, uint128 amount, uint128 minAssets) external {
        _reloan(account, market, amount, minAssets);
    }

    function depositCollateral(address account, uint64 market, uint128 amount) external {
        _depositCollateral(account, market, amount);
    }

    function withdrawCollateral(address account, uint64 market, address to, uint128 amount) external {
        _withdrawCollateral(account, market, to, amount);
    }

    function moveCollateral(address account, uint64 fromMarket, uint64 toMarket, uint128 amount) external {
        _moveCollateral(account, fromMarket, toMarket, amount);
    }

    function getHealthFactor(uint64 market, address account) external view returns (uint256 healthFactor) {
        return _getHealthFactor(market, account);
    }

    function isLiquidatable(uint64 market, address account) external view returns (bool) {
        return _isLiquidatable(market, account);
    }

    function refinanceDebts(
        address account,
        uint64 fromMarket,
        uint256 maxDebtFactor,
        RefinanceDebtParams[] calldata refinances
    ) external returns (RefinanceDebtResult[] memory results) {
        return _refinanceDebts(account, fromMarket, maxDebtFactor, refinances);
    }

}
