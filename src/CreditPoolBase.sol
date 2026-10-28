// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import { TransientSlot } from "lib/openzeppelin-contracts/contracts/utils/TransientSlot.sol";

import { ILiquidator } from "src/interfaces/ILiquidator.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { IUnderlyingPool } from "src/interfaces/IUnderlyingPool.sol";
import { IPermit2 } from "lib/permit2/src/interfaces/IPermit2.sol";

import { ICreditPoolErrors, ICreditPoolEvents, ICreditPoolTypes, ICreditPoolConstants, ICreditPoolExplorerAPITypes } from "src/interfaces/ICreditPool.sol";

import { BitSet } from "src/lib/BitSet.sol";
import { PriceMath } from "src/lib/PriceMath.sol";
import { SetUint64, SetUint256 } from "src/lib/Set.sol";
import { MarketsConfig } from "src/lib/MarketsConfig.sol";

abstract contract CreditPoolBase is
    ICreditPoolExplorerAPITypes,
    ICreditPoolEvents, ICreditPoolTypes, ICreditPoolErrors, ICreditPoolConstants
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using Math for uint256;
    using PriceMath for IPriceOracle.Price;
    using TransientSlot for *;

    // These namespaced transient slots cache one validated oracle snapshot only inside pool.multicall.
    bytes32 private constant _PRICE_CACHE_SCOPE_SLOT = keccak256("fixprice.credit-pool.price-cache.scope");
    bytes32 private constant _PRICE_CACHE_NUMERATOR_SLOT = keccak256("fixprice.credit-pool.price-cache.numerator");
    bytes32 private constant _PRICE_CACHE_DENOMINATOR_SLOT = keccak256("fixprice.credit-pool.price-cache.denominator");

    IPriceOracle internal _priceOracle;
    IPermit2     internal _permit2;

    IUnderlyingPool internal _underlyingPoolAdapter;
    bytes32         internal _underlyingPoolConfig;

    IERC20       internal _asset;
    IERC20       internal _collateral;

    uint64       internal _stalePriceWindow;
    uint256      internal _borrowLTV;
    uint256      internal _liquidationLTV;

    uint256      internal _protocolFee;

    uint128      internal _totalCollateral;
    uint128      internal _totalCollateralCap;

    uint128      internal _borrowOrderMinAmount;
    uint128      internal _provideOrderMinAmount;

    uint8        internal _maxActiveProvideOrders;
    uint8        internal _maxActiveBorrowOrders;

    uint256      internal _liquidationDiscountMin;
    uint256      internal _liquidationDiscountMax;
    uint64       internal _liquidationGracePeriod;
    uint128      internal _minDebtRemainingAfterLiquidation;

    MarketsConfig internal _marketsConfig;

    struct PriceCache {
        IPriceOracle.Price price;
        bool loaded;
    }

    struct RefinanceTotals {
        uint256 debtRepaid;
        uint256 newDebt;
    }

    struct UserPOrder {
        uint256 shares;
        uint64 tickGeneration;
        uint128 disabledAssets;
        uint256 loanIndexSnapshot;
    }

    struct UserPOrdersByAPR {
        SetUint256 aprs;
        mapping(uint256 APR => UserPOrder) byAPR;
    }

    struct UserPOrdersByMarket {
        SetUint64 markets;
        mapping(uint64 market => UserPOrdersByAPR) byMarket;
    }

    struct UserBOrder {
        uint128 amount;
        uint48 queueNodeId;
        BOrderType orderType;
    }

    struct UserBOrdersByAPR {
        SetUint256 aprs;
        mapping(uint256 APR => UserBOrder) byAPR;

        // type(uint256).max means no active reloan order; zero is a valid APR.
        uint256 reloanAPR;
    }

    struct UserBOrdersByMarket {
        SetUint64 markets;
        mapping(uint64 market => UserBOrdersByAPR) byMarket;
    }

    struct UserLoan {
        uint256 shares;
    }

    struct User {
        SetUint64 markets;

        UserPOrdersByMarket porders;
        UserBOrdersByMarket borders;
        mapping(uint64 market => uint128) debt;
        mapping(uint64 market => uint128) collateral;
        mapping(uint64 market => UserLoan) loan;

        uint128 balance;
    }

    uint256 internal _globalUnderlyingPoolIndex = SCALE;
    uint256 internal _lastUnderlyingPoolAssets;
    uint256 internal _underlyingPoolReserve;
    mapping(address => User) internal _users;
    mapping(address account => mapping(address delegate => uint256 actions)) internal _delegations;

    struct POrderbookTick {
        uint64 tickGeneration;
        uint64 bucketGeneration;
        uint64 underlyingPoolGeneration;
        mapping(uint64 tickGeneration => uint64 bucketGeneration) bucketGenerationByTickGeneration;

        uint256 totalShares;
        uint128 assets;
        uint256 indexSnapshot;

        mapping(uint64 generation => uint256) loanIndex;
    }

    struct BucketSettlement {
        uint256 indexSnapshot;
        uint256 netInterestDuration;
        uint256 debtWeight;
        uint256 loanShares;
    }

    struct POrderbookBucket {
        uint64  bucketGeneration;
        uint64  underlyingPoolGeneration;

        uint128 assets;
        uint256 assetsTimesAPR;
        uint256 indexSnapshot;

        mapping(uint64 bucketGeneration => BucketSettlement) settlementByGeneration;
        bool mayHaveLiveTicks;
    }

    struct POrderbook {
        mapping(uint256 APR => POrderbookTick) tickByAPR;
        mapping(uint256 bucketId => POrderbookBucket) bucketById;
    }

    struct AddressQueueNode {
        address value;
        uint48  next;
        uint48  prev;
    }

    struct AddressQueue {
        uint48  head;
        uint48  tail;
        uint48  _nextId;
        uint48  length;
        mapping(uint48 => AddressQueueNode) nodes;
    }

    struct BOrderbookTick {
        uint128 totalBorrowAmount;
        uint128 totalReloanAmount;

        AddressQueue borrowers;
    }

    struct BOrderbook {
        BitSet aprs;
        mapping(uint256 APR => BOrderbookTick) tickByAPR;
    }

    struct LoanPool {
        uint128 balance;

        uint128 totalAssets;
        uint256 totalShares;
    }

    struct MarketCachedConfig {
        bool    initialized;

        uint64  liquidationGracePeriod;
        uint256 liquidationDiscountMin;
        uint256 liquidationDiscountMax;

        uint256 protocolFee;
    }

    struct MarketUsers {
        address[] accounts;
        mapping(address account => bool) seen;
    }

    struct Market {
        POrderbook  porderbook;
        BOrderbook  borderbook;

        LoanPool    loanPool;
        MarketUsers users;

        MarketCachedConfig cachedConfig;
    }

    mapping(uint64 market => Market) internal _markets;

    uint64 internal _underlyingPoolGeneration;

    uint256 constant internal RIGHTMOST_BUCKET_ID = (MAX_APR / APR_TICK_SPACING) >> BUCKET_SIZE_AS_POWER_OF_TWO;
    uint256 constant internal NO_RELOAN_APR = type(uint256).max;



    // ==============================================================
    // Initialization
    //
    // Bootstraps the pool storage layout and validates the initial
    // protocol configuration before any market activity starts.
    //
    // API:
    // - _initialize(params)
    // ==============================================================

    function _initialize(InitializationParams memory params) internal {
        owner = params.owner;
        _checkOwner(params.owner);

        _permit2 = IPermit2(params.permit2);

        _asset = IERC20(params.asset);
        _collateral = IERC20(params.collateral);

        address adapter = params.underlyingPool.adapter;
        if (adapter == address(0) || adapter.code.length == 0) revert InvalidUnderlyingPoolAdapter(adapter);
        _underlyingPoolAdapter = IUnderlyingPool(adapter);
        _underlyingPoolConfig = params.underlyingPool.config;
        _underlyingPoolAdapter.validate(params.asset, _underlyingPoolConfig);

        _priceOracle = IPriceOracle(params.priceOracle);
        if (address(_priceOracle.source()) != address(_collateral)) revert InvalidPriceOracle();
        if (address(_priceOracle.target()) != address(_asset)) revert InvalidPriceOracle();

        _stalePriceWindow = params.stalePriceWindow;
        if (_stalePriceWindow == 0) revert InvalidStalePriceWindow();

        _borrowOrderMinAmount = params.borrowOrderMinAmount;
        _provideOrderMinAmount = params.provideOrderMinAmount;
        _checkBorrowOrderMinAmount(_borrowOrderMinAmount);
        _checkProvideOrderMinAmount(_provideOrderMinAmount);

        _maxActiveBorrowOrders = params.maxActiveBorrowOrders;
        _maxActiveProvideOrders = params.maxActiveProvideOrders;

        _protocolFee = params.protocolFee;
        _totalCollateralCap = params.totalCollateralCap;
        _checkProtocolFee(_protocolFee);

        _marketsConfig = MarketsConfig({
            start: uint64(block.timestamp),
            durations: params.marketsConfig.durations,
            active: params.marketsConfig.active,
            extensions: params.marketsConfig.extensions
        });
        if (!_marketsConfig.isValidSeed()) revert InvalidMarketsConfig();

        _liquidationLTV = params.liquidationLTV;
        if (_liquidationLTV >= UNIT) revert InvalidLiquidationLTV();
        _borrowLTV = params.borrowLTV;
        if (_borrowLTV > _liquidationLTV) revert InvalidBorrowLTV();

        _liquidationDiscountMin = params.liquidationDiscountMin;
        _liquidationDiscountMax = params.liquidationDiscountMax;
        _checkLiquidationDiscountMin(_liquidationDiscountMin);
        _checkLiquidationDiscountMax(_liquidationDiscountMax);

        _liquidationGracePeriod = params.liquidationGracePeriod;
        _checkLiquidationGracePeriod(_liquidationGracePeriod);

        _minDebtRemainingAfterLiquidation = params.minDebtRemainingAfterLiquidation;
    }



    // ==============================================================
    // Market / Admin
    //
    // Exposes market metadata and owner-controlled configuration for
    // fees, limits, and liquidation policy.
    // ==============================================================

    function _settleUnderlyingPoolDust() internal {
        uint256 assetsBefore = _syncUnderlyingPoolIndex();
        uint256 activeAssets = _activeUnderlyingPoolAssets(assetsBefore);
        if (_globalUnderlyingPoolIndex >= SCALE || activeAssets != 1) {
            revert UnderlyingPoolDustSettlementUnavailable(
                _globalUnderlyingPoolIndex,
                activeAssets,
                1
            );
        }

        uint256 assetsAfter = _withdrawUnderlyingPoolTo(address(this), 1);
        _creditBalance(owner, 1);
        _reconcileUnderlyingPoolWithdrawal(assetsBefore, 1, assetsAfter);

        emit UnderlyingPoolDustSettled(1, _underlyingPoolGeneration);
    }

    function _setProtocolFee(uint256 newProtocolFee) internal {
        _checkProtocolFee(newProtocolFee);

        _cacheActiveMarketsConfig();

        uint256 oldProtocolFee = _protocolFee;
        _protocolFee = newProtocolFee;
        _emitAdminConfigUpdated("protocolFee", oldProtocolFee, newProtocolFee);
    }

    function _setTotalCollateralCap(uint128 newTotalCollateralCap) internal {
        uint256 oldTotalCollateralCap = _totalCollateralCap;
        _totalCollateralCap = newTotalCollateralCap;
        _emitAdminConfigUpdated("totalCollateralCap", oldTotalCollateralCap, newTotalCollateralCap);
    }

    function _setBorrowOrderMinAmount(uint128 newMinAmount) internal {
        _checkBorrowOrderMinAmount(newMinAmount);

        uint128 oldMinAmount = _borrowOrderMinAmount;
        _borrowOrderMinAmount = newMinAmount;
        _emitAdminConfigUpdated("borrowOrderMinAmount", oldMinAmount, newMinAmount);
    }

    function _setProvideOrderMinAmount(uint128 newMinAmount) internal {
        _checkProvideOrderMinAmount(newMinAmount);

        uint128 oldMinAmount = _provideOrderMinAmount;
        _provideOrderMinAmount = newMinAmount;
        _emitAdminConfigUpdated("provideOrderMinAmount", oldMinAmount, newMinAmount);
    }

    function _setMaxActiveProvideOrders(uint8 newMax) internal {
        uint8 oldMax = _maxActiveProvideOrders;
        _maxActiveProvideOrders = newMax;
        _emitAdminConfigUpdated("maxActiveProvideOrders", oldMax, newMax);
    }

    function _setMaxActiveBorrowOrders(uint8 newMax) internal {
        uint8 oldMax = _maxActiveBorrowOrders;
        _maxActiveBorrowOrders = newMax;
        _emitAdminConfigUpdated("maxActiveBorrowOrders", oldMax, newMax);
    }

    function _setLiquidationDiscountMin(uint256 newMin) internal {
        _checkLiquidationDiscountMin(newMin);

        _cacheActiveMarketsConfig();

        uint256 oldMin = _liquidationDiscountMin;
        _liquidationDiscountMin = newMin;
        _emitAdminConfigUpdated("liquidationDiscountMin", oldMin, newMin);
    }

    function _setLiquidationDiscountMax(uint256 newMax) internal {
        _checkLiquidationDiscountMax(newMax);

        _cacheActiveMarketsConfig();

        uint256 oldMax = _liquidationDiscountMax;
        _liquidationDiscountMax = newMax;
        _emitAdminConfigUpdated("liquidationDiscountMax", oldMax, newMax);
    }

    function _setLiquidationGracePeriod(uint64 newGracePeriod) internal {
        _checkLiquidationGracePeriod(newGracePeriod);

        _cacheActiveMarketsConfig();

        uint64 oldGracePeriod = _liquidationGracePeriod;
        _liquidationGracePeriod = newGracePeriod;
        _emitAdminConfigUpdated("liquidationGracePeriod", oldGracePeriod, newGracePeriod);
    }

    function _setMinDebtRemainingAfterLiquidation(uint128 newMin) internal {
        uint128 oldMin = _minDebtRemainingAfterLiquidation;
        _minDebtRemainingAfterLiquidation = newMin;
        _emitAdminConfigUpdated("minDebtRemainingAfterLiquidation", oldMin, newMin);
    }



    // ==============================================================
    // Delegation
    //
    // Stores per-account action masks for operators that can execute
    // selected balance and position mutations on the account's behalf.
    // ==============================================================

    function _setDelegate(address delegate, uint256 actions) internal {
        if (delegate == address(0) || delegate == msg.sender) revert InvalidDelegate(delegate);
        if ((actions & ~DELEGATE_ALL) != 0) revert InvalidDelegateActions(actions);

        uint256 oldActions = _delegations[msg.sender][delegate];
        _delegations[msg.sender][delegate] = actions;

        emit DelegateUpdated(msg.sender, delegate, oldActions, actions);
    }

    function _getDelegateActions(address account, address delegate) internal view returns (uint256) {
        return _delegations[account][delegate];
    }

    function _isDelegateApproved(address account, address delegate, uint256 action) internal view returns (bool) {
        if (account == delegate) return true;
        if (action == 0 || (action & ~DELEGATE_ALL) != 0) return false;
        return (_delegations[account][delegate] & action) == action;
    }

    function _requireDelegate(address account, uint256 action) internal view {
        _requireAccount(account);
        if (account == msg.sender) return;
        if (action == 0 || (action & ~DELEGATE_ALL) != 0) revert InvalidDelegateActions(action);
        if ((_delegations[account][msg.sender] & action) != action) {
            revert DelegateNotApproved(account, msg.sender, action);
        }
    }

    function _requireAccount(address account) internal pure {
        if (account == address(0)) revert InvalidAccount(account);
    }



    // ==============================================================
    // Pool Balance
    //
    // Manages idle asset balances that have already been credited to a
    // user inside the pool and can be withdrawn directly.
    // ==============================================================

    function _balanceOf(address account) internal view returns (uint128) {
        return _users[account].balance;
    }

    function _deposit(address recipient, uint128 amount) internal {
        if (recipient == address(0)) revert InvalidTransferRecipient();
        _requireAmountInRange(amount, 1, type(uint128).max, false);

        _asset.safeTransferFrom(msg.sender, address(this), amount);
        _creditBalance(recipient, amount);

        emit AssetsDeposited(msg.sender, recipient, amount);
    }

    function _withdraw(address account, address to, uint128 amount) internal {
        amount = _debitBalance(account, amount, true);
        _asset.safeTransfer(to, amount);

        emit AssetsWithdrawn(account, to, amount);
    }

    function _creditBalance(address account, uint128 amount) private {
        User storage user = _users[account];
        _requireAmountInRange(amount, 1, type(uint128).max - user.balance, false);
        user.balance += amount;
    }

    function _debitBalance(address account, uint128 amount, bool maxValueOnMax) private returns (uint128) {
        User storage user = _users[account];
        amount = _requireAmountInRange(amount, 1, user.balance, maxValueOnMax);
        user.balance -= amount;
        return amount;
    }



    // ==============================================================
    // Provide Orders
    //
    // Maintains resting lender liquidity inside the provide orderbook.
    // These methods mint and burn porder exposure without immediately
    // matching it against borrowers.
    // ==============================================================

    function _placeProvideOrder(address account, uint64 market, uint256 APR, uint128 amount) internal {
        _cacheMarketsConfig(market);
        _requireActiveMarket(market);
        _requireAmountInRange(amount, 1, type(uint128).max, false);
        _requireValidAPR(APR);

        _regUserMarket(account, market);

        uint256 underlyingPoolAssetsBefore = _syncUnderlyingPoolIndex();
        POrderbookTick storage tick = _syncPOrderbookTick(market, APR);
        UserPOrder storage order = _syncPOrder(account, market, APR);

        _debitBalance(account, amount, false);
        uint256 underlyingPoolAssetsAfter = _depositUnderlyingPool(amount);
        if (underlyingPoolAssetsAfter < underlyingPoolAssetsBefore) {
            revert UnderlyingPoolPositionDecreased(underlyingPoolAssetsBefore, underlyingPoolAssetsAfter);
        }

        uint256 activeAssetsAfter = _activeUnderlyingPoolAssets(underlyingPoolAssetsAfter);
        // This keeps the next index nonzero for every partial loss that leaves at least one asset unit.
        if (activeAssetsAfter > _globalUnderlyingPoolIndex) {
            revert UnderlyingPoolIndexPrecisionExhausted(
                _globalUnderlyingPoolIndex,
                activeAssetsAfter
            );
        }

        uint128 creditedAssets = (underlyingPoolAssetsAfter - underlyingPoolAssetsBefore).toUint128();
        uint256 shares = _previewMintShares(tick, creditedAssets, _globalUnderlyingPoolIndex);
        if (shares == 0) revert ZeroSharesMinted(creditedAssets);

        _mintPOrderShares(account, market, APR, shares);
        _addPOrderbookTickAmountShares(market, APR, creditedAssets, shares);

        _syncAllPOrders(account, market); // clean up all empty porders
        _requireMaxPOrders(account, market);
        _requirePOrderMinAmount(order, tick, market, APR);

        _lastUnderlyingPoolAssets = underlyingPoolAssetsAfter;
        emit ProvideOrderPlaced(account, market, APR, creditedAssets, shares);
    }

    function _cancelProvideOrder(address account, uint64 market, uint256 APR, uint128 amount) internal {
        uint256 underlyingPoolAssetsBefore = _syncUnderlyingPoolIndex();
        POrderbookTick storage tick = _syncPOrderbookTick(market, APR);
        UserPOrder storage order = _syncPOrder(account, market, APR);
        POrderbookBucket storage bucket = _markets[market].porderbook.bucketById[_aprToBucketId(APR)];

        uint128 balance = _porderBalance(
            order,
            tick,
            bucket,
            _globalUnderlyingPoolIndex,
            _underlyingPoolGeneration
        );
        amount = _requireAmountInRange(amount, 1, balance, true);

        uint256 shares = amount == balance
            ? order.shares
            : Math.mulDiv(amount, tick.totalShares + VIRTUAL_SHARES, uint256(tick.assets) + VIRTUAL_ASSETS, Math.Rounding.Ceil);

        if (order.shares < shares) revert InsufficientProvideOrderShares(order.shares, shares);

        _burnPOrderShares(account, market, APR, shares);
        _removePOrderbookTickAmountShares(market, APR, amount, shares);

        uint256 underlyingPoolAssetsAfter = _withdrawUnderlyingPoolTo(address(this), amount);
        _creditBalance(account, amount);
        _reconcileUnderlyingPoolWithdrawal(underlyingPoolAssetsBefore, amount, underlyingPoolAssetsAfter);

        _requirePOrderMinAmount(order, tick, market, APR);
        emit ProvideOrderCancelled(account, market, APR, amount, shares);
    }

    function _getProvideOrderBalance(uint64 market, uint256 APR, address account) internal view returns (uint128 balance) {
        UserPOrder storage order = _users[account].porders.byMarket[market].byAPR[APR];
        POrderbookTick storage tick = _markets[market].porderbook.tickByAPR[APR];
        POrderbookBucket storage bucket = _markets[market].porderbook.bucketById[_aprToBucketId(APR)];

        (uint256 index, uint64 generation,) = _previewUnderlyingPoolState();
        return _porderBalance(order, tick, bucket, index, generation);
    }

    function _requirePOrderMinAmount(UserPOrder storage order, POrderbookTick storage tick, uint64 market, uint256 APR) internal view {
        POrderbookBucket storage bucket = _markets[market].porderbook.bucketById[_aprToBucketId(APR)];
        uint128 balance = _porderBalance(
            order,
            tick,
            bucket,
            _globalUnderlyingPoolIndex,
            _underlyingPoolGeneration
        );

        if (balance != 0 && balance < _provideOrderMinAmount) {
            revert ProvideOrderMinAmountNotReached(balance, _provideOrderMinAmount);
        }
    }



    // ==============================================================
    // Provide
    //
    // Fills borrow and reloan orders by consuming assets and producing
    // fixed-term loan exposure. Supports full-fill and stop-on-min-loan
    // execution, with a preview path that mirrors live matching.
    // ==============================================================

    function _provideExactIn(address account, uint64 market, uint128 assetsAmount, uint128 minLoanAmount, uint16 maxCrossedOrders) internal {
        _provideExact(account, market, assetsAmount, minLoanAmount, Direction.ExactIn, maxCrossedOrders);
    }

    function _provideExactOut(address account, uint64 market, uint128 maxAssetsAmount, uint128 loanAmount, uint16 maxCrossedOrders) internal {
        _provideExact(account, market, maxAssetsAmount, loanAmount, Direction.ExactOut, maxCrossedOrders);
    }

    function _provideExact(address account, uint64 market, uint128 amount, uint128 minLoan, Direction direction, uint16 maxCrossedOrders) private {
        _requireAmountInRange(amount, MIN_AMOUNT, type(uint128).max, false);

        uint256 protocolFee = _getProtocolFee(market);
        (uint128 collectedLoan, uint128 consumedAssets, uint128 fee,, ProvideOrderChanges memory changes) = _provide(
            account, market, amount, minLoan,
            direction, maxCrossedOrders,
            protocolFee
        );

        _debitBalance(account, consumedAssets, false);
        _creditProvidedLoan(account, market, collectedLoan, fee);

        _emitProvided(account, market, consumedAssets, collectedLoan, changes);
    }

    struct ProvideOrderChanges {
        OrderFill[] fills;
        InvalidatedBorrowOrder[] invalidatedOrders;
        ReconciledReloanOrder[] reconciliations;
        uint256 fillsCount;
        uint256 invalidatedOrdersCount;
        uint256 reconciliationsCount;
    }

    struct ProvideState {
        Direction direction;
        address provider;

        uint128 minLoan;
        uint64  market;
        uint256 protocolFee;

        uint256 debtDuration;
        PriceCache priceCache;
        uint128 collectedFee;

        uint128 collectedLoan;
        uint128 remainingAssets;
        uint16  crossedOrders;

        uint128 totalBorrowAmount;
        uint128 totalReloanAmount;
        uint48  queueHead;
        uint48  queueLength;

        address borrower;
        uint128 consumed;
        uint128 debt;
        uint128 borderAssets;
        BOrderType orderType;
        bool closeBorrowOrder;
        ProvideOrderChanges changes;

        LoanPool loanPool;
        uint256 burnedLoanShares;
    }

    enum Direction {
        ExactIn,
        ExactOut
    }

    function _provide(address provider, uint64 market, uint128 amount, uint128 minLoan, Direction direction, uint16 maxCrossedOrders, uint256 protocolFee)
        private
        returns (uint128 collectedLoan, uint128 consumedAssets, uint128 fee, uint16 crossedOrders, ProvideOrderChanges memory changes)
    {
        _requireActiveMarket(market);
        _requireAmountInRange(amount, 1, type(uint128).max, false);

        _regUserMarket(provider, market);

        ProvideState memory state;
        state.provider = provider;
        state.changes.fills = new OrderFill[](maxCrossedOrders);
        state.changes.invalidatedOrders = new InvalidatedBorrowOrder[](maxCrossedOrders);
        state.changes.reconciliations = new ReconciledReloanOrder[](maxCrossedOrders);
        _initProvideState(state, minLoan, direction, market, amount, protocolFee);
        BOrderbook storage borderbook = _markets[market].borderbook;

        for (
            (bool exists, uint256 APR) = borderbook.aprs.last();
            exists && (state.direction == Direction.ExactOut ? state.collectedLoan < state.minLoan : state.remainingAssets > 0);
            (exists, APR) = borderbook.aprs.prev(APR)
        ) {
            BOrderbookTick storage tick = borderbook.tickByAPR[APR];
            uint48 ownOrderNodeId;
            state.queueHead = tick.borrowers.head;
            state.queueLength = tick.borrowers.length;
            state.totalBorrowAmount = tick.totalBorrowAmount;
            state.totalReloanAmount = tick.totalReloanAmount;

            while (
                state.queueHead != 0 &&
                state.remainingAssets > 0 &&
                (state.direction == Direction.ExactOut ? state.collectedLoan < state.minLoan : true)
            ) {
                state.crossedOrders += 1;
                if (state.crossedOrders > maxCrossedOrders) {
                    revert ProvideMaxCrossedOrdersExceeded(state.crossedOrders, maxCrossedOrders);
                }

                state.borrower = tick.borrowers.nodes[state.queueHead].value;
                UserBOrder storage border = _users[state.borrower].borders.byMarket[state.market].byAPR[APR];

                if (state.borrower == state.provider) {
                    ownOrderNodeId = state.queueHead;
                    state.queueHead = tick.borrowers.nodes[state.queueHead].next;
                    continue;
                }

                if (border.orderType == BOrderType.Borrow && border.amount != 0) _cachePriceForMulticall();
                (uint128 netLoan, uint128 orderFee) = _initBOrderProviding(state, border, APR);

                if (state.consumed > 0) {
                    _creditBalance(state.borrower, state.consumed);
                    User storage borrower = _users[state.borrower];

                    if (state.orderType == BOrderType.Borrow) {
                        borrower.debt[state.market] += state.debt;

                        if (state.closeBorrowOrder) {
                            state.totalBorrowAmount = border.amount > state.totalBorrowAmount
                                ? 0
                                : state.totalBorrowAmount - border.amount;
                        } else {
                            border.amount -= state.consumed;
                            state.totalBorrowAmount -= state.consumed;
                        }
                    } else if (state.orderType == BOrderType.Reloan) {
                        borrower.loan[state.market].shares -= state.burnedLoanShares;
                    }

                    state.collectedLoan += netLoan;
                    state.collectedFee += orderFee;
                    state.remainingAssets -= state.consumed;
                }

                uint128 amountBeforeReconcile = border.amount;
                bool removeOrder = state.orderType == BOrderType.Reloan
                    ? _reconcileReloanAfterProvide(state, border)
                    : state.closeBorrowOrder;

                _recordBOrderExecution(state, APR, amountBeforeReconcile, removeOrder ? 0 : border.amount);

                if (removeOrder) {
                    // A restored self-order can keep the head below this consumed node's ID.
                    border.queueNodeId = 0;
                    state.queueHead = tick.borrowers.nodes[state.queueHead].next;
                    state.queueLength -= 1;

                    if (state.consumed == 0 && state.orderType == BOrderType.Borrow) {
                        state.totalBorrowAmount = border.amount > state.totalBorrowAmount
                            ? 0
                            : state.totalBorrowAmount - border.amount;
                    }
                }
            }

            // Keep the skipped order ahead of the unfilled suffix: rotating it to the tail
            // lets a provider accumulate dust orders by repeatedly skipping their own head.
            if (ownOrderNodeId != 0) {
                tick.borrowers.nodes[ownOrderNodeId].next = state.queueHead;
                if (state.queueHead == 0) {
                    tick.borrowers.tail = ownOrderNodeId;
                } else {
                    tick.borrowers.nodes[state.queueHead].prev = ownOrderNodeId;
                }
                state.queueHead = ownOrderNodeId;
            }

            if (state.queueHead == 0) {
                borderbook.aprs.remove(APR);
                state.totalBorrowAmount = 0;
                state.totalReloanAmount = 0;
            }

            if (state.queueHead != tick.borrowers.head || state.queueLength != tick.borrowers.length) {
                tick.borrowers.head = state.queueHead;

                if (state.queueHead == 0) {
                    tick.borrowers.tail = 0;
                } else {
                    tick.borrowers.nodes[state.queueHead].prev = 0;
                }

                tick.borrowers.length = state.queueLength;
            }

            tick.totalBorrowAmount = state.totalBorrowAmount;
            tick.totalReloanAmount = state.totalReloanAmount;
        }

        if (state.collectedLoan < state.minLoan) revert ProvideMinLoanNotReached(state.collectedLoan, state.minLoan);

        if (state.direction == Direction.ExactIn) {
            if (state.remainingAssets != 0) {
                revert ProvideNotFulfilled(amount - state.remainingAssets, amount);
            }
        }

        if (state.burnedLoanShares != 0) {
            LoanPool storage loanPool = _markets[market].loanPool;
            loanPool.totalAssets = state.loanPool.totalAssets;
            loanPool.totalShares = state.loanPool.totalShares;
        }

        return (state.collectedLoan, amount - state.remainingAssets, state.collectedFee, state.crossedOrders, state.changes);
    }

    function _creditProvidedLoan(
        address account,
        uint64 market,
        uint128 netLoan,
        uint128 fee
    ) private {
        uint128 grossLoan = netLoan + fee;
        uint256 grossShares = _mintLoanShares(market, grossLoan);

        if (account == owner) {
            _creditLoanShares(owner, market, grossShares);
            return;
        }

        uint256 feeShares = Math.mulDiv(grossShares, fee, grossLoan);

        _creditLoanShares(account, market, grossShares - feeShares);
        _creditLoanShares(owner, market, feeShares);
    }

    function _recordBOrderExecution(ProvideState memory state, uint256 APR, uint128 amountBeforeReconcile, uint128 amountAfter) private pure {
        ProvideOrderChanges memory changes = state.changes;
        if (state.consumed != 0) {
            uint256 count = changes.fillsCount;
            changes.fills[count] = OrderFill({
                account: state.borrower,
                APR: APR,
                assets: state.consumed,
                loanAmount: state.debt,
                isReloan: state.orderType == BOrderType.Reloan
            });
            changes.fillsCount = count + 1;
        }
        if (state.orderType == BOrderType.Reloan) {
            uint128 amountAfterFill = amountBeforeReconcile - state.debt;
            if (amountAfterFill != amountAfter) {
                uint256 count = changes.reconciliationsCount;
                changes.reconciliations[count] = ReconciledReloanOrder({
                    account: state.borrower,
                    APR: APR,
                    amount: amountAfterFill - amountAfter
                });
                changes.reconciliationsCount = count + 1;
            }
        } else if (amountAfter == 0 && amountBeforeReconcile > state.consumed) {
            _recordBorrowOrderInvalidation(changes, state.borrower, APR, amountBeforeReconcile - state.consumed);
        }
    }

    function _recordBorrowOrderInvalidation(ProvideOrderChanges memory changes, address account, uint256 APR, uint128 amount) private pure {
        uint256 count = changes.invalidatedOrdersCount;
        changes.invalidatedOrders[count] = InvalidatedBorrowOrder({ account: account, APR: APR, amount: amount });
        changes.invalidatedOrdersCount = count + 1;
    }

    function _emitProvided(address account, uint64 market, uint128 assets, uint128 loan, ProvideOrderChanges memory changes) private {
        OrderFill[] memory fills = changes.fills;
        InvalidatedBorrowOrder[] memory invalidatedOrders = changes.invalidatedOrders;
        ReconciledReloanOrder[] memory reconciledOrders = changes.reconciliations;
        // Trim unused capacity, including buffers with no recorded entries.
        uint256 count = changes.fillsCount;
        assembly ("memory-safe") { mstore(fills, count) }
        count = changes.invalidatedOrdersCount;
        assembly ("memory-safe") { mstore(invalidatedOrders, count) }
        count = changes.reconciliationsCount;
        assembly ("memory-safe") { mstore(reconciledOrders, count) }
        emit Provided(account, market, assets, loan, fills, invalidatedOrders, reconciledOrders);
    }

    function _reconcileReloanAfterProvide(ProvideState memory state, UserBOrder storage order)
        private
        returns (bool removeOrder)
    {
        uint128 oldAmount = order.amount;
        uint128 newAmount;

        if (state.borderAssets != 0) {
            newAmount = oldAmount - state.debt;

            if (newAmount != 0) {
                // A partial fill may leave a backed amount below the placement minimum; keep it fillable.
                uint128 loan = _previewRedeemLoanAssets(state.loanPool.totalAssets, state.loanPool.totalShares, _users[state.borrower].loan[state.market].shares);
                if (newAmount > loan) newAmount = loan;
            }
        }

        state.totalReloanAmount -= oldAmount - newAmount;
        order.amount = newAmount;
        return newAmount == 0;
    }

    function _previewProvide(uint64 market, uint128 amount, uint128 minLoan, Direction direction, uint16 maxCrossedOrders, address provider)
        internal view
        returns (uint128 collectedLoan, uint128 consumedAssets, uint16 crossedOrders)
    {
        _requireActiveMarket(market);
        _requireAmountInRange(amount, MIN_AMOUNT, type(uint128).max, false);

        BOrderbook storage borderbook = _markets[market].borderbook;
        ProvideState memory state;
        uint256 protocolFee = _getProtocolFee(market);
        _initProvideState(state, minLoan, direction, market, amount, protocolFee);

        for (
            (bool exists, uint256 APR) = borderbook.aprs.last();
            exists && (state.direction == Direction.ExactOut ? state.collectedLoan < state.minLoan : state.remainingAssets > 0);
            (exists, APR) = borderbook.aprs.prev(APR)
        ) {
            BOrderbookTick storage tick = borderbook.tickByAPR[APR];
            state.queueHead = tick.borrowers.head;

            while (
                state.queueHead != 0 &&
                state.remainingAssets > 0 &&
                (state.direction == Direction.ExactOut ? state.collectedLoan < state.minLoan : true)
            ) {
                if (state.crossedOrders + 1 > maxCrossedOrders) break;
                state.crossedOrders += 1;

                state.borrower = tick.borrowers.nodes[state.queueHead].value;
                UserBOrder storage border = _users[state.borrower].borders.byMarket[state.market].byAPR[APR];

                if (state.borrower == provider) {
                    state.queueHead = tick.borrowers.nodes[state.queueHead].next;
                    continue;
                }

                (uint128 netLoan,) = _initBOrderProviding(state, border, APR);

                if (state.consumed > 0) {
                    state.collectedLoan += netLoan;
                    state.remainingAssets -= state.consumed;
                }

                if (state.consumed == state.borderAssets || state.borderAssets == 0) {
                    state.queueHead = tick.borrowers.nodes[state.queueHead].next;
                }
            }
        }

        collectedLoan = state.collectedLoan;
        consumedAssets = amount - state.remainingAssets;
        crossedOrders = state.crossedOrders;
    }

    function _initProvideState(
        ProvideState memory state,
        uint128 minLoan,
        Direction direction,
        uint64 market,
        uint128 amount,
        uint256 protocolFee
    ) private view {
        state.direction = direction;

        state.minLoan = minLoan;
        state.market = market;
        state.protocolFee = protocolFee;

        state.debtDuration = _debtDuration(state.market);

        state.collectedLoan = 0;
        state.remainingAssets = amount;
        state.loanPool = _markets[market].loanPool;
    }

    function _loadProvidePrice(ProvideState memory state) private view {
        if (state.priceCache.loaded) return;
        state.priceCache.price = _price(state.priceCache);
        state.priceCache.loaded = true;
    }

    function _initBOrderProviding(ProvideState memory state, UserBOrder storage border, uint256 APR) private view returns (uint128 netLoan, uint128 fee) {
        uint128 availableDebt;

        state.borderAssets = border.amount;
        state.orderType = border.orderType;

        if (state.orderType == BOrderType.Reloan) {
            uint128 borrowerLoan = _previewRedeemLoanAssets(state.loanPool.totalAssets, state.loanPool.totalShares, _users[state.borrower].loan[state.market].shares);
            availableDebt = borrowerLoan < border.amount ? borrowerLoan : border.amount;
            state.borderAssets = _minimumAssetsForDebt(availableDebt, APR, state.debtDuration);
        } else if (state.borderAssets != 0) {
            _loadProvidePrice(state);
            User storage borrower = _users[state.borrower];
            uint128 maxDebt = uint128(Math.min(
                _borrowLTV.mulDiv(state.priceCache.price.quoteSourceToTarget(borrower.collateral[state.market]), UNIT),
                type(uint128).max
            ));
            uint128 currentDebt = borrower.debt[state.market];
            availableDebt = currentDebt < maxDebt ? maxDebt - currentDebt : 0;
            // Floor the principal so its rounded-up debt stays within the collateral limit.
            state.borderAssets = uint128(Math.min(border.amount, _assetsFor(availableDebt, APR, state.debtDuration, Math.Rounding.Floor)));
        }

        if (state.borderAssets > 0) {
            state.consumed = state.remainingAssets < state.borderAssets ? state.remainingAssets : state.borderAssets;
            state.debt = _debtFor(state.consumed, APR, state.debtDuration, Math.Rounding.Ceil);

            if (state.orderType == BOrderType.Reloan) {
                if (state.debt > availableDebt) state.debt = availableDebt;
            }

        } else {
            state.consumed = 0;
            state.debt = 0;
        }

        if (state.orderType == BOrderType.Reloan && state.debt == border.amount + 1) {
            state.debt -= 1;
        }

        fee = _protocolFeeAssets(state.consumed, state.debt, state.protocolFee);
        netLoan = state.debt - fee;

        if (state.direction == Direction.ExactOut && state.collectedLoan + netLoan > state.minLoan) {
            netLoan = state.minLoan - state.collectedLoan;
            state.debt = _grossLoanForNetLoan(
                netLoan, APR, state.debtDuration, state.protocolFee, state.debt
            );
            uint128 principal = _assetsFor(state.debt, APR, state.debtDuration, Math.Rounding.Ceil);
            state.consumed = uint128(Math.min(principal, state.consumed));
            fee = state.debt - netLoan;
        }

        if (state.orderType == BOrderType.Borrow) {
            // ExactOut can use the capped principal while booking less debt. Only cancel
            // the remainder when it cannot fund even one more asset unit at this APR.
            state.closeBorrowOrder = state.consumed == border.amount
                || availableDebt - state.debt < _debtFor(1, APR, state.debtDuration, Math.Rounding.Ceil);
        }

        if (state.orderType == BOrderType.Reloan && state.consumed > 0) {
            // One reloan order per seller per market; a partial fill ends this matching pass.
            // Advancing the pool here gives preview the same rounding recovery as execution.
            state.burnedLoanShares = _loanSharesForAssets(state.loanPool.totalAssets, state.loanPool.totalShares, _users[state.borrower].loan[state.market].shares, state.debt);
            state.loanPool.totalAssets -= state.debt;
            state.loanPool.totalShares -= state.burnedLoanShares;
        }
    }



    // ==============================================================
    // Loan Claims / Transfers
    //
    // Reads realized lender loan value and lets a lender either claim
    // matured assets or transfer loan exposure to another account.
    // ==============================================================

    function _loanOf(uint64 market, address account) internal view returns (uint128 loan) {
        User storage user = _users[account];
        UserPOrdersByAPR storage pordersByAPR = user.porders.byMarket[market];
        POrderbook storage orderbook = _markets[market].porderbook;
        LoanPool storage loanPool = _markets[market].loanPool;

        uint256 loanShares = user.loan[market].shares;

        for (uint256 i = 0; i < pordersByAPR.aprs.keys.length; i++) {
            uint256 APR = pordersByAPR.aprs.keys[i];
            UserPOrder storage order = pordersByAPR.byAPR[APR];
            POrderbookTick storage tick = orderbook.tickByAPR[APR];
            POrderbookBucket storage bucket = orderbook.bucketById[_aprToBucketId(APR)];
            loanShares += _porderLoanShares(order, tick, bucket, APR);
        }

        return _previewRedeemLoanAssets(loanPool, loanShares);
    }

    function _claim(address account, uint64 market, uint128 amount) internal {
        _syncAllPOrders(account, market);

        amount = _requireAmountInRange(amount, 1, __loanOf(market, account), true);

        _requirePoolBalance(_asset, amount);
        _requireMarketLoanAvailable(market, amount);
        _requireFinalizedMarket(market);

        uint256 shares = _burnLoanAssets(account, market, amount);
        _markets[market].loanPool.balance -= amount;
        _creditBalance(account, amount);
        emit Claimed(account, market, amount, shares);
    }

    function _transferLoan(uint64 market, address to, uint128 amount) internal {
        if (to == address(0)) revert InvalidTransferRecipient();

        _regUserMarket(to, market);
        _syncAllPOrders(msg.sender, market);

        LoanPool storage loanPool = _markets[market].loanPool;
        UserLoan storage sourceLoan = _users[msg.sender].loan[market];
        UserLoan storage targetLoan = _users[to].loan[market];

        amount = _requireAmountInRange(amount, 1, _previewRedeemLoanAssets(loanPool, sourceLoan.shares), true);
        uint256 shares = _loanSharesForAssets(loanPool, sourceLoan, amount);

        sourceLoan.shares -= shares;
        targetLoan.shares += shares;

        uint128 transferred = _previewRedeemLoanAssets(loanPool, shares);
        emit LoanTransferred(msg.sender, to, market, transferred);

        __reconcileReloanOrder(msg.sender, market);
    }



    // ==============================================================
    // Borrow Orders
    //
    // Maintains queued borrower and reloan demand inside the borrow-side
    // orderbook, including FIFO placement and cancellation.
    // ==============================================================

    function _placeBorrowOrder(address account, uint64 market, uint256 APR, uint128 amount) internal {
        _cacheMarketsConfig(market);
        UserBOrder storage order = __placeBorrowOrder(account, market, APR, amount, BOrderType.Borrow);

        uint128 debt = _debtFor(order.amount, APR, _debtDuration(market), Math.Rounding.Ceil);
        PriceCache memory priceCache;
        __requireHealthyDebt(market, account, priceCache, debt, 0);
        emit BorrowOrderPlaced(account, market, APR, amount);
    }

    function _placeReloanOrder(address account, uint64 market, uint256 APR, uint128 amount) internal {
        _cacheMarketsConfig(market);
        UserBOrder storage order = __placeBorrowOrder(account, market, APR, amount, BOrderType.Reloan);

        _syncAllPOrders(account, market);
        uint128 loan = __loanOf(market, account);
        if (order.amount > loan) revert ReloanOrderExceedsLoan(order.amount, loan);
        emit ReloanOrderPlaced(account, market, APR, amount);
    }

    function _reconcileReloanOrder(address account, uint64 market) internal {
        __reconcileReloanOrder(account, market);
    }

    function _requireBOrderMinAmount(UserBOrder storage order, uint64 market, uint256 APR) internal view {
        uint128 balanceInAssets;

        if (order.orderType == BOrderType.Reloan) {
            balanceInAssets = _minimumAssetsForDebt(order.amount, APR, _debtDuration(market));
        } else if (order.orderType == BOrderType.Borrow) {
            balanceInAssets = order.amount;
        }

        if (balanceInAssets != 0 && balanceInAssets < _borrowOrderMinAmount) {
            revert BorrowOrderMinAmountNotReached(balanceInAssets, _borrowOrderMinAmount);
        }
    }

    function _cancelBorrowOrder(address account, uint64 market, uint256 APR, uint128 amount, BOrderType orderType) internal {
        _requireActiveMarket(market);

        UserBOrdersByMarket storage borderByMarket = _users[account].borders;
        UserBOrdersByAPR storage borderByAPR = borderByMarket.byMarket[market];
        bool hadOrder = borderByAPR.aprs.has(APR);

        _syncAllBOrders(account, market);

        if (!borderByAPR.aprs.has(APR)) {
            if (hadOrder) return;
            _requireAmountInRange(amount, 1, 0, true);
            return;
        }

        UserBOrder storage order = borderByAPR.byAPR[APR];

        BOrderbook storage borderbook = _markets[market].borderbook;
        BOrderbookTick storage tick = borderbook.tickByAPR[APR];
        if (_isBOrderInactive(tick, order)) return;
        if (order.orderType != orderType) revert BorrowOrderTypeMismatch(orderType, order.orderType);

        amount = _requireAmountInRange(amount, 1, order.amount, true);

        order.amount -= amount;

        if (order.amount == 0) {
            _deleteBOrderIfEmpty(account, market, APR);
        }

        if (order.orderType == BOrderType.Borrow) {
            tick.totalBorrowAmount = amount > tick.totalBorrowAmount ? 0 : tick.totalBorrowAmount - amount;
        } else if (order.orderType == BOrderType.Reloan) {
            tick.totalReloanAmount = amount > tick.totalReloanAmount ? 0 : tick.totalReloanAmount - amount;
        }

        if (tick.borrowers.head == 0) {
            borderbook.aprs.remove(APR);
        }

        _requireBOrderMinAmount(order, market, APR);
        if (orderType == BOrderType.Borrow) {
            emit BorrowOrderCancelled(account, market, APR, amount, false);
        } else {
            emit ReloanOrderCancelled(account, market, APR, amount, false);
        }
    }

    function _getBorrowOrderType(uint64 market, uint256 APR, address account) internal view returns (BOrderType orderType) {
        UserBOrder storage order = _users[account].borders.byMarket[market].byAPR[APR];
        return order.orderType;
    }

    function __placeBorrowOrder(address account, uint64 market, uint256 APR, uint128 amount, BOrderType orderType)
        private
        returns (UserBOrder storage)
    {
        amount = _requireAmountInRange(amount, 1, type(uint128).max, false);
        _requireActiveMarket(market);
        _requireValidAPR(APR);

        _regUserMarket(account, market);

        _syncAllBOrders(account, market);

        UserBOrdersByMarket storage borderByMarket = _users[account].borders;
        UserBOrdersByAPR storage borderByAPR = borderByMarket.byMarket[market];

        if (orderType == BOrderType.Reloan && borderByMarket.markets.has(market)) {
            uint256 existingAPR = borderByAPR.reloanAPR;
            if (existingAPR != NO_RELOAN_APR && existingAPR != APR) {
                revert ReloanOrderAlreadyExists(existingAPR);
            }
        }

        UserBOrder storage order = borderByAPR.byAPR[APR];

        BOrderbook storage borderbook = _markets[market].borderbook;
        BOrderbookTick storage tick = borderbook.tickByAPR[APR];

        bool isNewOrder = borderByAPR.aprs.insert(APR);
        if (borderByMarket.markets.insert(market)) {
            borderByAPR.reloanAPR = NO_RELOAN_APR;
        }
        _requireMaxBOrders(account, market);

        if (isNewOrder) {
            borderbook.aprs.insert(APR);
            order.amount = 0;
            order.orderType = orderType;
            order.queueNodeId = _queue_push(tick.borrowers, account);
        } else {
            if (order.orderType != orderType) revert BorrowOrderTypeMismatch(orderType, order.orderType);
        }

        if (orderType == BOrderType.Reloan) {
            borderByAPR.reloanAPR = APR;
        }

        amount = _requireAmountInRange(amount, 1, type(uint128).max - order.amount, false);

        if (orderType == BOrderType.Borrow) {
            tick.totalBorrowAmount += amount;
        } else if (orderType == BOrderType.Reloan) {
            tick.totalReloanAmount += amount;
        }

        order.amount += amount;

        _requireBOrderMinAmount(order, market, APR);

        return order;
    }



    // ==============================================================
    // Borrow
    //
    // Consumes provide liquidity against queued borrower demand and
    // returns both live and previewed debt outcomes.
    // ==============================================================

    struct BorrowState {
        Direction direction;
        uint64 market;
        uint256 debtDuration;
        uint256 protocolFee;
        uint256 feeShares;
        uint128 remaining;
        uint128 assets;
        uint128 debt;
        uint256 loanSharesRemaining;
        uint256 endAPR;
    }

    function _borrow(address account, uint64 market, uint128 amount, uint128 maxDebt) internal {
        _requireActiveMarket(market);

        (, uint128 debt) = __borrow(market, amount, maxDebt, Direction.ExactOut, account, _getProtocolFee(market), 0, account);
        _creditBalance(account, amount);

        _users[account].debt[market] += debt;
        PriceCache memory priceCache;
        _requireHealthyDebt(market, account, priceCache);
    }

    // ==============================================================
    // Debt Service
    //
    // Exposes direct borrower debt reads and repayment paths that do not
    // require liquidation orchestration.
    // ==============================================================

    function _debtOf(uint64 market, address account) internal view returns (uint128) {
        return _users[account].debt[market];
    }

    function _repay(address account, address borrower, uint64 market, uint128 amount) internal {
        _requireAccount(borrower);
        User storage user = _users[borrower];

        amount = _requireAmountInRange(amount, 1, user.debt[market], true);

        _debitBalance(account, amount, false);
        user.debt[market] -= amount;
        _markets[market].loanPool.balance += amount;

        emit DebtRepaid(account, borrower, market, amount);
    }

    // ==============================================================
    // Debt Refinance
    //
    // Lets audited extensions atomically replace finalized debt with
    // active-market debt without exposing an unsafe intermediate state.
    // ==============================================================

    function _refinanceDebts(
        address account,
        uint64 fromMarket,
        uint256 maxDebtFactor,
        RefinanceDebtParams[] calldata refinances
    )
        internal
        returns (RefinanceDebtResult[] memory results)
    {
        _requireFinalizedMarket(fromMarket);

        results = new RefinanceDebtResult[](refinances.length);
        if (refinances.length == 0) return results;

        User storage user = _users[account];
        uint128 collateral = user.collateral[fromMarket];
        RefinanceTotals memory totals;

        for (uint256 i = 0; i < refinances.length; i++) {
            uint128 newDebt = _executeRefinance(user, account, fromMarket, refinances[i]);
            totals.debtRepaid += refinances[i].debtToRepay;
            totals.newDebt += newDebt;
            results[i].newDebt = newDebt;
        }

        uint256 factor = Math.mulDiv(UNIT, totals.newDebt, totals.debtRepaid) - UNIT;
        if (factor > maxDebtFactor) revert MaxRolloverFactorExceeded(factor, maxDebtFactor);

        _moveRefinanceCollateral(user, fromMarket, collateral, totals.newDebt, refinances, results);

        PriceCache memory priceCache;
        if (user.collateral[fromMarket] != collateral) _cleanupBOrders(user, account, fromMarket, priceCache);
        __requireHealthyDebt(fromMarket, account, priceCache, 0, 0);

        for (uint256 i = 0; i < refinances.length; i++) {
            _requireHealthyRefinanceAndEmit(account, fromMarket, refinances[i], results[i], priceCache);
        }
    }

    function _executeRefinance(
        User storage user,
        address account,
        uint64 fromMarket,
        RefinanceDebtParams calldata refinance
    )
        private
        returns (uint128 newDebt)
    {
        if (fromMarket == refinance.toMarket) revert InvalidRefinanceMarket(fromMarket, refinance.toMarket);
        _requireActiveMarket(refinance.toMarket);

        uint128 debtToRepay = _requireAmountInRange(refinance.debtToRepay, 1, user.debt[fromMarket], false);
        uint128 assetsToBorrow =
            _requireAmountInRange(refinance.assetsToBorrow, debtToRepay, type(uint128).max, false);

        (, newDebt) = __borrow(
            refinance.toMarket,
            assetsToBorrow,
            type(uint128).max,
            Direction.ExactOut,
            account,
            _getProtocolFee(refinance.toMarket),
            0,
            account
        );

        user.debt[refinance.toMarket] += newDebt;
        user.debt[fromMarket] -= debtToRepay;
        _markets[fromMarket].loanPool.balance += debtToRepay;
        if (assetsToBorrow > debtToRepay) _creditBalance(account, assetsToBorrow - debtToRepay);
    }

    function _moveRefinanceCollateral(
        User storage user,
        uint64 fromMarket,
        uint128 collateral,
        uint256 totalNewDebt,
        RefinanceDebtParams[] calldata refinances,
        RefinanceDebtResult[] memory results
    )
        private
    {
        uint256 collateralPerDebt = Math.mulDiv(
            collateral,
            UNIT,
            uint256(user.debt[fromMarket]) + totalNewDebt,
            Math.Rounding.Floor
        );
        uint128 remainingCollateralToMove = user.debt[fromMarket] == 0
            ? collateral
            : Math.mulDiv(collateralPerDebt, totalNewDebt, UNIT, Math.Rounding.Floor).toUint128();

        for (uint256 i = 0; i < refinances.length; i++) {
            uint128 collateralToMove = i == refinances.length - 1
                ? remainingCollateralToMove
                : Math.mulDiv(collateralPerDebt, results[i].newDebt, UNIT, Math.Rounding.Floor).toUint128();

            user.collateral[fromMarket] -= collateralToMove;
            user.collateral[refinances[i].toMarket] += collateralToMove;
            remainingCollateralToMove -= collateralToMove;
            results[i].collateralMoved = collateralToMove;
        }
    }

    function _requireHealthyRefinanceAndEmit(
        address account,
        uint64 fromMarket,
        RefinanceDebtParams calldata refinance,
        RefinanceDebtResult memory result,
        PriceCache memory priceCache
    )
        private
    {
        __requireHealthyDebt(refinance.toMarket, account, priceCache, 0, 0);
        emit DebtRefinanced(
            account,
            fromMarket,
            refinance.toMarket,
            refinance.debtToRepay,
            result.collateralMoved
        );
    }



    // ==============================================================
    // Reloan
    //
    // Converts owned loan exposure back into assets by matching against
    // live provide liquidity, with a preview path aligned to execution.
    // ==============================================================

    function _reloan(address account, uint64 market, uint128 amount, uint128 minAssets) internal {
        _syncAllPOrders(account, market);
        UserLoan storage loan = _users[account].loan[market];
        LoanPool storage pool = _markets[market].loanPool;

        amount = _requireAmountInRange(amount, MIN_AMOUNT, _previewRedeemLoanAssets(pool, loan.shares), true);
        _requireActiveMarket(market);

        uint256 loanSharesToTransfer = _loanSharesForAssets(pool, loan, amount);

        (uint128 assetsReceived,) = __borrow(
            market, minAssets, amount,
            Direction.ExactIn, account, _getProtocolFee(market), loanSharesToTransfer, account
        );

        loan.shares -= loanSharesToTransfer;
        __reconcileReloanOrder(account, market);
        _creditBalance(account, assetsReceived);
    }

    function _previewReloan(uint64 market, uint128 amount, address account)
        internal view
        returns (uint128 loanConsumed, uint128 assetsReceived)
    {
        (assetsReceived, loanConsumed) = __previewBorrow(market, 0, amount, Direction.ExactIn, account);
    }



    // ==============================================================
    // Debt Offset
    //
    // Burns owned loan exposure directly against outstanding debt in the
    // same market without going through asset withdrawal.
    // ==============================================================

    function _offset(address account, uint64 market, uint128 amount) internal {
        _syncAllPOrders(account, market);

        uint128 loan = __loanOf(market, account);
        uint128 debt = _users[account].debt[market];
        uint128 common = loan < debt ? loan : debt;

        amount = _requireAmountInRange(amount, 1, common, true);

        _burnLoanAssets(account, market, amount);
        _users[account].debt[market] -= amount;
        __reconcileReloanOrder(account, market);

        emit DebtOffsetWithLoan(account, market, amount);
    }



    // ==============================================================
    // Collateral
    //
    // Reads, deposits, and withdraws pledged collateral while enforcing
    // post-action solvency constraints for open debt positions.
    // ==============================================================

    function _collateralOf(uint64 market, address account) internal view returns (uint128) {
        return _users[account].collateral[market];
    }

    function _depositCollateral(address account, uint64 market, uint128 amount) internal {
        _requireAccount(account);
        _requireAmountInRange(amount, 1, type(uint128).max, false);

        _regUserMarket(account, market);

        _totalCollateral += amount;
        _collateral.safeTransferFrom(msg.sender, address(this), amount);
        _users[account].collateral[market] += amount;

        _requireCollateralCapNotExceeded();

        emit CollateralDeposited(account, market, amount);
    }

    function _moveCollateral(address account, uint64 fromMarket, uint64 toMarket, uint128 amount) internal {
        if (fromMarket == toMarket) revert InvalidCollateralMove(fromMarket, toMarket);

        User storage user = _users[account];
        amount = _requireAmountInRange(amount, 1, user.collateral[fromMarket], true);
        _regUserMarket(account, toMarket);

        user.collateral[fromMarket] -= amount;
        user.collateral[toMarket] += amount;

        PriceCache memory priceCache;
        _requireHealthyDebt(fromMarket, account, priceCache);
        _cleanupBOrders(user, account, fromMarket, priceCache);

        emit CollateralMoved(account, fromMarket, toMarket, amount);
    }

    function _withdrawCollateral(address account, uint64 market, address to, uint128 amount) internal {
        if (to == address(0)) revert InvalidTransferRecipient();

        User storage user = _users[account];
        amount = _requireAmountInRange(amount, 1, user.collateral[market], true);

        _totalCollateral -= amount;
        _collateral.safeTransfer(to, amount);
        user.collateral[market] -= amount;

        PriceCache memory priceCache;
        _requireHealthyDebt(market, account, priceCache);
        _cleanupBOrders(user, account, market, priceCache);

        emit CollateralWithdrawn(account, to, market, amount);
    }



    // ==============================================================
    // Liquidation / Risk Views
    //
    // Liquidates unhealthy positions and exposes the runtime risk state,
    // discount schedule, grace period, and fee parameters used by that
    // liquidation machinery.
    // ==============================================================

    struct LiquidateState {
        bool liquidatable;
        uint256 healthFactor;
        uint256 discount;
        uint128 badDebtAmount;

        uint128 userDebt;
        uint128 userCollateral;
    }

    function _liquidate(uint64 market, address borrower, uint128 debtAmount, uint256 minDiscountOut, uint256 deadline, bytes calldata data) internal {
        if (block.timestamp > deadline) revert LiquidationExpired(deadline);

        LiquidateState memory state;
        PriceCache memory priceCache;

        if (_users[borrower].debt[market] != 0) _cachePriceForMulticall();
        (state.liquidatable, state.healthFactor) = __isLiquidatable(market, borrower, priceCache);
        if (!state.liquidatable) revert NotLiquidatable();

        User storage user = _users[borrower];

        state.userDebt = user.debt[market];
        state.userCollateral = user.collateral[market];

        debtAmount = _requireAmountInRange(debtAmount, 1, state.userDebt, true);

        state.discount = Math.min(
            _getLiquidationDiscountMax(market),
            _getLiquidationDiscountMin(market) + UNIT - state.healthFactor.min(UNIT)
        );

        if (state.discount < minDiscountOut) revert LiquidationDiscountTooLow(state.discount, minDiscountOut);

        uint128 collateralToSeize;
        (collateralToSeize, debtAmount) = _collateralToSeize(
            state.userCollateral,
            debtAmount,
            state.discount,
            priceCache
        );

        if (collateralToSeize == 0) revert NoCollateralToSeize();

        // Value the remainder at the maximum discount so later liquidations can still recover the minimum.
        if (state.userDebt != debtAmount && collateralToSeize < state.userCollateral) {
            uint256 remainingCollateralValue = _price(priceCache).quoteSourceToTarget(state.userCollateral - collateralToSeize);
            uint256 remainingCollateralRecovery = Math.mulDiv(
                remainingCollateralValue, UNIT - _getLiquidationDiscountMax(market), UNIT, Math.Rounding.Floor
            );

            if (Math.min(state.userDebt - debtAmount, remainingCollateralRecovery) < _minDebtRemainingAfterLiquidation) {
                revert InsufficientLiquidationAmount(state.userDebt - debtAmount, remainingCollateralValue, _minDebtRemainingAfterLiquidation);
            }
        }

        _totalCollateral -= collateralToSeize;
        _collateral.safeTransfer(msg.sender, collateralToSeize);

        if (data.length > 0) {
            ILiquidator(msg.sender).liquidateCallback(debtAmount, collateralToSeize, data);
        }

        _asset.safeTransferFrom(msg.sender, address(this), debtAmount);

        state.userDebt -= debtAmount;
        state.userCollateral -= collateralToSeize;

        if (state.userCollateral == 0 && state.userDebt > 0) {
            state.badDebtAmount = state.userDebt;
            _socializeBadDebt(market, state.badDebtAmount);
            state.userDebt = 0;
        }

        _markets[market].loanPool.balance += debtAmount;
        user.debt[market] = state.userDebt;
        user.collateral[market] = state.userCollateral;

        emit Liquidated(msg.sender, borrower, market, debtAmount, collateralToSeize);

        if (state.badDebtAmount > 0) {
            emit BadDebtIncurred(borrower, market, state.badDebtAmount);
        }
    }

    function _collateralToSeize(
        uint128 userCollateral,
        uint128 debtAmount,
        uint256 discount,
        PriceCache memory priceCache
    ) private view returns (uint128, uint128) {
        if (userCollateral == 0) return (0, debtAmount);

        IPriceOracle.Price memory price = _price(priceCache);
        uint256 collateralValue = price.quoteSourceToTarget(userCollateral);
        // Round recovery down so exhausting collateral never reduces the liquidator's discount.
        uint256 maxDebtAmount = Math.mulDiv(collateralValue, UNIT - discount, UNIT, Math.Rounding.Floor);
        if (maxDebtAmount == 0) revert NoDebtToLiquidate();
        uint256 collateralToSeize = userCollateral;
        if (debtAmount <= collateralValue) {
            collateralToSeize = price.quoteTargetToSource(debtAmount);
            // Rounding both conversions up can add only a few raw collateral units at configured discounts.
            collateralToSeize = Math.mulDiv(collateralToSeize, UNIT, UNIT - discount, Math.Rounding.Ceil);
        }
        if (collateralToSeize >= userCollateral) {
            return (userCollateral, Math.min(debtAmount, maxDebtAmount).toUint128());
        }
        return (collateralToSeize.toUint128(), debtAmount);
    }

    function _isLiquidatable(uint64 market, address account) internal view returns (bool) {
        PriceCache memory priceCache;
        (bool liquidatable,) = __isLiquidatable(market, account, priceCache);
        return liquidatable;
    }

    // ==============================================================
    // Explore / Market Views
    //
    // Provides aggregated read models for market balances and both sides
    // of the orderbook, intended for offchain inspection and UI access.
    // ==============================================================

    function _getMarketLoan(uint64 market) internal view returns (uint128) {
        return _markets[market].loanPool.totalAssets;
    }

    function _getMarketBalance(uint64 market) internal view returns (uint128) {
        return _markets[market].loanPool.balance;
    }

    function _getProvideOrderbook(uint64 market) internal view returns (ProvideOrderbookTickView[] memory ticks) {
        POrderbook storage orderbook = _markets[market].porderbook;
        (uint256 index, uint64 underlyingPoolGeneration,) = _previewUnderlyingPoolState();

        uint256 ticksCount = (MAX_APR / APR_TICK_SPACING) + 1;
        ticks = new ProvideOrderbookTickView[](ticksCount);

        for (uint256 tickIndex = 0; tickIndex < ticksCount; tickIndex++) {
            uint256 APR = tickIndex * APR_TICK_SPACING;

            POrderbookTick storage tick = orderbook.tickByAPR[APR];
            POrderbookBucket storage bucket = orderbook.bucketById[_aprToBucketId(APR)];
            if (
                tick.bucketGeneration != bucket.bucketGeneration
                    || tick.underlyingPoolGeneration != underlyingPoolGeneration
                    || bucket.underlyingPoolGeneration != underlyingPoolGeneration
            ) continue;

            ticks[tickIndex].amount = _previewIndexedAmount(tick.assets, tick.indexSnapshot, index).toUint128();
        }
    }

    function _getBorrowOrderbook(uint64 market) internal view returns (BorrowOrderbookTickView[] memory ticks) {
        BOrderbook storage orderbook = _markets[market].borderbook;
        uint256 debtDuration = _debtDuration(market);

        uint256 ticksCount = (MAX_APR / APR_TICK_SPACING) + 1;
        ticks = new BorrowOrderbookTickView[](ticksCount);

        for (uint256 tickIndex = 0; tickIndex < ticksCount; tickIndex++) {
            uint256 APR = tickIndex * APR_TICK_SPACING;

            BOrderbookTick storage tick = orderbook.tickByAPR[APR];

            ticks[tickIndex].amount = tick.totalBorrowAmount + _minimumAssetsForDebt(tick.totalReloanAmount, APR, debtDuration);
            ticks[tickIndex].count = tick.borrowers.length;
        }
    }



    // ==============================================================
    // Config / Validation Helpers
    //
    // Local validators and config fanout used while initializing the
    // pool or mutating owner-controlled parameters.
    // ==============================================================

    function _checkProtocolFee(uint256 fee) private pure {
        if (fee >= UNIT) revert InvalidProtocolFee();
    }

    function _checkBorrowOrderMinAmount(uint128 amount) private pure {
        if (amount == 0) revert InvalidBorrowOrderMinAmount();
    }

    function _checkProvideOrderMinAmount(uint128 amount) private pure {
        if (amount == 0) revert InvalidProvideOrderMinAmount();
    }

    function _cacheActiveMarketsConfig() private {
        uint64[] memory activeMarkets = _marketsConfig.getActiveMarkets(uint64(block.timestamp));

        for (uint256 i = 0; i < activeMarkets.length; i++) {
            _cacheMarketsConfig(activeMarkets[i]);
        }

        uint64 gracePeriodMarket = _getGracePeriodMarketForCache();
        if (gracePeriodMarket != 0) {
            _cacheMarketsConfig(gracePeriodMarket);
        }
    }

    function _getGracePeriodMarketForCache() private view returns (uint64 market) {
        uint64 now_ = uint64(block.timestamp);
        if (_liquidationGracePeriod == 0 || now_ <= _marketsConfig.start) return 0;

        uint64 marketStep = _marketsConfig.durations[0];
        uint64 finalizedMarkets = (now_ - _marketsConfig.start) / marketStep;
        if (finalizedMarkets == 0) return 0;

        market = _marketsConfig.start + finalizedMarkets * marketStep;
        if (now_ >= market + _liquidationGracePeriod) return 0;
    }

    function _cacheMarketsConfig(uint64 market) private {
        Market storage m = _markets[market];
        if (m.cachedConfig.initialized) return;

        m.cachedConfig = MarketCachedConfig({
            initialized: true,

            liquidationGracePeriod: _liquidationGracePeriod,
            liquidationDiscountMax: _liquidationDiscountMax,
            liquidationDiscountMin: _liquidationDiscountMin,

            protocolFee: _protocolFee
        });
    }

    function _checkLiquidationDiscountMin(uint256 newMin) private view {
        uint256 max = _liquidationDiscountMax;

        if (newMin > max) revert InvalidLiquidationDiscountMin(0, max, newMin);
    }

    function _checkLiquidationDiscountMax(uint256 newMax) private view {
        uint256 max = (UNIT - _liquidationLTV) * 4 / 10;

        if (newMax < _liquidationDiscountMin) revert InvalidLiquidationDiscountMax(_liquidationDiscountMin, max, newMax);
        if (newMax > max) revert InvalidLiquidationDiscountMax(_liquidationDiscountMin, max, newMax);
    }

    function _checkLiquidationGracePeriod(uint64 gracePeriod) private view {
        uint64 max = _marketsConfig.durations[0] - 1;
        if (gracePeriod > max) revert InvalidLiquidationGracePeriod(0, max, gracePeriod);
    }

    function _emitAdminConfigUpdated(string memory key, uint256 oldValue, uint256 newValue) private {
        emit AdminConfigUpdated(msg.sender, key, oldValue, newValue);
    }



    // ==============================================================
    // Underlying Pool Helpers
    //
    // State-changing adapter calls run in the CreditPool context so the
    // external position remains owned by this pool.
    // ==============================================================

    function _underlyingPoolAssets() private view returns (uint256) {
        return _underlyingPoolAdapter.totalAssets(address(this), _underlyingPoolConfig);
    }

    function _depositUnderlyingPool(uint128 amount) private returns (uint256 assetsAfter) {
        return _delegateUnderlyingPool(
            abi.encodeCall(
                IUnderlyingPool.deposit,
                (address(_asset), _underlyingPoolConfig, uint256(amount))
            )
        );
    }

    function _withdrawUnderlyingPoolTo(address to, uint128 amount) private returns (uint256 assetsAfter) {
        return _delegateUnderlyingPool(
            abi.encodeCall(
                IUnderlyingPool.withdraw,
                (address(_asset), _underlyingPoolConfig, uint256(amount), to)
            )
        );
    }

    function _delegateUnderlyingPool(bytes memory data) private returns (uint256 result) {
        address adapter = address(_underlyingPoolAdapter);
        (bool success, bytes memory returnData) = adapter.delegatecall(data);
        if (!success) {
            if (returnData.length == 0) revert UnderlyingPoolCallFailed(adapter);
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        if (returnData.length != 32) revert UnderlyingPoolCallFailed(adapter);
        return abi.decode(returnData, (uint256));
    }



    // ==============================================================
    // Loan / Borrow View Helpers
    //
    // Computes realized lender loan value and the currently executable
    // borrow-order balance without mutating user or market state.
    // ==============================================================

    function __loanOf(uint64 market, address account) private view returns (uint128 loan) {
        LoanPool storage loanPool = _markets[market].loanPool;
        return _previewRedeemLoanAssets(loanPool, _users[account].loan[market].shares);
    }

    function _getBorrowOrderBalance(uint64 market, uint256 APR, address account) internal view returns (uint128 balance) {
        UserBOrdersByMarket storage borderByMarket = _users[account].borders;
        if (!borderByMarket.markets.has(market)) return 0;

        UserBOrdersByAPR storage borderByAPR = borderByMarket.byMarket[market];
        if (!borderByAPR.aprs.has(APR)) return 0;

        BOrderbookTick storage tick = _markets[market].borderbook.tickByAPR[APR];
        if (_isBOrderInactive(tick, borderByAPR.byAPR[APR])) return 0;

        UserBOrder storage order = borderByAPR.byAPR[APR];
        if (order.orderType == BOrderType.Reloan) {
            if (block.timestamp >= market) return 0;

            uint128 loan = __loanOf(market, account);
            return order.amount < loan ? order.amount : loan;
        }

        return order.amount;
    }



    // ==============================================================
    // Borrow Matching Helpers
    //
    // Walks buckets and ticks to fulfill borrow demand against provide
    // liquidity and to preview the same execution path offchain.
    // ==============================================================

    function __borrow(
        uint64 market,
        uint128 assetsAmount,
        uint128 debtAmount,
        Direction direction,
        address borrower,
        uint256 protocolFee,
        uint256 loanShares,
        address eventAccount
    )
        private
        returns (uint128 assets, uint128 debt)
    {
        _requireAmountInRange(direction == Direction.ExactOut ? assetsAmount : debtAmount, MIN_AMOUNT, type(uint128).max, false);
        _regUserMarket(borrower, market);

        uint256 underlyingPoolAssetsBefore = _syncUnderlyingPoolIndex();

        BorrowState memory state = BorrowState({
            direction: direction,
            market: market,
            debtDuration: _debtDuration(market),
            protocolFee: protocolFee,
            feeShares: 0,
            remaining: direction == Direction.ExactOut ? assetsAmount : debtAmount,
            assets: 0,
            debt: 0,
            loanSharesRemaining: loanShares,
            endAPR: 0
        });

        uint256[] memory APRs = _disableAllPOrders(borrower, market);

        uint256 bucketId;
        for (bucketId = 0; bucketId < RIGHTMOST_BUCKET_ID && state.remaining > 0; bucketId += 1) {
            if (_borrowFromBucket(bucketId, state)) break;
        }

        for (uint256 tickId = _bucketIdToAPR(bucketId); tickId <= MAX_APR && state.remaining > 0; tickId += APR_TICK_SPACING) {
            _borrowFromTick(tickId, state);
        }

        _enableAllPOrders(borrower, market, APRs);

        debt = state.debt;
        assets = state.assets;

        if (direction == Direction.ExactOut) {
            if (state.remaining != 0) revert BorrowAssetsNotReached(assetsAmount, assets);
            if (debt > debtAmount) revert BorrowDebtExceeded(debt, debtAmount);
        } else {
            if (state.remaining != 0) revert BorrowDebtNotReached(debtAmount, debt);
            if (assets < assetsAmount) revert BorrowAssetsNotReached(assetsAmount, assets);
        }

        if (state.feeShares != 0) {
            _regUserMarket(owner, state.market);
            _creditLoanShares(owner, state.market, state.feeShares);
        }

        if (direction == Direction.ExactOut) {
            emit Borrowed(eventAccount, market, assets, debt, state.endAPR);
        } else {
            emit Reloaned(eventAccount, market, debtAmount, assets, loanShares, state.endAPR);
        }

        uint256 underlyingPoolAssetsAfter = _withdrawUnderlyingPoolTo(address(this), state.assets);
        _reconcileUnderlyingPoolWithdrawal(
            underlyingPoolAssetsBefore,
            state.assets,
            underlyingPoolAssetsAfter
        );
    }

    function _previewBorrow(uint64 market, uint128 amount, address borrower)
        internal view
        returns (uint128 borrowed, uint128 debt)
    {
        return __previewBorrow(market, amount, type(uint128).max, Direction.ExactOut, borrower);
    }

    function __previewBorrow(uint64 market, uint128 assetsAmount, uint128 debtAmount, Direction direction, address borrower)
        private view
        returns (uint128 assets, uint128 debt)
    {
        if (direction == Direction.ExactIn) {
            _requireAmountInRange(debtAmount, MIN_AMOUNT, type(uint128).max, false);
            _requireActiveMarket(market);
        } else {
            _requireActiveMarket(market);
            _requireAmountInRange(assetsAmount, MIN_AMOUNT, type(uint128).max, false);
        }

        (uint256 index, uint64 underlyingPoolGeneration, uint256 underlyingPoolAssets) =
            _previewUnderlyingPoolState();

        BorrowState memory state = BorrowState({
            direction: direction,
            market: market,
            debtDuration: _debtDuration(market),
            protocolFee: 0,
            feeShares: 0,
            remaining: direction == Direction.ExactOut ? assetsAmount : debtAmount,
            assets: 0,
            debt: 0,
            loanSharesRemaining: 0,
            endAPR: 0
        });

        uint256 bucketId;
        for (bucketId = 0; bucketId < RIGHTMOST_BUCKET_ID && state.remaining > 0; bucketId += 1) {
            if (_previewBorrowFromBucket(borrower, bucketId, state, index, underlyingPoolGeneration)) break;
        }

        for (uint256 tickId = _bucketIdToAPR(bucketId); tickId <= MAX_APR && state.remaining > 0; tickId += APR_TICK_SPACING) {
            _previewBorrowFromTick(borrower, tickId, state, index, underlyingPoolGeneration);
        }

        assets = state.assets;
        debt = state.debt;

        if (direction == Direction.ExactIn && underlyingPoolAssets < assets) {
            revert InsufficientUnderlyingPoolBalance(
                address(_underlyingPoolAdapter),
                underlyingPoolAssets,
                assets
            );
        }
    }

    function _borrowFromBucket(uint256 bucketId, BorrowState memory state) private returns (bool fail) {
        POrderbookBucket storage bucket = _syncPOrderbookBucket(state.market, bucketId);

        uint128 assets = bucket.assets;
        uint128 debt = _debtForBucket(bucket.assets, bucket.assetsTimesAPR, state.debtDuration);

        if (state.direction == Direction.ExactOut) {
            if (assets == 0) return false;
            if (assets > state.remaining) return true;
        } else {
            if (debt == 0) return false;
            if (debt > state.remaining) return true;
        }

        uint256 matchedLoanShares = _matchedLoanShares(state, assets, debt);
        state.remaining -= state.direction == Direction.ExactOut ? assets : debt;
        state.assets += assets;
        state.debt += debt;

        state.endAPR = _bucketIdToAPR(bucketId + 1) - APR_TICK_SPACING;
        _consumeBucket(bucket, matchedLoanShares, state.debtDuration * (UNIT - state.protocolFee));
        return false;
    }

    function _borrowFromTick(uint256 tickAPR, BorrowState memory state) private {
        POrderbook storage orderbook = _markets[state.market].porderbook;
        POrderbookTick storage tick = _syncPOrderbookTick(state.market, tickAPR);
        POrderbookBucket storage bucket = orderbook.bucketById[_aprToBucketId(tickAPR)];

        uint128 assets;
        uint128 debt;

        if (state.direction == Direction.ExactOut) {
            assets = state.remaining < tick.assets ? state.remaining : tick.assets;
            if (assets == 0) return;
            debt = _debtFor(assets, tickAPR, state.debtDuration, Math.Rounding.Ceil);
        } else {
            uint128 availableDebt = _debtFor(tick.assets, tickAPR, state.debtDuration, Math.Rounding.Ceil);
            debt = state.remaining < availableDebt ? state.remaining : availableDebt;
            if (debt == 0) return;

            assets = debt == availableDebt
                ? tick.assets
                : _minimumAssetsForDebt(debt, tickAPR, state.debtDuration);
        }

        uint256 loanShares = _matchedLoanShares(state, assets, debt);
        state.remaining -= state.direction == Direction.ExactOut ? assets : debt;
        state.assets += assets;
        state.debt += debt;

        state.endAPR = tickAPR;
        _consumeTick(tick, bucket, tickAPR, assets, loanShares);
    }

    function _previewBorrowFromBucket(
        address borrower,
        uint256 bucketId,
        BorrowState memory state,
        uint256 index,
        uint64 underlyingPoolGeneration
    )
        private view
        returns (bool fail)
    {
        (uint128 bucketAssets, uint256 bucketAssetsTimesAPR) =
            _previewAvailableBucketLiquidity(
                state.market,
                borrower,
                bucketId,
                index,
                underlyingPoolGeneration
            );

        uint128 bucketDebt = _debtForBucket(bucketAssets, bucketAssetsTimesAPR, state.debtDuration);

        if (state.direction == Direction.ExactOut) {
            if (bucketAssets == 0) return false;
            if (bucketAssets > state.remaining) return true;

            state.remaining -= bucketAssets;
        } else {
            if (bucketDebt == 0) return false;
            if (bucketDebt > state.remaining) return true;

            state.remaining -= bucketDebt;
        }

        state.assets += bucketAssets;
        state.debt += bucketDebt;

        return false;
    }

    function _previewBorrowFromTick(
        address borrower,
        uint256 tickAPR,
        BorrowState memory state,
        uint256 index,
        uint64 underlyingPoolGeneration
    ) private view {
        uint128 tickAssets = _previewAvailableTickLiquidity(
            state.market,
            borrower,
            tickAPR,
            index,
            underlyingPoolGeneration
        );
        uint128 assets;
        uint128 debt;

        if (state.direction == Direction.ExactOut) {
            assets = state.remaining < tickAssets ? state.remaining : tickAssets;
            if (assets == 0) return;
            debt = _debtFor(assets, tickAPR, state.debtDuration, Math.Rounding.Ceil);

            state.remaining -= assets;
        } else {
            uint128 availableDebt = _debtFor(tickAssets, tickAPR, state.debtDuration, Math.Rounding.Ceil);
            debt = state.remaining < availableDebt ? state.remaining : availableDebt;
            if (debt == 0) return;

            assets = debt == availableDebt
                ? tickAssets
                : _minimumAssetsForDebt(debt, tickAPR, state.debtDuration);

            state.remaining -= debt;
        }

        state.assets += assets;
        state.debt += debt;
    }

    function _matchedLoanShares(BorrowState memory state, uint128 assets, uint128 debt) private returns (uint256 lenderShares) {
        uint256 grossShares;
        if (state.direction == Direction.ExactOut) {
            grossShares = _mintLoanShares(state.market, debt);
        } else {
            grossShares = debt == state.remaining
                ? state.loanSharesRemaining
                : Math.mulDiv(state.loanSharesRemaining, debt, state.remaining);

            state.loanSharesRemaining -= grossShares;
        }

        uint128 feeAssets = _protocolFeeAssets(assets, debt, state.protocolFee);
        uint256 feeShares = Math.mulDiv(grossShares, feeAssets, debt);

        state.feeShares += feeShares;
        lenderShares = grossShares - feeShares;
    }

    function _previewAvailableBucketLiquidity(
        uint64 market,
        address account,
        uint256 bucketId,
        uint256 index,
        uint64 underlyingPoolGeneration
    )
        private view
        returns (uint128 assets, uint256 assetsTimesAPR)
    {
        (assets, assetsTimesAPR) = _previewPOrderbookBucketAmounts(
            _markets[market].porderbook, bucketId, index, underlyingPoolGeneration
        );

        uint256[] memory aprs = _users[account].porders.byMarket[market].aprs.keys;
        for (uint256 i = 0; i < aprs.length; i++) {
            uint256 APR = aprs[i];
            if (_aprToBucketId(APR) != bucketId) continue;

            uint128 ownAssets = _previewOwnPOrderLiquidity(
                account,
                market,
                APR,
                index,
                underlyingPoolGeneration
            );
            assets -= ownAssets;
            assetsTimesAPR -= ownAssets * APR;
        }
    }

    function _previewAvailableTickLiquidity(
        uint64 market,
        address account,
        uint256 tickAPR,
        uint256 index,
        uint64 underlyingPoolGeneration
    )
        private view
        returns (uint128 assets)
    {
        POrderbook storage orderbook = _markets[market].porderbook;
        POrderbookTick storage tick = orderbook.tickByAPR[tickAPR];
        POrderbookBucket storage bucket = orderbook.bucketById[_aprToBucketId(tickAPR)];

        if (
            tick.bucketGeneration != bucket.bucketGeneration
                || tick.underlyingPoolGeneration != underlyingPoolGeneration
                || bucket.underlyingPoolGeneration != underlyingPoolGeneration
        ) return 0;

        assets = _previewIndexedAmount(tick.assets, tick.indexSnapshot, index).toUint128();
        if (assets == 0) return 0;

        return assets - _previewOwnPOrderLiquidity(
            account,
            market,
            tickAPR,
            index,
            underlyingPoolGeneration
        );
    }

    function _previewOwnPOrderLiquidity(
        address account,
        uint64 market,
        uint256 APR,
        uint256 index,
        uint64 underlyingPoolGeneration
    )
        private view
        returns (uint128)
    {
        POrderbook storage orderbook = _markets[market].porderbook;
        UserPOrder storage order = _users[account].porders.byMarket[market].byAPR[APR];
        POrderbookTick storage tick = orderbook.tickByAPR[APR];
        POrderbookBucket storage bucket = orderbook.bucketById[_aprToBucketId(APR)];

        return _porderBalance(order, tick, bucket, index, underlyingPoolGeneration);
    }

    function _sweep(address account, uint64 market, uint128 amount, uint16 maxCrossedOrders) internal {
        _requireAccount(account);
        _requireActiveMarket(market);
        _requireAmountInRange(amount, MIN_AMOUNT, type(uint128).max, false);

        uint256 protocolFee = _getProtocolFee(market);
        // address(0) allows matching the sweeper's and owner's orders.
        (, uint128 debt) = __borrow(
            market, amount, type(uint128).max,
            Direction.ExactOut, address(0), protocolFee, 0, account
        );

        uint128 spread;
        {
            (uint128 collectedLoan, uint128 consumedAssets,, uint16 crossedOrders, ProvideOrderChanges memory changes) = _provide(
                address(0), market, amount, debt,
                Direction.ExactOut, maxCrossedOrders,
                0
            );
            _emitProvided(account, market, consumedAssets, collectedLoan, changes);
            assert(collectedLoan == debt);

            spread = amount - consumedAssets;
            maxCrossedOrders -= crossedOrders;
        }
        if (spread == 0) {
            emit Swept(account, market, amount, 0);
            return;
        }

        if (protocolFee != 0) {
            // (1 - v) * K + v * Y = v * spread, with v = fD / ((1 - f)A + fD).
            uint256 virtualFee = Math.mulDiv(
                protocolFee * debt, UNIT,
                (UNIT - protocolFee) * amount + protocolFee * debt,
                Math.Rounding.Floor
            );
            // Round the target up so a positive fee and spread cannot silently skip this leg.
            uint128 targetLoan = Math.mulDiv(spread, virtualFee, UNIT, Math.Rounding.Ceil).toUint128();
            (uint128 collectedLoan, uint128 consumedAssets, uint128 fee,, ProvideOrderChanges memory changes) = _provide(
                address(0), market, spread, targetLoan,
                Direction.ExactOut, maxCrossedOrders,
                virtualFee
            );
            _emitProvided(account, market, consumedAssets, collectedLoan, changes);
            _regUserMarket(owner, market);
            _creditLoan(owner, market, collectedLoan + fee);
            spread -= consumedAssets;
        }

        if (spread != 0) _creditBalance(account, spread);
        emit Swept(account, market, amount, spread);
    }



    // ==============================================================
    // Risk / Liquidation Helpers
    //
    // Evaluates health, derives liquidation parameters, cleans up stale
    // borrow-side demand, and socializes bad debt into loan accounting.
    // ==============================================================

    function __reconcileReloanOrder(address account, uint64 market) private {
        UserBOrdersByMarket storage borderByMarket = _users[account].borders;
        if (!borderByMarket.markets.has(market)) return;

        UserBOrdersByAPR storage borderByAPR = borderByMarket.byMarket[market];
        uint256 APR = borderByAPR.reloanAPR;
        if (APR == NO_RELOAN_APR) return;

        _syncBOrder(account, market, APR);

        if (!borderByMarket.markets.has(market) || borderByAPR.reloanAPR != APR) return;

        UserBOrder storage order = borderByAPR.byAPR[APR];
        uint128 oldAmount = order.amount;
        uint128 newAmount;

        if (block.timestamp < market) {
            uint128 loan = __loanOf(market, account);
            newAmount = oldAmount < loan ? oldAmount : loan;

            if (newAmount == oldAmount) return;

            if (_minimumAssetsForDebt(newAmount, APR, _debtDuration(market)) < _borrowOrderMinAmount) {
                newAmount = 0;
            }
        }

        BOrderbook storage borderbook = _markets[market].borderbook;
        BOrderbookTick storage tick = borderbook.tickByAPR[APR];
        tick.totalReloanAmount -= oldAmount - newAmount;
        order.amount = newAmount;

        if (newAmount == 0) {
            _deleteBOrderIfEmpty(account, market, APR);
            if (tick.borrowers.head == 0) borderbook.aprs.remove(APR);
        }

        _emitReloanReconciliation(account, market, APR, oldAmount, newAmount);
    }

    function _emitReloanReconciliation(address account, uint64 market, uint256 APR, uint128 oldAmount, uint128 newAmount) private {
        emit ReloanOrderCancelled(account, market, APR, oldAmount - newAmount, true);
    }

    function _cleanupBOrders(
        User storage user,
        address borrower,
        uint64 market,
        PriceCache memory priceCache
    ) private {
        _syncAllBOrders(borrower, market);
        _cleanupBorrowOrders(user, borrower, market, priceCache);
    }

    function _cleanupBorrowOrders(
        User storage user,
        address borrower,
        uint64 market,
        PriceCache memory priceCache
    ) private {
        UserBOrdersByAPR storage borderByAPR = user.borders.byMarket[market];
        BOrderbook storage borderbook = _markets[market].borderbook;
        uint256[] memory APRs = borderByAPR.aprs.keys;
        uint256 duration = _debtDuration(market);

        for (uint256 i = 0; i < APRs.length; i++) {
            uint256 APR = APRs[i];
            BOrderbookTick storage tick = borderbook.tickByAPR[APR];
            UserBOrder storage border = borderByAPR.byAPR[APR];

            if (border.orderType != BOrderType.Borrow) continue;

            uint128 maxOrderDebt = _debtFor(border.amount, APR, duration, Math.Rounding.Ceil);
            _cachePriceForMulticall();
            uint256 hf = __getHealthFactor(market, borrower, priceCache, maxOrderDebt, 0, _borrowLTV);
            if (hf >= UNIT) continue;

            emit BorrowOrderCancelled(borrower, market, APR, border.amount, true);
            tick.totalBorrowAmount = border.amount > tick.totalBorrowAmount ? 0 : tick.totalBorrowAmount - border.amount;
            border.amount = 0;
            _deleteBOrderIfEmpty(borrower, market, APR);

            if (tick.borrowers.head == 0) {
                borderbook.aprs.remove(APR);
            }
        }
    }

    function _getHealthFactor(uint64 market, address account) internal view returns (uint256) {
        PriceCache memory priceCache;
        return __getHealthFactor(market, account, priceCache, 0, 0, _liquidationLTV);
    }

    function __getHealthFactor(
        uint64 market,
        address account,
        PriceCache memory priceCache,
        uint128 debtIncrease,
        uint128 collateralDecrease,
        uint256 ltv
    )
        private view
        returns (uint256)
    {
        User storage user = _users[account];
        uint128 collateral_ = user.collateral[market] - collateralDecrease;
        uint128 debt = user.debt[market] + debtIncrease;

        return _calculateHealthFactor(priceCache, debt, collateral_, ltv);
    }

    function _calculateHealthFactor(PriceCache memory priceCache, uint128 debt, uint128 collateral_, uint256 ltv)
        private view
        returns (uint256)
    {
        if (debt == 0) return UNIT;
        if (collateral_ == 0) return 0;

        uint256 collateralValue = _price(priceCache).quoteSourceToTarget(collateral_);
        return ltv.mulDiv(collateralValue, debt);
    }

    function __isLiquidatable(uint64 market, address account, PriceCache memory priceCache)
        internal view
        returns (bool, uint256 healthFactor)
    {
        uint256 userDebt = _users[account].debt[market];
        if (userDebt == 0) return (false, 0);

        healthFactor = __getHealthFactor(market, account, priceCache, 0, 0, _liquidationLTV);
        if (healthFactor < UNIT) return (true, healthFactor);

        uint256 liquidatableAfter = uint256(market) + _getLiquidationGracePeriod(market);
        if (block.timestamp >= liquidatableAfter) return (true, healthFactor);

        return (false, healthFactor);
    }

    function _getLiquidationGracePeriod(uint64 market) internal view returns (uint64) {
        Market storage m = _markets[market];
        if (m.cachedConfig.initialized) {
            return m.cachedConfig.liquidationGracePeriod;
        } else {
            return _liquidationGracePeriod;
        }
    }

    function _getLiquidationDiscountMin(uint64 market) internal view returns (uint256) {
        Market storage m = _markets[market];
        if (m.cachedConfig.initialized) {
            return m.cachedConfig.liquidationDiscountMin;
        } else {
            return _liquidationDiscountMin;
        }
    }

    function _getLiquidationDiscountMax(uint64 market) internal view returns (uint256) {
        Market storage m = _markets[market];
        if (m.cachedConfig.initialized) {
            return m.cachedConfig.liquidationDiscountMax;
        } else {
            return _liquidationDiscountMax;
        }
    }

    function _getProtocolFee(uint64 market) internal view returns (uint256) {
        Market storage m = _markets[market];
        if (m.cachedConfig.initialized) {
            return m.cachedConfig.protocolFee;
        } else {
            return _protocolFee;
        }
    }

    function _socializeBadDebt(uint64 market, uint128 badDebtAmount) internal {
        LoanPool storage pool = _markets[market].loanPool;

        // Let D be the borrower's debt before liquidation, R >= 1 the repaid amount and B = D - R
        // the bad debt. Since totalAssets = balance + sum(debts), totalAssets >= D. Therefore,
        // totalAssets - B >= D - (D - R) = R >= 1, so a production bad-debt write-down cannot
        // consume the final loan asset. Equality can only result from an internal accounting error.
        assert(pool.totalAssets > badDebtAmount);
        pool.totalAssets -= badDebtAmount;
    }

    // ==============================================================
    // Provide Explorer Helpers
    //
    // Enumerates lender order identifiers in a compact form for UI and
    // indexer consumers that need the full provide-order surface.
    // ==============================================================

    function _getUserMarkets(address account, uint256 start, uint256 limit) internal view returns (uint64[] memory markets) {
        uint64[] storage userMarkets = _users[account].markets.keys;
        uint256 count = userMarkets.length;

        if (limit == 0 || start >= count) {
            return new uint64[](0);
        }

        uint256 size = (count - start).min(limit);
        markets = new uint64[](size);

        for (uint256 i = 0; i < size; i++) {
            markets[i] = userMarkets[start + i];
        }
    }

    function _getMarketUsers(uint64 market, uint256 start, uint256 limit)
        internal view
        returns (address[] memory users)
    {
        address[] storage accounts = _markets[market].users.accounts;
        uint256 count = accounts.length;

        if (limit == 0 || start >= count) {
            return new address[](0);
        }

        uint256 size = (count - start).min(limit);
        users = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            users[i] = accounts[start + i];
        }
    }

    function _getAllProvideOrders(uint64 market, address account)
        internal view
        returns (ProvideOrderView[] memory orders)
    {
        uint256[] storage APRs = _users[account].porders.byMarket[market].aprs.keys;
        uint256 count = APRs.length;
        orders = new ProvideOrderView[](count);
        uint256 empty = 0;
        (uint256 index, uint64 underlyingPoolGeneration,) = _previewUnderlyingPoolState();
        POrderbook storage orderbook = _markets[market].porderbook;

        for (uint256 i = 0; i < count; i++) {
            uint256 APR = APRs[i];
            UserPOrder storage order = _users[account].porders.byMarket[market].byAPR[APR];
            POrderbookTick storage tick = orderbook.tickByAPR[APR];
            POrderbookBucket storage bucket = orderbook.bucketById[_aprToBucketId(APR)];
            uint128 balance = _porderBalance(
                order,
                tick,
                bucket,
                index,
                underlyingPoolGeneration
            );
            if (balance == 0) {
                empty += 1;
                continue;
            }

            orders[i - empty] = ProvideOrderView({
                APR: APR,
                amount: balance
            });
        }

        // trim empty orders
        assembly ("memory-safe") { mstore(orders, sub(mload(orders), empty)) }
    }

    function _getAllBorrowOrders(uint64 market, address account)
        internal view
        returns (BorrowOrderView[] memory orders)
    {
        uint256[] storage APRs = _users[account].borders.byMarket[market].aprs.keys;
        uint256 count = APRs.length;
        orders = new BorrowOrderView[](count);
        uint256 empty = 0;

        for (uint256 i = 0; i < count; i++) {
            uint256 APR = APRs[i];

            uint128 balance = _getBorrowOrderBalance(market, APR, account);
            if (balance == 0) {
                empty += 1;
                continue;
            }

            orders[i - empty] = BorrowOrderView({
                APR: APR,
                amount: balance,
                orderType: _users[account].borders.byMarket[market].byAPR[APR].orderType
            });
        }

        // trim empty orders
        assembly ("memory-safe") { mstore(orders, sub(mload(orders), empty)) }
    }



    // ==============================================================
    // Runtime Validation Helpers
    //
    // Shared require-style guards used across execution paths for market
    // liveness, bounds checking, solvency, and pool inventory safety.
    // ==============================================================

    function _requireActiveMarket(uint64 market) private view {
        if (!_marketsConfig.isMarketActive(uint64(block.timestamp), market)) revert InactiveMarket(market);
    }

    function _requireFinalizedMarket(uint64 market) private view {
        if (!_marketsConfig.isMarketFinalized(uint64(block.timestamp), market)) revert ActiveMarket(market);
    }

    function _requireAmountInRange(uint128 amount, uint128 minAmount, uint128 maxAmount, bool maxValueOnMax) private pure returns (uint128) {
        if (amount == type(uint128).max && maxValueOnMax) amount = maxAmount;
        if (amount < minAmount || amount > maxAmount) revert AmountIsOutOfRange(amount, minAmount, maxAmount);
        return amount;
    }

    function _requireValidAPR(uint256 APR) private pure {
        if (APR % APR_TICK_SPACING != 0 || APR > MAX_APR) revert InvalidAPR(APR, APR_TICK_SPACING, MAX_APR);
    }

    function _requireMaxPOrders(address account, uint64 market) private view {
        SetUint256 storage porders = _users[account].porders.byMarket[market].aprs;
        uint256 active = porders.count();
        if (active > _maxActiveProvideOrders) revert TooManyProvideOrders(_maxActiveProvideOrders);
    }

    function _requireMaxBOrders(address account, uint64 market) private view {
        SetUint256 storage borders = _users[account].borders.byMarket[market].aprs;
        uint256 active = borders.count();
        if (active > _maxActiveBorrowOrders) revert TooManyBorrowOrders(_maxActiveBorrowOrders);
    }

    function _requirePoolBalance(IERC20 token, uint128 amount) private view {
        uint256 poolBalance = token.balanceOf(address(this));
        if (poolBalance < amount) revert InsufficientPoolBalance(address(token), poolBalance, amount);
    }

    function _requireHealthyDebt(uint64 market, address account, PriceCache memory priceCache) private {
        // allow to withdraw collateral even oracle price is stale
        if (_users[account].debt[market] == 0) return;

        _cachePriceForMulticall();
        uint256 hf = __getHealthFactor(market, account, priceCache, 0, 0, _borrowLTV);
        if (hf < UNIT) revert UnhealthyDebt(hf);
    }

    function __requireHealthyDebt(
        uint64 market,
        address account,
        PriceCache memory priceCache,
        uint128 debtIncrease,
        uint128 collateralDecrease
    ) private {
        if (_users[account].debt[market] == 0 && debtIncrease == 0) return;

        _cachePriceForMulticall();
        uint256 hf = __getHealthFactor(market, account, priceCache, debtIncrease, collateralDecrease, _borrowLTV);
        if (hf < UNIT) revert UnhealthyDebt(hf);
    }

    function _requireMarketLoanAvailable(uint64 market, uint128 amount) private view {
        uint128 loanAvailable = _markets[market].loanPool.balance;
        if (loanAvailable < amount) revert InsufficientMarketLoanAvailable(loanAvailable, amount);
    }

    function _isBOrderInactive(BOrderbookTick storage tick, UserBOrder storage order) private view returns (bool) {
        return order.queueNodeId == 0 || tick.borrowers.head == 0 || tick.borrowers.head > order.queueNodeId;
    }

    function _requireCollateralCapNotExceeded() private view {
        uint128 balance = _totalCollateral;
        uint128 cap = _totalCollateralCap;
        if (balance > cap) revert CollateralCapExceeded(balance, cap);
    }



    // ==============================================================
    // Loan Accounting Helpers
    //
    // Mints, burns, synchronizes, and previews loan shares so lender
    // ownership and redeemable assets stay internally consistent.
    // ==============================================================

    function _previewMintLoanShares(LoanPool storage pool, uint128 assets) private view returns (uint256) {
        if (assets == 0) return 0;
        if (pool.totalShares == 0 || pool.totalAssets == 0) return assets * SCALE;
        return Math.mulDiv(pool.totalShares, assets, pool.totalAssets, Math.Rounding.Ceil);
    }

    function _previewRedeemLoanAssets(LoanPool storage pool, uint256 shares) private view returns (uint128) {
        return _previewRedeemLoanAssets(pool.totalAssets, pool.totalShares, shares);
    }

    function _previewRedeemLoanAssets(uint128 totalAssets, uint256 totalShares, uint256 shares) private pure returns (uint128) {
        if (shares == 0 || totalShares == 0 || totalAssets == 0) return 0;
        return Math.mulDiv(shares, totalAssets, totalShares).toUint128();
    }

    function _mintLoanShares(uint64 market, uint128 assets) private returns (uint256 loanShares) {
        LoanPool storage pool = _markets[market].loanPool;

        loanShares = _previewMintLoanShares(pool, assets);
        pool.totalAssets += assets;
        pool.totalShares += loanShares;
    }

    function _creditLoan(address account, uint64 market, uint128 assets) private returns (uint256 loanShares) {
        loanShares = _mintLoanShares(market, assets);
        _creditLoanShares(account, market, loanShares);
    }

    function _creditLoanShares(address account, uint64 market, uint256 loanShares) private {
        if (loanShares == 0) return;

        _users[account].loan[market].shares += loanShares;
    }

    function _loanSharesForAssets(LoanPool storage pool, UserLoan storage loan, uint128 assets) private view returns (uint256) {
        return _loanSharesForAssets(pool.totalAssets, pool.totalShares, loan.shares, assets);
    }

    function _loanSharesForAssets(uint128 totalAssets, uint256 totalShares, uint256 shares, uint128 assets) private pure returns (uint256) {
        uint128 maxAssets = _previewRedeemLoanAssets(totalAssets, totalShares, shares);
        if (assets == maxAssets) return shares;
        if (assets == 0 || totalShares == 0 || totalAssets == 0) return 0;
        return Math.mulDiv(totalShares, assets, totalAssets, Math.Rounding.Ceil);
    }

    function _burnLoanAssets(address account, uint64 market, uint128 assets) private returns (uint256 loanShares) {
        LoanPool storage pool = _markets[market].loanPool;
        UserLoan storage loan = _users[account].loan[market];

        loanShares = _loanSharesForAssets(pool, loan, assets);

        loan.shares -= loanShares;
        pool.totalAssets -= assets;
        pool.totalShares -= loanShares;
    }



    // ==============================================================
    // Provide Orderbook Helpers
    //
    // Maintains provide-order ownership, tick and bucket liquidity, and
    // lazy settlement state for matching and claim accounting.
    // ==============================================================

    function _mintPOrderShares(
        address account,
        uint64 market,
        uint256 APR,
        uint256 deltaShares
    ) private {
        POrderbookTick storage tick = _markets[market].porderbook.tickByAPR[APR];
        UserPOrdersByMarket storage pordersByMarket = _users[account].porders;
        UserPOrdersByAPR storage pordersByAPR = pordersByMarket.byMarket[market];
        UserPOrder storage order = pordersByAPR.byAPR[APR];

        pordersByMarket.markets.insert(market);
        pordersByAPR.aprs.insert(APR);

        order.tickGeneration = tick.tickGeneration;
        order.loanIndexSnapshot = tick.loanIndex[tick.tickGeneration];
        order.shares += deltaShares;
    }

    function _burnPOrderShares(address account, uint64 market, uint256 APR, uint256 shares) private {
        UserPOrdersByMarket storage pordersByMarket = _users[account].porders;
        UserPOrdersByAPR storage pordersByAPR = pordersByMarket.byMarket[market];
        UserPOrder storage order = pordersByAPR.byAPR[APR];

        order.shares -= shares;

        _deletePOrderIfEmpty(pordersByMarket, pordersByAPR, market, APR);
    }

    function _deletePOrderIfEmpty(
        UserPOrdersByMarket storage pordersByMarket,
        UserPOrdersByAPR storage pordersByAPR,
        uint64 market,
        uint256 APR
    ) private {
        UserPOrder storage order = pordersByAPR.byAPR[APR];

        if (order.shares == 0) {
            pordersByAPR.aprs.remove(APR);
        }

        if (pordersByAPR.aprs.isEmpty()) {
            pordersByMarket.markets.remove(market);
        }
    }

    function _deleteBOrderIfEmpty(
        address borrower,
        uint64 market,
        uint256 APR
    ) private {
        UserBOrdersByMarket storage borderByMarket = _users[borrower].borders;
        UserBOrdersByAPR storage borderByAPR = borderByMarket.byMarket[market];
        UserBOrder storage order = borderByAPR.byAPR[APR];
        BOrderbookTick storage tick = _markets[market].borderbook.tickByAPR[APR];
        bool inactive = _isBOrderInactive(tick, order);

        if (inactive) {
            order.amount = 0;
        }

        if (order.amount == 0) {
            if (!inactive) {
                _queue_remove(tick.borrowers, order.queueNodeId);
            }
            order.queueNodeId = 0;

            _cleanupBOrderSetsIfEmpty(borrower, market, APR);
        }
    }

    function _cleanupBOrderSetsIfEmpty(
        address borrower,
        uint64 market,
        uint256 APR
    ) private {
        UserBOrdersByMarket storage borderByMarket = _users[borrower].borders;
        UserBOrdersByAPR storage borderByAPR = borderByMarket.byMarket[market];
        UserBOrder storage order = borderByAPR.byAPR[APR];

        if (order.amount != 0) return;

        bool clearReloanAPR = order.orderType == BOrderType.Reloan && borderByAPR.reloanAPR == APR;
        borderByAPR.aprs.remove(APR);

        if (borderByAPR.aprs.isEmpty()) {
            borderByMarket.markets.remove(market);
        } else if (clearReloanAPR) {
            borderByAPR.reloanAPR = NO_RELOAN_APR;
        }
    }

    function _disableAllPOrders(address account, uint64 market) private returns (uint256[] memory APRs) {
        UserPOrdersByAPR storage pordersByAPR = _users[account].porders.byMarket[market];
        APRs = pordersByAPR.aprs.keys;
        for (uint256 i = 0; i < APRs.length; i++) {
            _disablePOrder(account, market, APRs[i]);
        }
    }

    function _enableAllPOrders(address account, uint64 market, uint256[] memory APRs) private {
        for (uint256 i = 0; i < APRs.length; i++) {
            _enablePOrder(account, market, APRs[i]);
        }
    }

    function _disablePOrder(address account, uint64 market, uint256 APR) private {
        POrderbookTick storage tick = _syncPOrderbookTick(market, APR);
        POrderbookBucket storage bucket = _markets[market].porderbook.bucketById[_aprToBucketId(APR)];
        UserPOrder storage order = _syncPOrder(account, market, APR);
        if (order.shares == 0) return;

        uint128 balance = _porderBalance(
            order,
            tick,
            bucket,
            _globalUnderlyingPoolIndex,
            _underlyingPoolGeneration
        );
        if (balance == 0) return;

        tick.assets -= balance;
        tick.totalShares -= order.shares;

        bucket.assets -= balance;
        bucket.assetsTimesAPR -= balance * APR;

        order.disabledAssets = balance;
    }

    function _enablePOrder(address account, uint64 market, uint256 APR) private {
        POrderbookTick storage tick = _syncPOrderbookTick(market, APR);
        POrderbookBucket storage bucket = _markets[market].porderbook.bucketById[_aprToBucketId(APR)];
        UserPOrder storage order = _users[account].porders.byMarket[market].byAPR[APR];

        uint128 balance = order.disabledAssets;
        if (balance == 0) return;

        uint256 shares = _previewMintShares(tick, balance, _globalUnderlyingPoolIndex);
        if (shares == 0) revert ZeroSharesMinted(balance);

        tick.assets += balance;
        tick.totalShares += shares;

        bucket.assets += balance;
        bucket.assetsTimesAPR += balance * APR;
        bucket.mayHaveLiveTicks = true;

        order.shares = shares;
        order.tickGeneration = tick.tickGeneration;
        order.loanIndexSnapshot = tick.loanIndex[order.tickGeneration];

        order.disabledAssets = 0;
    }

    function _addPOrderbookTickAmountShares(uint64 market, uint256 APR, uint128 assets, uint256 shares) private {
        POrderbook storage orderbook = _markets[market].porderbook;
        POrderbookTick storage tick = orderbook.tickByAPR[APR];
        POrderbookBucket storage bucket = orderbook.bucketById[_aprToBucketId(APR)];

        tick.assets += assets;
        tick.totalShares += shares;
        bucket.assets += assets;
        bucket.assetsTimesAPR += assets * APR;
        bucket.mayHaveLiveTicks = true;
    }

    function _removePOrderbookTickAmountShares(uint64 market, uint256 APR, uint128 assets, uint256 shares) private {
        POrderbook storage orderbook = _markets[market].porderbook;
        POrderbookTick storage tick = orderbook.tickByAPR[APR];
        POrderbookBucket storage bucket = orderbook.bucketById[_aprToBucketId(APR)];

        tick.assets -= assets;
        tick.totalShares -= shares;
        bucket.assets -= assets;
        bucket.assetsTimesAPR -= assets * APR;
    }

    function _porderBalance(
        UserPOrder storage order,
        POrderbookTick storage tick,
        POrderbookBucket storage bucket,
        uint256 index,
        uint64 underlyingPoolGeneration
    ) private view returns (uint128) {
        if (order.shares == 0 || tick.totalShares == 0) return 0;
        if (
            tick.underlyingPoolGeneration != underlyingPoolGeneration
                || bucket.underlyingPoolGeneration != underlyingPoolGeneration
        ) return 0;
        if (order.tickGeneration != tick.tickGeneration) return 0;

        uint64 orderBucketGeneration = tick.bucketGenerationByTickGeneration[order.tickGeneration];
        if (orderBucketGeneration != bucket.bucketGeneration) return 0;

        uint128 tickAssets = _previewIndexedAmount(tick.assets, tick.indexSnapshot, index).toUint128();
        return Math.mulDiv(uint256(tickAssets) + VIRTUAL_ASSETS, order.shares, tick.totalShares + VIRTUAL_SHARES).toUint128();
    }

    function _porderLoanShares(
        UserPOrder storage order,
        POrderbookTick storage tick,
        POrderbookBucket storage bucket,
        uint256 APR
    ) private view returns (uint256) {
        if (order.shares == 0) return 0;

        uint256 targetLoanIndex = tick.loanIndex[order.tickGeneration];
        uint256 loanShares = 0;

        if (targetLoanIndex > order.loanIndexSnapshot) {
            loanShares += order.shares.mulDiv(targetLoanIndex - order.loanIndexSnapshot, INDEX_SCALE);
        }

        uint64 orderBucketGeneration = tick.bucketGenerationByTickGeneration[order.tickGeneration];
        if (order.tickGeneration != tick.tickGeneration || orderBucketGeneration == bucket.bucketGeneration) return loanShares;

        BucketSettlement storage settlement = bucket.settlementByGeneration[orderBucketGeneration];

        uint128 settledAssets = _previewIndexedAmount(tick.assets, tick.indexSnapshot, settlement.indexSnapshot).toUint128();
        if (settledAssets == 0 || tick.totalShares == 0 || settlement.debtWeight == 0) return loanShares;

        uint256 settledWeight = _loanWeight(settledAssets, APR, settlement.netInterestDuration);
        uint256 settledLoanShares = settledWeight.mulDiv(settlement.loanShares, settlement.debtWeight);
        uint256 settledLoanIndex = _porderLoanIndex(settledLoanShares, settledAssets, tick.totalShares);
        return loanShares + order.shares.mulDiv(settledLoanIndex, INDEX_SCALE);
    }

    function _porderLoanIndex(uint256 loanShares, uint256 assets, uint256 shares) private pure returns (uint256) {
        if (shares == 0) return 0;

        // The virtual asset has no principal to lend. Allocate loans by real redeemable backing;
        // the part of actual liquidity captured by virtual shares must not return to lenders.
        uint256 lenderAssets = Math.mulDiv(assets + VIRTUAL_ASSETS, shares, shares + VIRTUAL_SHARES);
        uint256 lenderLoanShares = loanShares.mulDiv(lenderAssets, assets);
        return lenderLoanShares.mulDiv(INDEX_SCALE, shares);
    }

    function _consumeBucket(
        POrderbookBucket storage bucket,
        uint256 loanShares,
        uint256 netInterestDuration
    ) private {
        bucket.settlementByGeneration[bucket.bucketGeneration] = BucketSettlement({
            indexSnapshot: _globalUnderlyingPoolIndex,
            netInterestDuration: netInterestDuration,
            debtWeight: _loanWeightForBucket(bucket.assets, bucket.assetsTimesAPR, netInterestDuration),
            loanShares: loanShares
        });

        bucket.bucketGeneration += 1;
        bucket.assets = 0;
        bucket.assetsTimesAPR = 0;
        bucket.indexSnapshot = _globalUnderlyingPoolIndex;
        bucket.mayHaveLiveTicks = false;
    }

    function _consumeTick(
        POrderbookTick storage tick,
        POrderbookBucket storage bucket,
        uint256 APR,
        uint128 consumed,
        uint256 loanShares
    ) private {
        tick.loanIndex[tick.tickGeneration] += _porderLoanIndex(loanShares, tick.assets, tick.totalShares);
        tick.assets -= consumed;
        bucket.assets -= consumed;
        bucket.assetsTimesAPR -= consumed * APR;

        if (tick.assets == 0) {
            tick.totalShares = 0;
            tick.tickGeneration += 1;
            tick.bucketGenerationByTickGeneration[tick.tickGeneration] = tick.bucketGeneration;
        }
    }



    // ==============================================================
    // Index / Sync Helpers
    //
    // Propagates underlying-pool PnL into pool-local indices and syncs
    // bucket, tick, and user state before execution or preview logic.
    // ==============================================================

    function _previewUnderlyingPoolState()
        internal view
        returns (uint256 index, uint64 generation, uint256 assets)
    {
        assets = _underlyingPoolAssets();
        index = _globalUnderlyingPoolIndex;
        generation = _underlyingPoolGeneration;
        uint256 activeAssetsBefore = _activeUnderlyingPoolAssets(_lastUnderlyingPoolAssets);
        if (activeAssetsBefore == 0) return (index, generation, assets);

        index = index.mulDiv(_activeUnderlyingPoolAssets(assets), activeAssetsBefore);
        if (index == 0) {
            index = SCALE;
            generation += 1;
        }
    }

    function _previewIndexedAmount(uint256 amount, uint256 indexSnapshot, uint256 index) internal pure returns (uint256) {
        if (amount == 0) return 0;
        if (indexSnapshot == 0) return amount;
        if (index == indexSnapshot) return amount;
        return amount.mulDiv(index, indexSnapshot);
    }

    function _previewMintShares(POrderbookTick storage tick, uint128 assets, uint256 index) private view returns (uint256) {
        uint128 currentAssets = _previewIndexedAmount(tick.assets, tick.indexSnapshot, index).toUint128();

        return Math.mulDiv(tick.totalShares + VIRTUAL_SHARES, assets, uint256(currentAssets) + VIRTUAL_ASSETS, Math.Rounding.Floor);
    }

    function _regUserMarket(address account, uint64 market) private {
        if (account == address(0)) return;

        _users[account].markets.insert(market);

        MarketUsers storage users = _markets[market].users;
        if (!users.seen[account]) {
            users.seen[account] = true;
            users.accounts.push(account);
        }
    }

    function _syncUnderlyingPoolIndex() private returns (uint256 assets) {
        assets = _underlyingPoolAssets();
        _updateUnderlyingPoolIndex(_activeUnderlyingPoolAssets(_lastUnderlyingPoolAssets), assets);
        _lastUnderlyingPoolAssets = assets;
    }

    function _reconcileUnderlyingPoolWithdrawal(uint256 assetsBefore, uint128 withdrawn, uint256 assetsAfter) private {
        uint256 activeAssetsBefore = _activeUnderlyingPoolAssets(assetsBefore);
        if (activeAssetsBefore < withdrawn) {
            revert InsufficientUnderlyingPoolBalance(
                address(_underlyingPoolAdapter),
                activeAssetsBefore,
                withdrawn
            );
        }

        _updateUnderlyingPoolIndex(activeAssetsBefore - withdrawn, assetsAfter);
        _lastUnderlyingPoolAssets = assetsAfter;
    }

    function _updateUnderlyingPoolIndex(uint256 expectedActiveAssets, uint256 assetsAfter) private {
        uint256 oldIndex = _globalUnderlyingPoolIndex;
        bool generationChanged;
        if (expectedActiveAssets == 0) {
            // Recovery without live idle claims stays outside the index; later PnL belongs to new active claims.
            _underlyingPoolReserve = assetsAfter;
            if (oldIndex < SCALE) {
                _underlyingPoolGeneration += 1;
                generationChanged = true;
                _globalUnderlyingPoolIndex = SCALE;
            }
        } else {
            uint256 nextIndex = oldIndex.mulDiv(
                _activeUnderlyingPoolAssets(assetsAfter), expectedActiveAssets
            );
            if (nextIndex == 0) {
                _underlyingPoolGeneration += 1;
                generationChanged = true;
                _globalUnderlyingPoolIndex = SCALE;
                _underlyingPoolReserve = assetsAfter;
            } else {
                _globalUnderlyingPoolIndex = nextIndex;
            }
        }

        if (oldIndex != _globalUnderlyingPoolIndex || generationChanged) {
            emit UnderlyingPoolIndexUpdated(_globalUnderlyingPoolIndex, _underlyingPoolGeneration);
        }
    }

    function _activeUnderlyingPoolAssets(uint256 totalAssets) private view returns (uint256) {
        return totalAssets > _underlyingPoolReserve ? totalAssets - _underlyingPoolReserve : 0;
    }

    function _syncPOrderbookTick(uint64 market, uint256 APR) private returns (POrderbookTick storage tick) {
        POrderbook storage orderbook = _markets[market].porderbook;
        POrderbookBucket storage bucket = _syncPOrderbookBucket(market, _aprToBucketId(APR));
        tick = orderbook.tickByAPR[APR];
        bool underlyingPoolGenerationChanged =
            tick.underlyingPoolGeneration != _underlyingPoolGeneration;
        bool resetTick;

        if (tick.bucketGeneration != bucket.bucketGeneration) {
            BucketSettlement storage settlement = bucket.settlementByGeneration[tick.bucketGeneration];

            uint128 settledAssets = _previewIndexedAmount(tick.assets, tick.indexSnapshot, settlement.indexSnapshot).toUint128();
            if (settledAssets > 0 && tick.totalShares > 0 && settlement.debtWeight > 0) {
                uint256 settledWeight = _loanWeight(settledAssets, APR, settlement.netInterestDuration);
                uint256 settledLoanShares = settlement.loanShares.mulDiv(settledWeight, settlement.debtWeight);
                tick.loanIndex[tick.tickGeneration] += _porderLoanIndex(settledLoanShares, settledAssets, tick.totalShares);
            }

            tick.bucketGeneration = bucket.bucketGeneration;
            resetTick = true;
        } else if (underlyingPoolGenerationChanged) {
            resetTick = true;
        } else {
            tick.assets = _previewIndexedAmount(tick.assets, tick.indexSnapshot, _globalUnderlyingPoolIndex).toUint128();
            resetTick = tick.assets == 0 && tick.totalShares != 0;
        }

        if (resetTick) {
            tick.tickGeneration += 1;
            tick.bucketGenerationByTickGeneration[tick.tickGeneration] = bucket.bucketGeneration;
            tick.assets = 0;
            tick.totalShares = 0;
        }

        tick.underlyingPoolGeneration = _underlyingPoolGeneration;
        tick.indexSnapshot = _globalUnderlyingPoolIndex;
    }

    function _syncPOrderbookBucket(uint64 market, uint256 bucketId) private returns (POrderbookBucket storage bucket) {
        POrderbook storage orderbook = _markets[market].porderbook;
        bucket = orderbook.bucketById[bucketId];
        if (bucket.underlyingPoolGeneration != _underlyingPoolGeneration) {
            bucket.assets = 0;
            bucket.assetsTimesAPR = 0;
            bucket.underlyingPoolGeneration = _underlyingPoolGeneration;
            bucket.mayHaveLiveTicks = false;
        } else if (bucket.mayHaveLiveTicks && bucket.indexSnapshot != _globalUnderlyingPoolIndex) {
            (bucket.assets, bucket.assetsTimesAPR) = _previewPOrderbookBucketAmounts(
                orderbook, bucketId, _globalUnderlyingPoolIndex, _underlyingPoolGeneration
            );
        }
        bucket.indexSnapshot = _globalUnderlyingPoolIndex;
    }

    function _previewPOrderbookBucketAmounts(
        POrderbook storage orderbook,
        uint256 bucketId,
        uint256 index,
        uint64 underlyingPoolGeneration
    ) private view returns (uint128 assets, uint256 assetsTimesAPR) {
        POrderbookBucket storage bucket = orderbook.bucketById[bucketId];
        if (bucket.underlyingPoolGeneration != underlyingPoolGeneration || !bucket.mayHaveLiveTicks) return (0, 0);

        // Rebasing the aggregate separately loses different rounding remainders than rebasing its ticks.
        // A zero aggregate can contain untouched ticks that regain value when the index rises.
        // Old bucket generations remain available for lazy loan settlement, but are no longer live liquidity.
        uint256 firstAPR = _bucketIdToAPR(bucketId);
        for (uint256 i = 0; i < TICKS_PER_BUCKET && firstAPR + i * APR_TICK_SPACING <= MAX_APR; i++) {
            uint256 APR = firstAPR + i * APR_TICK_SPACING;
            POrderbookTick storage tick = orderbook.tickByAPR[APR];
            if (
                tick.bucketGeneration != bucket.bucketGeneration ||
                tick.underlyingPoolGeneration != underlyingPoolGeneration
            ) continue;

            uint128 tickAssets = _previewIndexedAmount(tick.assets, tick.indexSnapshot, index).toUint128();
            assets += tickAssets;
            assetsTimesAPR += uint256(tickAssets) * APR;
        }
    }

    function _syncPOrder(address account, uint64 market, uint256 APR) private returns (UserPOrder storage order) {
        UserPOrdersByMarket storage pordersByMarket = _users[account].porders;
        UserPOrdersByAPR storage pordersByAPR = pordersByMarket.byMarket[market];
        order = pordersByAPR.byAPR[APR];
        POrderbookTick storage tick = _markets[market].porderbook.tickByAPR[APR];

        uint256 targetLoanIndex = tick.loanIndex[order.tickGeneration];

        if (order.shares > 0 && targetLoanIndex > order.loanIndexSnapshot) {
            uint256 deltaIndex = targetLoanIndex - order.loanIndexSnapshot;
            uint256 deltaLoanShares = order.shares.mulDiv(deltaIndex, INDEX_SCALE);
            _creditLoanShares(account, market, deltaLoanShares);
        }

        if (order.tickGeneration != tick.tickGeneration) {
            order.shares = 0;
            order.tickGeneration = tick.tickGeneration;
        }

        order.loanIndexSnapshot = tick.loanIndex[tick.tickGeneration];

        _deletePOrderIfEmpty(pordersByMarket, pordersByAPR, market, APR);
    }

    function _syncAllPOrders(address account, uint64 market) private {
        uint256[] memory aprs = _users[account].porders.byMarket[market].aprs.keys;
        for (uint256 i = 0; i < aprs.length; i++) {
            _syncPOrderbookTick(market, aprs[i]);
            _syncPOrder(account, market, aprs[i]);
        }
    }

    function _syncBOrder(address account, uint64 market, uint256 APR) private {
        UserBOrdersByMarket storage borderByMarket = _users[account].borders;
        UserBOrdersByAPR storage borderByAPR = borderByMarket.byMarket[market];
        UserBOrder storage order = borderByAPR.byAPR[APR];
        BOrderbookTick storage tick = _markets[market].borderbook.tickByAPR[APR];

        if (!_isBOrderInactive(tick, order)) return;

        order.queueNodeId = 0;
        order.amount = 0;
        _cleanupBOrderSetsIfEmpty(account, market, APR);
    }

    function _syncAllBOrders(address account, uint64 market) private {
        uint256[] memory aprs = _users[account].borders.byMarket[market].aprs.keys;
        for (uint256 i = 0; i < aprs.length; i++) {
            _syncBOrder(account, market, aprs[i]);
        }
    }



    // ==============================================================
    // Math / Oracle Helpers
    //
    // Encapsulates fixed-term conversion math, bucket weighting, market
    // duration derivation, and validated oracle price access.
    // ==============================================================

    function _debtFor(uint128 amount, uint256 APR, uint256 duration, Math.Rounding rounding) private pure returns (uint128) {
        uint256 denominator = HUNDRED_PERCENT * YEAR;
        uint256 numerator = amount * (denominator + APR * duration);
        if (rounding == Math.Rounding.Ceil && numerator % denominator != 0) {
            return (numerator / denominator + 1).toUint128();
        }
        return (numerator / denominator).toUint128();
    }

    function _assetsFor(uint128 debt, uint256 APR, uint256 duration, Math.Rounding rounding) private pure returns (uint128) {
        uint256 denominator = HUNDRED_PERCENT * YEAR + APR * duration;
        uint256 numerator = debt * HUNDRED_PERCENT * YEAR;
        if (rounding == Math.Rounding.Ceil && numerator % denominator != 0) {
            return (numerator / denominator + 1).toUint128();
        }
        return (numerator / denominator).toUint128();
    }

    function _protocolFeeAssets(uint128 principal, uint128 grossLoan, uint256 protocolFee)
        internal pure
        returns (uint128 feeAssets)
    {
        if (grossLoan <= principal || protocolFee == 0) return 0;

        return Math.mulDiv(
            grossLoan - principal,
            protocolFee,
            UNIT,
            Math.Rounding.Floor
        ).toUint128();
    }

    // Invert net = gross * (D + R * (1 - fee)) / (D + R), with D = 100% * YEAR.
    // Assigning gross - net to the fee preserves exact output and rounds in the protocol's
    // favor by at most one asset unit compared with floor((gross - principal) * fee).
    // Called for a partial fill whose available net loan exceeds the requested net loan.
    function _grossLoanForNetLoan(uint128 netLoan, uint256 APR, uint256 duration, uint256 protocolFee, uint128 maxGrossLoan)
        internal pure
        returns (uint128)
    {
        uint256 denominator = HUNDRED_PERCENT * YEAR;
        uint256 interest = APR * duration;
        uint256 gross = Math.mulDiv(
            netLoan,
            (denominator + interest) * UNIT,
            denominator * UNIT + interest * (UNIT - protocolFee),
            Math.Rounding.Floor
        );
        // A rounding plateau can extend past the available debt of the last order.
        return uint128(Math.min(gross, maxGrossLoan));
    }

    function _minimumAssetsForDebt(uint128 debt, uint256 APR, uint256 duration) private pure returns (uint128) {
        if (debt == 0) return 0;
        return _assetsFor(debt - 1, APR, duration, Math.Rounding.Floor) + 1;
    }

    function _debtDuration(uint64 market) private view returns (uint256) {
        if (block.timestamp >= market) return 0;
        return market - block.timestamp;
    }

    function _aprToBucketId(uint256 APR) internal pure returns (uint256) {
        return (APR / APR_TICK_SPACING) >> BUCKET_SIZE_AS_POWER_OF_TWO;
    }

    function _bucketIdToAPR(uint256 bucketId) private pure returns (uint256) {
        return (bucketId << BUCKET_SIZE_AS_POWER_OF_TWO) * APR_TICK_SPACING;
    }

    function _debtForBucket(uint128 assets, uint256 assetsTimesAPR, uint256 duration) private pure returns (uint128) {
        uint256 denominator = HUNDRED_PERCENT * YEAR;
        uint256 numerator = assetsTimesAPR * duration;
        uint256 interest = numerator / denominator;
        if (numerator % denominator != 0) interest += 1;
        return (assets + interest).toUint128();
    }

    // netInterestDuration = duration * (UNIT - fee) snapshots the fee used for this settlement.
    // Keep weights in HUNDRED_PERCENT * YEAR units: mulDiv avoids overflowing the scaled
    // interest product and truncates less than 1 / (HUNDRED_PERCENT * YEAR) of an asset unit.
    function _loanWeight(uint128 assets, uint256 APR, uint256 netInterestDuration) private pure returns (uint256) {
        return assets * HUNDRED_PERCENT * YEAR + Math.mulDiv(assets * APR, netInterestDuration, UNIT);
    }

    function _loanWeightForBucket(uint128 assets, uint256 assetsTimesAPR, uint256 netInterestDuration) private pure returns (uint256) {
        return assets * HUNDRED_PERCENT * YEAR + Math.mulDiv(assetsTimesAPR, netInterestDuration, UNIT);
    }

    function _enterPriceCacheScope() internal {
        uint256 depth = _PRICE_CACHE_SCOPE_SLOT.asUint256().tload();
        _PRICE_CACHE_SCOPE_SLOT.asUint256().tstore(depth + 1);
    }

    function _exitPriceCacheScope() internal {
        uint256 depth = _PRICE_CACHE_SCOPE_SLOT.asUint256().tload() - 1;
        _PRICE_CACHE_SCOPE_SLOT.asUint256().tstore(depth);
        if (depth == 0) _clearTransientPrice();
    }

    function _cachePriceForMulticall() private {
        if (
            _PRICE_CACHE_SCOPE_SLOT.asUint256().tload() == 0 ||
            _PRICE_CACHE_DENOMINATOR_SLOT.asUint256().tload() != 0
        ) return;

        IPriceOracle.Price memory price = _loadPrice();
        _PRICE_CACHE_NUMERATOR_SLOT.asUint256().tstore(price.numerator);
        _PRICE_CACHE_DENOMINATOR_SLOT.asUint256().tstore(price.denominator);
    }

    function _clearTransientPrice() private {
        if (_PRICE_CACHE_DENOMINATOR_SLOT.asUint256().tload() != 0) {
            _PRICE_CACHE_DENOMINATOR_SLOT.asUint256().tstore(0);
        }
    }

    function _price(PriceCache memory priceCache) private view returns (IPriceOracle.Price memory price) {
        if (priceCache.loaded) return priceCache.price;

        if (_PRICE_CACHE_SCOPE_SLOT.asUint256().tload() != 0) {
            uint256 transientDenominator = _PRICE_CACHE_DENOMINATOR_SLOT.asUint256().tload();
            if (transientDenominator != 0) {
                price = IPriceOracle.Price({
                    numerator: _PRICE_CACHE_NUMERATOR_SLOT.asUint256().tload(),
                    denominator: transientDenominator,
                    updatedAt: 0
                });
                priceCache.price = price;
                priceCache.loaded = true;
                return price;
            }
        }

        price = _loadPrice();
        priceCache.price = price;
        priceCache.loaded = true;
    }

    function _loadPrice() private view returns (IPriceOracle.Price memory price) {
        price = _priceOracle.getPrice();
        if (
            price.numerator == 0 ||
            price.denominator == 0 ||
            price.numerator / price.denominator > type(uint128).max
        ) {
            revert InvalidOraclePrice(price.numerator, price.denominator);
        }
        if (price.updatedAt + _stalePriceWindow <= block.timestamp) revert StaleOraclePrice(price.updatedAt);
    }



    // ==============================================================
    // Queue / Market Cache Helpers
    //
    // Maintains FIFO borrow-order queues and snapshots mutable global
    // config into market-local cache once a market becomes active.
    // ==============================================================

    function _queue_push(AddressQueue storage queue, address value) internal returns (uint48 id) {
        uint48 queueTail = queue.tail;
        id = ++queue._nextId;

        queue.nodes[id] = AddressQueueNode({ value: value, next: 0, prev: queueTail });

        if (queue.head == 0) {
            queue.head = id;
        }

        if (queueTail != 0) {
            queue.nodes[queueTail].next = id;
        }

        queue.tail = id;
        queue.length += 1;
    }

    function _queue_remove(AddressQueue storage queue, uint48 id) internal {
        if (id == 0) return;

        AddressQueueNode storage node = queue.nodes[id];
        if (queue.head != id && queue.tail != id && node.prev == 0 && node.next == 0 && node.value == address(0)) {
            return;
        }

        if (node.prev != 0) {
            queue.nodes[node.prev].next = node.next;
        }

        if (node.next != 0) {
            queue.nodes[node.next].prev = node.prev;
        }

        if (queue.head == id) {
            queue.head = node.next;
        }

        if (queue.tail == id) {
            queue.tail = node.prev;
        }

        delete queue.nodes[id];
        queue.length -= 1;
    }

    // ==============================================================
    // Ownable
    // ==============================================================

    address public owner;
    modifier onlyOwner() { _onlyOwner(); _; }

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function _checkOwner(address _owner) internal view virtual {
        if (_owner == address(0)) revert OwnableInvalidOwner(_owner);
    }

    function _onlyOwner() internal view virtual {
        if (owner != msg.sender) revert OwnableUnauthorizedAccount(msg.sender);
    }

    function transferOwnership(address newOwner) public onlyOwner {
        _checkOwner(newOwner);

        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}
