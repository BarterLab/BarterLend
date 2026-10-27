// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import { Multicall } from "lib/openzeppelin-contracts/contracts/utils/Multicall.sol";
import { ReentrancyGuardTransient } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";

import { Delegator } from "src/Delegator.sol";
import { ICreditPool } from "src/interfaces/ICreditPool.sol";
import { ICreditPoolExplorerAPI, ICreditPoolBotAPI } from "src/interfaces/ICreditPool.sol";
import { UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";
import { CreditPoolBase } from "src/CreditPoolBase.sol";
import { MarketsConfig } from "src/lib/MarketsConfig.sol";

contract CreditPool is
    ICreditPool, ICreditPoolExplorerAPI, ICreditPoolBotAPI,
    CreditPoolBase,
    Delegator, Multicall, ReentrancyGuardTransient
{
    error OwnershipRenunciationDisabled();
    // Keep this error in the pool ABI when token transfers execute through facets.
    error SafeERC20FailedOperation(address token);

    uint256 public constant VERSION = 5;

    constructor(InitializationParams memory params, address[] memory facets)
        Delegator(facets)
    {
        _initialize(params);
    }


    function version() override(ICreditPool) external pure returns (uint256) {
        return VERSION;
    }



    function permit2() override(ICreditPool) external view returns (address) {
        return address(_permit2);
    }

    function priceOracle() override(ICreditPool) external view returns (address) {
        return address(_priceOracle);
    }



    function underlyingPool() override(ICreditPool) external view returns (UnderlyingPoolConfig memory) {
        return UnderlyingPoolConfig({
            adapter: address(_underlyingPoolAdapter),
            config: _underlyingPoolConfig
        });
    }



    function asset() override(ICreditPool) external view returns (address) {
        return address(_asset);
    }

    function collateral() override(ICreditPool) external view returns (address) {
        return address(_collateral);
    }



    function getStalePriceWindow() override(ICreditPool) external view returns (uint64) {
        return _stalePriceWindow;
    }

    function getBorrowLTV() override(ICreditPool) external view returns (uint256) {
        return _borrowLTV;
    }

    function getLiquidationLTV() override(ICreditPool) external view returns (uint256) {
        return _liquidationLTV;
    }



    function getProtocolFee(uint64 market) override(ICreditPool) external view returns (uint256) {
        return _getProtocolFee(market);
    }

    function setProtocolFee(uint256 newProtocolFee) override(ICreditPool) external onlyOwner {
        _setProtocolFee(newProtocolFee);
    }



    function getTotalCollateralCap() override(ICreditPool) external view returns (uint128) {
        return _totalCollateralCap;
    }

    function setTotalCollateralCap(uint128 newTotalCollateralCap) override(ICreditPool) external onlyOwner {
        _setTotalCollateralCap(newTotalCollateralCap);
    }



    function getBorrowOrderMinAmount() override(ICreditPool) external view returns (uint128) {
        return _borrowOrderMinAmount;
    }

    function setBorrowOrderMinAmount(uint128 newMinAmount) override(ICreditPool) external onlyOwner {
        _setBorrowOrderMinAmount(newMinAmount);
    }



    function getProvideOrderMinAmount() override(ICreditPool) external view returns (uint128) {
        return _provideOrderMinAmount;
    }

    function setProvideOrderMinAmount(uint128 newMinAmount) override(ICreditPool) external onlyOwner {
        _setProvideOrderMinAmount(newMinAmount);
    }



    function getMaxActiveProvideOrders() override(ICreditPool) external view returns (uint8) {
        return _maxActiveProvideOrders;
    }

    function setMaxActiveProvideOrders(uint8 newMax) override(ICreditPool) external onlyOwner {
        _setMaxActiveProvideOrders(newMax);
    }



    function getMaxActiveBorrowOrders() override(ICreditPool) external view returns (uint8) {
        return _maxActiveBorrowOrders;
    }

    function setMaxActiveBorrowOrders(uint8 newMax) override(ICreditPool) external onlyOwner {
        _setMaxActiveBorrowOrders(newMax);
    }



    function getMinDebtRemainingAfterLiquidation() override(ICreditPool) external view returns (uint128) {
        return _minDebtRemainingAfterLiquidation;
    }

    function setMinDebtRemainingAfterLiquidation(uint128 newMin) override(ICreditPool) external onlyOwner {
        _setMinDebtRemainingAfterLiquidation(newMin);
    }



    function getLiquidationDiscountMin(uint64 market) override(ICreditPool) external view returns (uint256) {
        return _getLiquidationDiscountMin(market);
    }

    function setLiquidationDiscountMin(uint256 newMin) override(ICreditPool) external onlyOwner {
        _setLiquidationDiscountMin(newMin);
    }



    function getLiquidationDiscountMax(uint64 market) override(ICreditPool) external view returns (uint256) {
        return _getLiquidationDiscountMax(market);
    }

    function setLiquidationDiscountMax(uint256 newMax) override(ICreditPool) external onlyOwner {
        _setLiquidationDiscountMax(newMax);
    }



    function getLiquidationGracePeriod(uint64 market) override(ICreditPool) external view returns (uint64) {
        return _getLiquidationGracePeriod(market);
    }

    function setLiquidationGracePeriod(uint64 newGracePeriod) override(ICreditPool) external onlyOwner {
        _setLiquidationGracePeriod(newGracePeriod);
    }



    function getMarketsConfig() override(ICreditPool) external view returns (MarketsConfig memory) {
        return _marketsConfig;
    }

    function getActiveMarkets() override(ICreditPool) external view returns (uint64[] memory) {
        return _marketsConfig.getActiveMarkets(uint64(block.timestamp));
    }



    function settleUnderlyingPoolDust() override(ICreditPool) external onlyOwner nonReentrant {
        _settleUnderlyingPoolDust();
    }



    function setDelegate(address delegate, uint256 actions) override(ICreditPool) external {
        _setDelegate(delegate, actions);
    }

    function getDelegateActions(address account, address delegate) override(ICreditPool) external view returns (uint256) {
        return _getDelegateActions(account, delegate);
    }

    function isDelegateApproved(address account, address delegate, uint256 action) override(ICreditPool) external view returns (bool) {
        return _isDelegateApproved(account, delegate, action);
    }



    function balanceOf(address account) override(ICreditPool) external view returns (uint128 balance) {
        account; balance;
        _delegateView(_facet1);
    }

    function deposit(address recipient, uint128 amount) override(ICreditPool) external nonReentrant {
        recipient; amount;
        _delegate(_facet1);
    }

    function withdraw(address account, address to, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_WITHDRAW);
        account; to; amount;
        _delegate(_facet1);
    }



    function placeProvideOrder(address account, uint64 market, uint256 APR, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_PLACE_PROVIDE_ORDER);
        _placeProvideOrder(account, market, APR, amount);
    }

    function cancelProvideOrder(address account, uint64 market, uint256 APR, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_CANCEL_PROVIDE_ORDER);
        _cancelProvideOrder(account, market, APR, amount);
    }

    function getProvideOrderBalance(uint64 market, uint256 APR, address account) override(ICreditPool) external view returns (uint128 balance) {
        market; APR; account; balance;
        _delegateView(_facet1);
    }



    function placeBorrowOrder(address account, uint64 market, uint256 APR, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_PLACE_BORROW_ORDER);
        account; market; APR; amount;
        _delegate(_facet2);
    }

    function placeReloanOrder(address account, uint64 market, uint256 APR, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_PLACE_RELOAN_ORDER);
        account; market; APR; amount;
        _delegate(_facet2);
    }

    function cancelBorrowOrder(address account, uint64 market, uint256 APR, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_CANCEL_BORROW_ORDER);
        account; market; APR; amount;
        _delegate(_facet2);
    }

    function cancelReloanOrder(address account, uint64 market, uint256 APR, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_CANCEL_RELOAN_ORDER);
        account; market; APR; amount;
        _delegate(_facet2);
    }

    function reconcileReloanOrder(address account, uint64 market) override(ICreditPool) external nonReentrant {
        account; market;
        _delegate(_facet1);
    }

    function getBorrowOrderBalance(uint64 market, uint256 APR, address account) override(ICreditPool) external view returns (uint128 balance) {
        market; APR; account; balance;
        _delegateView(_facet1);
    }

    function getBorrowOrderType(uint64 market, uint256 APR, address account) override(ICreditPool) external view returns (BOrderType orderType) {
        market; APR; account; orderType;
        _delegateView(_facet2);
    }



    function loanOf(uint64 market, address account) override(ICreditPool) external view returns (uint128 loan) {
        market; account; loan;
        _delegateView(_facet1);
    }

    function transferLoan(uint64 market, address to, uint128 amount) override(ICreditPool) external nonReentrant {
        market; to; amount;
        _delegate(_facet1);
    }

    function claim(address account, uint64 market, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_CLAIM);
        account; market; amount;
        _delegate(_facet1);
    }

    function debtOf(uint64 market, address account) override(ICreditPool) external view returns (uint128 debt) {
        market; account; debt;
        _delegateView(_facet2);
    }

    function repay(address account, address borrower, uint64 market, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, account == borrower ? DELEGATE_REPAY : DELEGATE_REPAY_ANY);
        _repay(account, borrower, market, amount);
    }



    function offset(address account, uint64 market, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_OFFSET);
        account; market; amount;
        _delegate(_facet1);
    }



    function collateralOf(uint64 market, address account) override(ICreditPool) external view returns (uint128 collateral_) {
        market; account; collateral_;
        _delegateView(_facet3);
    }

    function depositCollateral(address account, uint64 market, uint128 amount) override(ICreditPool) external nonReentrant {
        account; market; amount;
        _delegate(_facet3);
    }

    function withdrawCollateral(address account, uint64 market, address to, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_WITHDRAW_COLLATERAL);
        account; market; to; amount;
        _delegate(_facet3);
    }

    function moveCollateral(address account, uint64 fromMarket, uint64 toMarket, uint128 amount) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_MOVE_COLLATERAL);
        account; fromMarket; toMarket; amount;
        _delegate(_facet3);
    }



    function provideExactIn(address account, uint64 market, uint128 assetsAmount, uint128 minLoanAmount, uint16 maxCrossedOrders) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_PROVIDE);
        account; market; assetsAmount; minLoanAmount; maxCrossedOrders;
        _delegate(_facet4);
    }

    function previewProvideExactIn(uint64 market, uint128 assetsAmount, uint128 minLoanAmount, uint16 maxCrossedOrders, address account) override(ICreditPool) external view returns (uint128 collectedLoan, uint128 consumedAssets, uint16 crossedOrders) {
        market; assetsAmount; minLoanAmount; maxCrossedOrders; account;
        collectedLoan; consumedAssets; crossedOrders;
        _delegateView(_facet1);
    }



    function provideExactOut(address account, uint64 market, uint128 maxAssetsAmount, uint128 loanAmount, uint16 maxCrossedOrders) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_PROVIDE);
        account; market; maxAssetsAmount; loanAmount; maxCrossedOrders;
        _delegate(_facet4);
    }

    function previewProvideExactOut(uint64 market, uint128 maxAssetsAmount, uint128 loanAmount, uint16 maxCrossedOrders, address account) override(ICreditPool) external view returns (uint128 collectedLoan, uint128 consumedAssets, uint16 crossedOrders) {
        market; maxAssetsAmount; loanAmount; maxCrossedOrders; account;
        collectedLoan; consumedAssets; crossedOrders;
        _delegateView(_facet1);
    }



    function borrow(address account, uint64 market, uint128 amount, uint128 maxDebt) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_BORROW);
        account; market; amount; maxDebt;
        _delegate(_facet2);
    }

    function previewBorrow(uint64 market, uint128 amount, address borrower) override(ICreditPool) external view returns (uint128 borrowed, uint128 debt) {
        market; amount; borrower; borrowed; debt;
        _delegateView(_facet2);
    }

    function refinanceDebts(
        address account,
        uint64 fromMarket,
        uint256 maxDebtFactor,
        RefinanceDebtParams[] calldata refinances
    )
        override(ICreditPool)
        external
        nonReentrant
        returns (RefinanceDebtResult[] memory results)
    {
        _requireDelegate(account, DELEGATE_BORROW | DELEGATE_REPAY | DELEGATE_MOVE_COLLATERAL);
        account; fromMarket; maxDebtFactor; refinances; results;
        return abi.decode(_delegateReturn(_facet3), (RefinanceDebtResult[]));
    }



    function reloan(address account, uint64 market, uint128 amount, uint128 minAssets) override(ICreditPool) external nonReentrant {
        _requireDelegate(account, DELEGATE_RELOAN);
        account; market; amount; minAssets;
        _delegate(_facet3);
    }

    function previewReloan(uint64 market, uint128 amount, address account) override(ICreditPool) external view returns (uint128 loanConsumed, uint128 assetsReceived) {
        market; amount; account; loanConsumed; assetsReceived;
        _delegateView(_facet2);
    }



    function sweep(address account, uint64 market, uint128 amount, uint16 maxCrossedOrders) override(ICreditPool) external nonReentrant {
        account; market; amount; maxCrossedOrders;
        _delegate(_facet4);
    }



    function getHealthFactor(uint64 market, address account) override(ICreditPool) external view returns (uint256 healthFactor) {
        market; account; healthFactor;
        _delegateView(_facet3);
    }

    function isLiquidatable(uint64 market, address account) override(ICreditPool) external view returns (bool liquidatable) {
        market; account; liquidatable;
        _delegateView(_facet3);
    }



    function liquidate(uint64 market, address borrower, uint128 debtAmount, uint256 minDiscountOut, uint256 deadline, bytes calldata data) override(ICreditPoolBotAPI) external nonReentrant {
        market; borrower; debtAmount; minDiscountOut; deadline; data;
        _delegate(_facet1);
    }



    function getUserMarkets(address account, uint256 start, uint256 limit) override(ICreditPoolExplorerAPI) external view returns (uint64[] memory markets) {
        return _getUserMarkets(account, start, limit);
    }

    function getMarketUsers(uint64 market, uint256 start, uint256 limit) override(ICreditPoolExplorerAPI) external view returns (address[] memory) {
        return _getMarketUsers(market, start, limit);
    }

    function getAllProvideOrders(uint64 market, address account) override(ICreditPoolExplorerAPI) external view returns (ProvideOrderView[] memory orders) {
        market; account; orders;
        _delegateView(_facet4);
    }

    function getAllBorrowOrders(uint64 market, address account) override(ICreditPoolExplorerAPI) external view returns (BorrowOrderView[] memory orders) {
        market; account; orders;
        _delegateView(_facet1);
    }

    function getMarketLoan(uint64 market) override(ICreditPoolExplorerAPI) external view returns (uint128 loan) {
        market; loan;
        _delegateView(_facet1);
    }

    function getMarketBalance(uint64 market) override(ICreditPoolExplorerAPI) external view returns (uint128 balance) {
        market; balance;
        _delegateView(_facet1);
    }

    function getProvideOrderbook(uint64 market) override(ICreditPoolExplorerAPI) external view returns (ProvideOrderbookTickView[] memory ticks) {
        market; ticks;
        _delegateView(_facet1);
    }

    function getBorrowOrderbook(uint64 market) override(ICreditPoolExplorerAPI) external view returns (BorrowOrderbookTickView[] memory ticks) {
        market; ticks;
        _delegateView(_facet1);
    }


    function _delegateView(address facet) internal view override nonReentrantView {
        super._delegateView(facet);
    }



    function multicall(bytes[] calldata data) override(Multicall, ICreditPool) public returns (bytes[] memory results) {
        _enterPriceCacheScope();
        results = Multicall.multicall(data);
        _exitPriceCacheScope();
    }
}
