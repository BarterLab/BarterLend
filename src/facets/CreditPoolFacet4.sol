// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import { CreditPoolBase } from "src/CreditPoolBase.sol";

contract CreditPoolFacet4 is CreditPoolBase {
    function sweep(address account, uint64 market, uint128 amount, uint16 maxCrossedOrders) external {
        _sweep(account, market, amount, maxCrossedOrders);
    }

    function getAllProvideOrders(uint64 market, address account) external view returns (ProvideOrderView[] memory orders) {
        return _getAllProvideOrders(market, account);
    }

    function provideExactIn(address account, uint64 market, uint128 assetsAmount, uint128 minLoanAmount, uint16 maxCrossedOrders) external {
        _provideExactIn(account, market, assetsAmount, minLoanAmount, maxCrossedOrders);
    }

    function provideExactOut(address account, uint64 market, uint128 maxAssetsAmount, uint128 loanAmount, uint16 maxCrossedOrders) external {
        _provideExactOut(account, market, maxAssetsAmount, loanAmount, maxCrossedOrders);
    }

}
