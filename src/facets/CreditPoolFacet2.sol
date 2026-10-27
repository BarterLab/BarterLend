// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import { CreditPoolBase } from "src/CreditPoolBase.sol";

contract CreditPoolFacet2 is CreditPoolBase {
    function debtOf(uint64 market, address account) external view returns (uint128) {
        return _debtOf(market, account);
    }

    function getBorrowOrderType(uint64 market, uint256 APR, address account) external view returns (BOrderType) {
        return _getBorrowOrderType(market, APR, account);
    }

    function placeBorrowOrder(address account, uint64 market, uint256 APR, uint128 amount) external {
        _placeBorrowOrder(account, market, APR, amount);
    }

    function placeReloanOrder(address account, uint64 market, uint256 APR, uint128 amount) external {
        _placeReloanOrder(account, market, APR, amount);
    }

    function cancelBorrowOrder(address account, uint64 market, uint256 APR, uint128 amount) external {
        _cancelBorrowOrder(account, market, APR, amount, BOrderType.Borrow);
    }

    function cancelReloanOrder(address account, uint64 market, uint256 APR, uint128 amount) external {
        _cancelBorrowOrder(account, market, APR, amount, BOrderType.Reloan);
    }

    function borrow(address account, uint64 market, uint128 amount, uint128 maxDebt) external {
        _borrow(account, market, amount, maxDebt);
    }

    function previewBorrow(uint64 market, uint128 amount, address borrower) external view returns (uint128 borrowed, uint128 debt) {
        return _previewBorrow(market, amount, borrower);
    }

    function previewReloan(uint64 market, uint128 amount, address account) external view returns (uint128 loanConsumed, uint128 assetsReceived) {
        return _previewReloan(market, amount, account);
    }

}
