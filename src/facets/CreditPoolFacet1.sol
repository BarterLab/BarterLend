// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import { CreditPoolBase } from "src/CreditPoolBase.sol";

contract CreditPoolFacet1 is CreditPoolBase {
    function balanceOf(address account) external view returns (uint128) {
        return _balanceOf(account);
    }

    function deposit(address recipient, uint128 amount) external {
        _deposit(recipient, amount);
    }

    function withdraw(address account, address to, uint128 amount) external {
        _withdraw(account, to, amount);
    }

    function getProvideOrderBalance(uint64 market, uint256 APR, address account) external view returns (uint128) {
        return _getProvideOrderBalance(market, APR, account);
    }

    function getMarketLoan(uint64 market) external view returns (uint128) {
        return _getMarketLoan(market);
    }

    function getMarketBalance(uint64 market) external view returns (uint128) {
        return _getMarketBalance(market);
    }

    function claim(address account, uint64 market, uint128 amount) external {
        _claim(account, market, amount);
    }

    function transferLoan(uint64 market, address to, uint128 amount) external {
        _transferLoan(market, to, amount);
    }

    function offset(address account, uint64 market, uint128 amount) external {
        _offset(account, market, amount);
    }

    function reconcileReloanOrder(address account, uint64 market) external {
        _reconcileReloanOrder(account, market);
    }

    function loanOf(uint64 market, address account) external view returns (uint128 loan) {
        return _loanOf(market, account);
    }

    function getAllBorrowOrders(uint64 market, address account) external view returns (BorrowOrderView[] memory orders) {
        return _getAllBorrowOrders(market, account);
    }

    function previewProvideExactIn(uint64 market, uint128 assetsAmount, uint128 minLoanAmount, uint16 maxCrossedOrders, address account) external view returns (uint128 collectedLoan, uint128 consumedAssets, uint16 crossedOrders) {
        return _previewProvide(market, assetsAmount, minLoanAmount, Direction.ExactIn, maxCrossedOrders, account);
    }

    function previewProvideExactOut(uint64 market, uint128 maxAssetsAmount, uint128 loanAmount, uint16 maxCrossedOrders, address account) external view returns (uint128 collectedLoan, uint128 consumedAssets, uint16 crossedOrders) {
        return _previewProvide(market, maxAssetsAmount, loanAmount, Direction.ExactOut, maxCrossedOrders, account);
    }

    function liquidate(uint64 market, address borrower, uint128 debtAmount, uint256 minDiscountOut, uint256 deadline, bytes calldata data) external {
        _liquidate(market, borrower, debtAmount, minDiscountOut, deadline, data);
    }

    function getProvideOrderbook(uint64 market) external view returns (ProvideOrderbookTickView[] memory ticks) {
        return _getProvideOrderbook(market);
    }

    function getBorrowOrderbook(uint64 market) external view returns (BorrowOrderbookTickView[] memory ticks) {
        return _getBorrowOrderbook(market);
    }

    function getBorrowOrderBalance(uint64 market, uint256 APR, address account) external view returns (uint128) {
        return _getBorrowOrderBalance(market, APR, account);
    }

}
