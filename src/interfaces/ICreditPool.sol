// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { MarketsConfig, MarketsConfigParams } from "src/lib/MarketsConfig.sol";
import { UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";

interface ICreditPoolTypes {
    struct InitializationParams {
        address owner;
        address permit2;

        address asset;
        UnderlyingPoolConfig underlyingPool;

        address priceOracle;
        address collateral;
        uint64  stalePriceWindow;

        uint256 protocolFee;
        uint128 totalCollateralCap;

        uint128 provideOrderMinAmount;
        uint128 borrowOrderMinAmount;

        uint8   maxActiveProvideOrders;
        uint8   maxActiveBorrowOrders;

        uint256 borrowLTV;
        uint256 liquidationLTV;
        uint256 liquidationDiscountMin;
        uint256 liquidationDiscountMax;
        uint64  liquidationGracePeriod;
        uint128 minDebtRemainingAfterLiquidation;

        MarketsConfigParams marketsConfig;
    }

    struct RefinanceDebtParams {
        uint64 toMarket;
        uint128 debtToRepay;
        uint128 assetsToBorrow;
    }

    struct RefinanceDebtResult {
        uint128 newDebt;
        uint128 collateralMoved;
    }

    struct OrderFill {
        address account;
        uint256 APR;
        uint128 assets;
        uint128 loanAmount;
        bool isReloan;
    }

    struct InvalidatedBorrowOrder {
        address account;
        uint256 APR;
        uint128 amount;
    }

    struct ReconciledReloanOrder {
        address account;
        uint256 APR;
        uint128 amount;
    }

    enum BOrderType {
        Borrow,
        Reloan
    }
}

interface ICreditPoolExplorerAPITypes {
    struct ProvideOrderView {
        uint256 APR;
        uint128 amount;
    }

    struct BorrowOrderView {
        uint256 APR;
        uint128 amount;
        ICreditPoolTypes.BOrderType orderType;
    }

    struct ProvideOrderbookTickView {
        uint128 amount;
    }

    struct BorrowOrderbookTickView {
        uint128 amount;
        uint256 count;
    }
}

abstract contract ICreditPoolConstants {
    uint64  constant public YEAR = 365 days;
    uint256 constant public SCALE = 1e27;
    uint256 constant public INDEX_SCALE = SCALE * SCALE;
    uint256 constant public VIRTUAL_SHARES = SCALE;
    uint256 constant public VIRTUAL_ASSETS = 1;

    uint256 constant public APR_PERCENT = 1e2; // 100 = 1%
    uint256 constant public HUNDRED_PERCENT = 100 * APR_PERCENT;

    uint256 constant public MAX_APR = 20 * APR_PERCENT;
    uint256 constant public APR_TICK_SPACING = 5; // 0.05%

    uint256 constant public BUCKET_SIZE_AS_POWER_OF_TWO = 5; // 2^5 = 32 ticks per bucket
    uint256 constant public TICKS_PER_BUCKET = 1 << BUCKET_SIZE_AS_POWER_OF_TWO;

    uint256 constant public UNIT = 1e18;

    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 constant public MIN_AMOUNT = uint128(HUNDRED_PERCENT / APR_TICK_SPACING); // minimum amount to prevent dust orders

    uint256 constant public DELEGATE_PLACE_PROVIDE_ORDER = 1 << 0;
    uint256 constant public DELEGATE_CANCEL_PROVIDE_ORDER = 1 << 1;
    uint256 constant public DELEGATE_PROVIDE = 1 << 2;
    uint256 constant public DELEGATE_CLAIM = 1 << 3;
    uint256 constant public DELEGATE_RELOAN = 1 << 4;
    uint256 constant public DELEGATE_PLACE_BORROW_ORDER = 1 << 5;
    uint256 constant public DELEGATE_CANCEL_BORROW_ORDER = 1 << 6;
    uint256 constant public DELEGATE_PLACE_RELOAN_ORDER = 1 << 7;
    uint256 constant public DELEGATE_CANCEL_RELOAN_ORDER = 1 << 8;
    uint256 constant public DELEGATE_BORROW = 1 << 9;
    uint256 constant public DELEGATE_REPAY = 1 << 10;
    uint256 constant public DELEGATE_OFFSET = 1 << 11;
    uint256 constant public DELEGATE_WITHDRAW = 1 << 12;
    uint256 constant public DELEGATE_WITHDRAW_COLLATERAL = 1 << 13;
    uint256 constant public DELEGATE_MOVE_COLLATERAL = 1 << 14;
    // Include self-repayment so the broader permission also satisfies existing repay checks.
    uint256 constant public DELEGATE_REPAY_ANY = DELEGATE_REPAY | (1 << 15);
    uint256 constant public DELEGATE_ALL = (1 << 16) - 1;
}

interface ICreditPoolEvents {
    /// @notice Emitted when a lender creates a provide order or adds liquidity to an existing order.
    /// @dev The amount records the increase in the orderbook tick's assets after the underlying deposit.
    /// Underlying protocol rounding may cause this value to differ from the debit to the lender's pool balance.
    /// @param account Address of the lender whose provide order is created or increased.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param amount Amount of assets added to the orderbook tick, in loan token base units.
    /// @param shares Number of internal provide-order shares minted, distinct from underlying protocol shares.
    event ProvideOrderPlaced(address indexed account, uint64 indexed market, uint256 APR, uint128 amount, uint256 shares);

    /// @notice Emitted when a provide order is reduced or cancelled and assets return to the lender's
    /// pool balance.
    /// @dev Cancellation burns all remaining internal shares of the order.
    /// @param account Address of the lender whose order is reduced or cancelled and whose pool balance receives the assets.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param amount Amount of assets removed from the orderbook tick and credited to the pool balance, in loan token
    /// base units.
    /// @param shares Number of internal provide-order shares burned.
    event ProvideOrderCancelled(address indexed account, uint64 indexed market, uint256 APR, uint128 amount, uint256 shares);

    /// @notice Emitted when a borrower creates or increases a borrow order.
    /// @param account Address of the borrower requesting assets through the borrow order.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param amount Increase in the order's asset amount, in loan token base units.
    event BorrowOrderPlaced(address indexed account, uint64 indexed market, uint256 APR, uint128 amount);

    /// @notice Emitted when a borrow order is reduced or cancelled, or invalidated outside matching.
    /// @dev Automatic invalidation occurs when the borrower's collateral is insufficient to support the order.
    /// Invalidations during matching are recorded in Provided.invalidatedOrders without a separate cancellation event.
    /// @param account Address of the borrower whose order is reduced, cancelled or invalidated.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param amount Reduction in the order's asset amount, in loan token base units.
    /// @param invalidated Whether the order was invalidated for insufficient collateral. False indicates manual
    /// reduction or cancellation.
    event BorrowOrderCancelled(address indexed account, uint64 indexed market, uint256 APR, uint128 amount, bool invalidated);

    /// @notice Emitted when a lender creates or increases a reloan order to exchange an existing loan claim for assets.
    /// @dev The order amount measures the loan claim offered for exchange. Asset proceeds depend on the execution
    /// APR.
    /// @param account Address of the lender offering an existing loan claim through the reloan order.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param amount Increase in the order's loan amount, in loan token base units.
    event ReloanOrderPlaced(address indexed account, uint64 indexed market, uint256 APR, uint128 amount);

    /// @notice Emitted when a reloan order is reduced or cancelled, or reconciled outside matching.
    /// @dev Reconciliation adjusts the order to the lender's available loan claim, market maturity and minimum order size.
    /// Reconciliations during matching are recorded in Provided.reconciledOrders without a separate cancellation event.
    /// @param account Address of the lender whose reloan order is reduced or cancelled.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param amount Reduction in the order's loan amount, in loan token base units.
    /// @param reconciled Whether the order was reduced or removed by reconciliation. False indicates manual
    /// reduction or cancellation.
    event ReloanOrderCancelled(address indexed account, uint64 indexed market, uint256 APR, uint128 amount, bool reconciled);

    /// @notice Emitted when a lender redeems a matured loan claim and receives assets in the pool balance.
    /// @param account Address of the lender whose loan claim is redeemed.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param assetsClaimed Amount of assets credited to the lender's pool balance, in loan token base units.
    /// @param loanSharesBurned Number of internal loan shares burned to redeem the claim.
    event Claimed(address indexed account, uint64 indexed market, uint128 assetsClaimed, uint256 loanSharesBurned);

    /// @notice Emitted when an existing loan claim is exchanged for assets by matching against existing provide orders.

    /// @dev Executions of resting reloan orders are recorded in Provided.fills.
    /// @param account Address of the lender exchanging the loan claim and receiving the proceeds in the pool balance.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param loanConsumed Amount of the existing loan claim exchanged, in loan token base units.
    /// @param assetsReceived Amount of assets credited to the lender's pool balance, in loan token base units.
    /// @param loanSharesConsumed Number of internal loan shares transferred from the lender's position.
    /// @param endAPR Inclusive upper APR of the consumed range. The boundary tick may be empty when
    /// execution consumes only whole buckets.
    event Reloaned(address indexed account, uint64 indexed market, uint128 loanConsumed, uint128 assetsReceived, uint256 loanSharesConsumed, uint256 endAPR);

    /// @notice Emitted when a sweep completes matching between the provide and borrow sides of the orderbook.
    /// @dev Summarizes the same operation as the preceding Borrowed and Provided events, including when reward is zero.
    /// The reward is credited to account's pool balance.
    /// @param account Address of the sweep reward beneficiary, which may differ from the caller.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param assetsMatched Amount of assets obtained from provide liquidity by the sweep's borrow leg, in loan token
    /// base units.
    /// @param reward Sweep profit after the protocol fee, in loan token base units.
    event Swept(address indexed account, uint64 indexed market, uint128 assetsMatched, uint128 reward);

    /// @notice Emitted when assets are supplied by matching against existing borrow or reloan orders.
    /// @dev A sweep emits this event for its main provide leg and again if a protocol fee leg is executed. During a
    /// sweep, account identifies the reward beneficiary. The loanReceived amount does not represent their loan
    /// credit. All array entries belong to market. Each array preserves matching order independently. Interleaving is
    /// not recorded.
    /// @param account Address of the lender for a direct provide, or the reward beneficiary for a sweep.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param assetsProvided Amount of assets consumed by the provide operation, in loan token base units.
    /// @param loanReceived Loan claim amount produced by matching, net of protocol fees and before share rounding,
    /// in loan token base units.
    /// @param fills Executed borrow and reloan orders. Each entry contains:
    /// - account: Address of the order owner: the borrower for a borrow order or the lender for a reloan order.
    /// - APR: Annual percentage rate of the order, where 100 represents 1%.
    /// - assets: Amount of assets credited to the order owner's pool balance, in loan token base units.
    /// - loanAmount: Debt created for a borrow order, or existing loan claim consumed for a reloan order,
    ///   in loan token base units.
    /// - isReloan: Whether the execution fills a reloan order. False indicates a borrow order.
    /// @param invalidatedOrders Borrow orders cancelled during matching for insufficient collateral.
    /// No separate BorrowOrderCancelled events are emitted. Each entry contains:
    /// - account: Address of the borrower whose order was invalidated for insufficient collateral.
    /// - APR: Annual percentage rate of the order, where 100 represents 1%.
    /// - amount: Full amount of the cancelled borrow order, in loan token base units.
    /// @param reconciledOrders Reloan orders reduced or removed by reconciliation during matching.
    /// No separate ReloanOrderCancelled events are emitted. Each entry contains:
    /// - account: Address of the lender whose reloan order was reconciled.
    /// - APR: Annual percentage rate of the order, where 100 represents 1%.
    /// - amount: Reduction beyond the reported fill, in loan token base units.
    event Provided(address indexed account, uint64 indexed market, uint128 assetsProvided, uint128 loanReceived, ICreditPoolTypes.OrderFill[] fills, ICreditPoolTypes.InvalidatedBorrowOrder[] invalidatedOrders, ICreditPoolTypes.ReconciledReloanOrder[] reconciledOrders);

    /// @notice Emitted when assets are borrowed by matching against existing provide orders.
    /// @dev Refinancing emits this event before DebtRefinanced for each destination market.
    /// A sweep also emits this event for its borrow leg, which does not credit assets or record debt for account.
    /// @param account Address of the borrower for a direct borrow or refinancing, or the reward beneficiary for a sweep.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param assetsBorrowed Amount of assets borrowed from provide liquidity, in loan token base units.
    /// @param debtIncurred Debt produced by matching, including fixed-term interest, in loan token base units.
    /// @param endAPR Inclusive upper APR of the consumed range. The boundary tick may be empty when
    /// execution consumes only whole buckets.
    event Borrowed(address indexed account, uint64 indexed market, uint128 assetsBorrowed, uint128 debtIncurred, uint256 endAPR);

    /// @notice Emitted when the underlying pool index or generation changes.
    /// @param index Updated underlying pool index, scaled by SCALE.
    /// @param generation Current underlying pool generation.
    event UnderlyingPoolIndexUpdated(uint256 index, uint64 generation);

    /// @notice Emitted when a liquidator repays debt on an unhealthy or overdue position in exchange for discounted
    /// collateral.
    /// @dev The debtRepaid amount excludes any subsequent bad-debt socialization, which is recorded in BadDebtIncurred.
    /// @param liquidator Address of the caller that repays the debt and receives the seized collateral.
    /// @param account Address of the borrower whose debt and collateral are reduced by liquidation.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param debtRepaid Amount of debt repaid by the liquidator, excluding socialized bad debt, in loan token base
    /// units.
    /// @param collateralSeized Amount of collateral transferred to the liquidator, in collateral token base units.
    event Liquidated(address indexed liquidator, address indexed account, uint64 indexed market, uint128 debtRepaid, uint128 collateralSeized);

    /// @notice Emitted when liquidation exhausts a borrower's collateral and the remaining debt is written off.
    /// @dev The loss is shared by loan claim holders in the market, reducing the value of their claims.
    /// @param account Address of the borrower whose remaining debt is written off.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Amount of unrepaid debt written off, in loan token base units.
    event BadDebtIncurred(address indexed account, uint64 indexed market, uint128 amount);

    /// @notice Emitted when a borrower's debt is repaid from a payer's pool balance.
    /// @dev The payer may differ from both the caller and the borrower identified by account.
    /// @param payer Address of the account whose pool balance funds the repayment.
    /// @param account Address of the borrower whose debt is repaid.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Amount of debt repaid, in loan token base units.
    event DebtRepaid(address indexed payer, address indexed account, uint64 indexed market, uint128 amount);

    /// @notice Emitted when loan shares are transferred between accounts within the same market.
    /// @dev The reported amount is the loan claim value of the shares actually transferred after share rounding.
    /// @param from Address of the lender whose loan shares are debited.
    /// @param to Address of the lender whose loan shares are credited.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Loan claim value of the transferred shares, in loan token base units.
    event LoanTransferred(address indexed from, address indexed to, uint64 indexed market, uint128 amount);

    /// @notice Emitted when collateral is deposited into an account's market position.
    /// @dev The depositor may differ from the position owner identified by account.
    /// @param account Address of the account whose market position is credited with collateral.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Amount of collateral deposited, in collateral token base units.
    event CollateralDeposited(address indexed account, uint64 indexed market, uint128 amount);

    /// @notice Emitted when collateral is withdrawn from an account's market position and transferred to a recipient.
    /// @param account Address of the account whose market position is debited for collateral.
    /// @param recipient Address receiving the withdrawn collateral tokens.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Amount of collateral withdrawn, in collateral token base units.
    event CollateralWithdrawn(address indexed account, address indexed recipient, uint64 indexed market, uint128 amount);

    /// @notice Emitted when collateral is moved between an account's positions in two markets.
    /// @dev Collateral transfers performed during refinancing are recorded in DebtRefinanced.
    /// @param account Address of the account that owns the collateral in both markets.
    /// @param fromMarket Source market maturity timestamp, in Unix seconds.
    /// @param toMarket Destination market maturity timestamp, in Unix seconds.
    /// @param amount Amount of collateral transferred between the markets, in collateral token base units.
    event CollateralMoved(address indexed account, uint64 indexed fromMarket, uint64 indexed toMarket, uint128 amount);

    /// @notice Emitted when an account's loan claim is consumed to repay its debt in the same market.
    /// @dev The operation burns loan shares without debiting the account's pool balance.
    /// @param account Address of the borrower whose own loan claim is used to offset the debt.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Amount of loan consumed and debt repaid, in loan token base units.
    event DebtOffsetWithLoan(address indexed account, uint64 indexed market, uint128 amount);

    /// @notice Emitted for each refinancing leg that replaces source-market debt with debt in an active market.
    /// @dev The preceding Borrowed event records this leg's borrowed assets and new debt. Any borrowed assets in excess
    /// of debtRepaid are credited to account's pool balance. No separate DebtRepaid or CollateralMoved events are emitted.
    /// @param account Address of the borrower who owns the source and destination debt and collateral.
    /// @param fromMarket Source market maturity timestamp, in Unix seconds.
    /// @param toMarket Destination market maturity timestamp, in Unix seconds.
    /// @param debtRepaid Amount of source-market debt repaid by this refinancing leg, in loan token base units.
    /// @param collateralMoved Amount of collateral transferred to the destination market, in collateral token base units.
    event DebtRefinanced(address indexed account, uint64 indexed fromMarket, uint64 indexed toMarket, uint128 debtRepaid, uint128 collateralMoved);

    /// @notice Emitted when loan tokens are deposited into the pool and credited to the recipient's pool balance.
    /// @param sender Address of the caller supplying the loan tokens, including extension contracts.
    /// @param recipient Address of the account receiving the pool balance credit.
    /// @param amount Amount of assets deposited, in loan token base units.
    event AssetsDeposited(address indexed sender, address indexed recipient, uint128 amount);

    /// @notice Emitted when loan tokens are withdrawn from an account's pool balance and transferred to a recipient.
    /// @param account Address of the account whose pool balance is debited for the withdrawal.
    /// @param recipient Address receiving the withdrawn loan tokens.
    /// @param amount Amount of assets withdrawn, in loan token base units.
    event AssetsWithdrawn(address indexed account, address indexed recipient, uint128 amount);

    /// @notice Emitted when an account grants, changes or revokes a delegate's action permissions.
    /// @param account Address of the account granting, changing or revoking delegated permissions.
    /// @param delegate Address authorized to perform the permitted actions on behalf of account.
    /// @param oldActions Previous action-permission bitmask, defined by the DELEGATE_* constants.
    /// @param newActions Updated action-permission bitmask, defined by the DELEGATE_* constants. Zero revokes all permissions.
    event DelegateUpdated(address indexed account, address indexed delegate, uint256 oldActions, uint256 newActions);

    /// @notice Emitted when residual underlying protocol dust is withdrawn and credited to the owner's pool balance.
    /// @param assets Amount of dust withdrawn, in loan token base units. Always one base unit.
    /// @param newGeneration Underlying-pool accounting generation after dust settlement.
    event UnderlyingPoolDustSettled(uint256 assets, uint64 newGeneration);

    /// @notice Emitted when the owner updates a pool configuration parameter.
    /// @param admin Address of the pool owner updating the configuration.
    /// @param key Name of the configuration parameter. Rates use 1e18 for 100%, token amounts use token base units,
    /// durations use seconds, and order-count limits use unscaled integers.
    /// @param oldValue Previous configuration value, in the units defined by key.
    /// @param newValue Updated configuration value, in the units defined by key.
    event AdminConfigUpdated(address indexed admin, string key, uint256 oldValue, uint256 newValue);
}

interface ICreditPoolExplorerAPI is ICreditPoolExplorerAPITypes {
    /// @notice Returns a page of markets an account has interacted with.
    /// @dev Includes activity initiated by others, such as loan claim transfers to the account. Entries remain after
    /// all positions are closed. An out-of-range start returns an empty array.
    /// @param account Address of the account.
    /// @param start Zero-based offset into the market list.
    /// @param limit Maximum number of entries to return. Zero returns an empty array.
    /// @return markets Maturity timestamps in order of first recorded interaction, in Unix seconds.
    function getUserMarkets(address account, uint256 start, uint256 limit) external view returns (uint64[] memory markets);

    /// @notice Returns a page of accounts that have interacted with a market.
    /// @dev Includes activity initiated by others, such as loan claim transfers to the account. Entries remain after
    /// all positions are closed. An out-of-range start returns an empty array.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param start Zero-based offset into the account list.
    /// @param limit Maximum number of entries to return. Zero returns an empty array.
    /// @return users Account addresses in order of first recorded interaction.
    function getMarketUsers(uint64 market, uint256 start, uint256 limit) external view returns (address[] memory users);

    /// @notice Returns an account's provide orders with nonzero remaining balances.
    /// @dev Balances reflect underlying pool gains and losses. Entries are not sorted by APR.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param account Address of the lender who owns the orders.
    /// @return orders Remaining orders. Each entry contains:
    /// - APR: Annual percentage rate of the order, where 100 represents 1%.
    /// - amount: Unfilled assets, in loan token base units.
    function getAllProvideOrders(uint64 market, address account) external view returns (ICreditPoolExplorerAPITypes.ProvideOrderView[] memory orders);

    /// @notice Returns an account's borrow and reloan orders with nonzero remaining balances.
    /// @dev Reloan amounts are capped as in getBorrowOrderBalance. Entries are not sorted by APR.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param account Address of the borrower or lender who owns the orders.
    /// @return orders Remaining orders. Each entry contains:
    /// - APR: Annual percentage rate of the order, where 100 represents 1%.
    /// - amount: Assets still requested by a borrow order or loan claim still offered by a reloan order, in loan
    /// token base units.
    /// - orderType: Borrow for an asset request or Reloan for a loan claim offer.
    function getAllBorrowOrders(uint64 market, address account) external view returns (ICreditPoolExplorerAPITypes.BorrowOrderView[] memory orders);

    /// @notice Returns the total value of a market's loan claims.
    /// @dev Includes repaid assets available for redemption and outstanding debt. Excludes unfilled provide orders.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @return Total loan claim amount after bad-debt write-downs, in loan token base units.
    function getMarketLoan(uint64 market) external view returns (uint128);

    /// @notice Returns the repaid assets available to redeem a market's loan claims.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @return Available redemption balance, in loan token base units.
    function getMarketBalance(uint64 market) external view returns (uint128);

    /// @notice Returns remaining provide liquidity at every APR tick.
    /// @dev Entry i represents APR i * APR_TICK_SPACING, including empty ticks. Balances reflect underlying pool
    /// gains and losses.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @return ticks Tick totals. Each entry contains:
    /// - amount: Unfilled assets at the tick, in loan token base units.
    function getProvideOrderbook(uint64 market) external view returns (ICreditPoolExplorerAPITypes.ProvideOrderbookTickView[] memory ticks);

    /// @notice Returns aggregate borrow and reloan demand at every APR tick.
    /// @dev Entry i represents APR i * APR_TICK_SPACING, including empty ticks. Reloan claims are converted to assets
    /// at that APR. Uses stored queue totals without checking collateral or reconciling reloan backing. Amounts may
    /// include stale orders.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @return ticks Tick totals. Each entry contains:
    /// - amount: Combined borrow and reloan asset demand at the tick, in loan token base units.
    /// - count: Number of queued borrow and reloan orders at the tick.
    function getBorrowOrderbook(uint64 market) external view returns (ICreditPoolExplorerAPITypes.BorrowOrderbookTickView[] memory ticks);
}

interface ICreditPoolBotAPI {
    /// @notice Liquidates a position by repaying debt in exchange for discounted collateral.
    /// @dev Permissionless. Collateral is sent to the caller before the optional callback. Loan tokens are then
    /// pulled from the caller. Any debt left after collateral is exhausted is written off. Loan claim holders share
    /// the loss.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param account Address of the borrower being liquidated.
    /// @param debtAmount Debt to repay, in loan token base units. type(uint128).max requests the full debt. Repayment
    /// is capped by available collateral.
    /// @param minDiscountOut Minimum acceptable collateral discount, where 1e18 represents 100%.
    /// @param deadline Latest allowed execution timestamp, in Unix seconds.
    /// @param data Data passed to the caller's liquidateCallback. Empty data skips the callback.
    function liquidate(uint64 market, address account, uint128 debtAmount, uint256 minDiscountOut, uint256 deadline, bytes calldata data) external;
}

interface ICreditPoolErrors is ICreditPoolTypes {
    error AmountIsOutOfRange(uint256 amount, uint256 minAmount, uint256 maxAmount);
    error ZeroSharesMinted(uint256 amount);
    error InvalidAPR(uint256 APR, uint256 tickSpacing, uint256 maxAPR);

    error TooManyProvideOrders(uint256 maxOrders);
    error TooManyBorrowOrders(uint256 maxOrders);

    error InsufficientProvideOrderShares(uint256 available, uint256 requested);

    error InvalidTransferRecipient();

    error ProvideNotFulfilled(uint256 provided, uint256 requested);
    error ProvideMinLoanNotReached(uint256 loan, uint256 minLoan);
    error ProvideMaxCrossedOrdersExceeded(uint256 crossedOrders, uint256 maxCrossedOrders);

    error InsufficientMarketLoanAvailable(uint256 available, uint256 requested);
    error InsufficientPoolBalance(address token, uint256 available, uint256 requested);

    error BorrowAssetsNotReached(uint256 requested, uint256 fulfilled);
    error BorrowDebtExceeded(uint256 debt, uint256 maxDebt);
    error BorrowDebtNotReached(uint256 requested, uint256 fulfilled);

    error InactiveMarket(uint64 market);
    error ActiveMarket(uint64 market);

    error BorrowOrderTypeMismatch(ICreditPoolTypes.BOrderType expected, ICreditPoolTypes.BOrderType actual);
    error ReloanOrderExceedsLoan(uint256 reloanAmount, uint256 loan);
    error ReloanOrderAlreadyExists(uint256 existingAPR);
    error UnhealthyDebt(uint256 healthFactor);
    error NotLiquidatable();
    error NoCollateralToSeize();
    error NoDebtToLiquidate();
    error LiquidationExpired(uint256 deadline);
    error LiquidationDiscountTooLow(uint256 discount, uint256 minDiscountOut);
    error InsufficientLiquidationAmount(uint256 remainingDebt, uint256 remainingCollateralInAssets, uint256 minRemainingDebt);

    error StaleOraclePrice(uint256 updatedAt);
    error InvalidOraclePrice(uint256 numerator, uint256 denominator);

    error InvalidUnderlyingPoolAdapter(address adapter);
    error UnderlyingPoolCallFailed(address adapter);
    error UnderlyingPoolPositionDecreased(uint256 assetsBefore, uint256 assetsAfter);
    error InsufficientUnderlyingPoolBalance(address adapter, uint256 available, uint256 requested);
    error UnderlyingPoolIndexPrecisionExhausted(uint256 index, uint256 activeAssets);
    error UnderlyingPoolDustSettlementUnavailable(uint256 index, uint256 activeAssets, uint256 maxDust);

    error InvalidRefinanceMarket(uint64 fromMarket, uint64 toMarket);
    error MaxRolloverFactorExceeded(uint256 factor, uint256 maxFactor);
    error InvalidCollateralMove(uint64 fromMarket, uint64 toMarket);

    error InvalidPriceOracle();
    error InvalidStalePriceWindow();
    error InvalidBorrowOrderMinAmount();
    error InvalidProvideOrderMinAmount();
    error InvalidMarketsConfig();
    error InvalidBorrowLTV();
    error InvalidLiquidationLTV();
    error InvalidProtocolFee();
    error InvalidLiquidationGracePeriod(uint256 min, uint256 max, uint256 provided);
    error InvalidLiquidationDiscountMin(uint256 min, uint256 max, uint256 provided);
    error InvalidLiquidationDiscountMax(uint256 min, uint256 max, uint256 provided);

    error ProvideOrderMinAmountNotReached(uint256 balance, uint256 minAmount);
    error BorrowOrderMinAmountNotReached(uint256 balance, uint256 minAmount);

    error InvalidAccount(address account);
    error InvalidDelegate(address delegate);
    error InvalidDelegateActions(uint256 actions);
    error DelegateNotApproved(address account, address delegate, uint256 action);

    error CollateralCapExceeded(uint128 collateralBalane, uint128 totalCollateralCap);
}

interface ICreditPool is ICreditPoolTypes {
    /// @notice Returns the pool implementation version.
    /// @return Version number.
    function version() external pure returns (uint256);

    /// @notice Returns the oracle that quotes the collateral token price in loan tokens.
    /// @return Oracle contract address.
    function priceOracle() external view returns (address);

    /// @notice Returns the Permit2 contract configured for this pool.
    /// @return Permit2 contract address.
    function permit2() external view returns (address);

    /// @notice Returns the adapter and configuration used for unmatched provide orders.
    /// @return Configuration containing:
    /// - adapter: Address of the underlying pool adapter.
    /// - config: Adapter-specific bytes32 identifier for the underlying position or market.
    function underlyingPool() external view returns (UnderlyingPoolConfig memory);

    /// @notice Returns the loan token used for pool balances and debt.
    /// @return Loan token address.
    function asset() external view returns (address);

    /// @notice Returns the collateral token.
    /// @return Collateral token address.
    function collateral() external view returns (address);

    /// @notice Returns the maximum staleness of an oracle price.
    /// @return Maximum price staleness, in seconds.
    function getStalePriceWindow() external view returns (uint64);

    /// @notice Returns the maximum loan-to-value allowed for borrowing and collateral removal.
    /// @return Borrow LTV, where 1e18 represents 100%.
    function getBorrowLTV() external view returns (uint256);

    /// @notice Returns the threshold loan-to-value for health-based liquidation.
    /// @return Liquidation LTV, where 1e18 represents 100%.
    function getLiquidationLTV() external view returns (uint256);

    /// @notice Returns the protocol fee rate applicable to a market.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @return Share of a lender's interest from matched positions charged as a fee, where 1e18 represents 100%.
    function getProtocolFee(uint64 market) external view returns (uint256);

    /// @notice Sets the protocol fee rate for future markets.
    /// @dev Only the pool owner may call this method.
    /// @param newProtocolFee Share of a lender's interest from matched positions charged as a fee, where 1e18 represents 100%.
    ///  Must be below 1e18.
    function setProtocolFee(uint256 newProtocolFee) external;

    /// @notice Returns the total collateral cap.
    /// @return Maximum collateral token amount held across all accounts and markets, in collateral token base units.
    function getTotalCollateralCap() external view returns (uint128);

    /// @notice Sets the total collateral cap.
    /// @dev Only the pool owner may call this method. Applies to subsequent collateral deposits. Lowering the cap
    /// does not affect existing collateral.
    /// @param newCollateralCap Maximum collateral token amount held across all accounts and markets, in collateral token base
    /// units.
    function setTotalCollateralCap(uint128 newCollateralCap) external;

    /// @notice Returns the minimum size of borrow and reloan orders.
    /// @return Minimum nonzero order size, in loan token base units. Reloan claims are measured by the assets they
    /// would receive at the order's APR.
    function getBorrowOrderMinAmount() external view returns (uint128);

    /// @notice Sets the minimum size of borrow and reloan orders.
    /// @dev Only the pool owner may call this method. Applies when placing or reducing orders and during reloan
    /// reconciliation. Matching may leave smaller remainders.
    /// @param newMinAmount Minimum nonzero order size, in loan token base units. Reloan claims are measured by the
    /// assets they would receive at the order's APR.
    function setBorrowOrderMinAmount(uint128 newMinAmount) external;

    /// @notice Returns the minimum provide order size.
    /// @return Minimum nonzero unfilled asset balance, in loan token base units.
    function getProvideOrderMinAmount() external view returns (uint128);

    /// @notice Sets the minimum provide order size.
    /// @dev Only the pool owner may call this method. Applies when placing or reducing orders. Matching may leave
    /// smaller remainders.
    /// @param newMinAmount Minimum nonzero unfilled asset balance, in loan token base units.
    function setProvideOrderMinAmount(uint128 newMinAmount) external;

    /// @notice Returns the maximum number of provide orders per account per market.
    /// @return Maximum number of distinct provide-order APRs per account per market.
    function getMaxActiveProvideOrders() external view returns (uint8);

    /// @notice Sets the maximum number of provide orders per account per market.
    /// @dev Only the pool owner may call this method.
    /// Existing orders are not cancelled when the limit is lowered.
    /// @param newMax Maximum number of distinct provide-order APRs per account per market.
    function setMaxActiveProvideOrders(uint8 newMax) external;

    /// @notice Returns the maximum number of borrow and reloan orders per account per market.
    /// @return Maximum number of distinct borrow or reloan order APRs per account per market, counted together.
    function getMaxActiveBorrowOrders() external view returns (uint8);

    /// @notice Sets the maximum number of borrow and reloan orders per account per market.
    /// @dev Only the pool owner may call this method.
    /// Existing orders are not cancelled when the limit is lowered.
    /// @param newMax Maximum number of distinct borrow or reloan order APRs per account per market, counted together.
    function setMaxActiveBorrowOrders(uint8 newMax) external;

    /// @notice Returns the minimum remaining debt allowed after a partial liquidation.
    /// @return Minimum remaining debt, in loan token base units.
    function getMinDebtRemainingAfterLiquidation() external view returns (uint128);

    /// @notice Sets the minimum remaining debt allowed after a partial liquidation.
    /// @dev Only the pool owner may call this method. A smaller remainder is allowed only when the position's
    /// collateral is exhausted. That remainder is accounted as bad debt.
    /// @param newMin Minimum remaining debt, in loan token base units.
    function setMinDebtRemainingAfterLiquidation(uint128 newMin) external;

    /// @notice Returns the minimum liquidation discount applicable to a market.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @return Discount fraction, where 1e18 represents 100%.
    function getLiquidationDiscountMin(uint64 market) external view returns (uint256);

    /// @notice Sets the minimum liquidation discount for future markets.
    /// @dev Only the pool owner may call this method.
    /// @param newMin Discount fraction, where 1e18 represents 100%. Must not exceed the maximum discount.
    function setLiquidationDiscountMin(uint256 newMin) external;

    /// @notice Returns the maximum liquidation discount applicable to a market.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @return Discount fraction, where 1e18 represents 100%.
    function getLiquidationDiscountMax(uint64 market) external view returns (uint256);

    /// @notice Sets the maximum liquidation discount for future markets.
    /// @dev Only the pool owner may call this method.
    /// @param newMax Discount fraction, where 1e18 represents 100%. Must be at least the minimum discount and at
    /// most 40% of the gap between 100% and liquidation LTV.
    function setLiquidationDiscountMax(uint256 newMax) external;

    /// @notice Returns the delay after maturity before healthy debt becomes liquidatable.
    /// @dev Healthy debt has a health factor of at least 1e18 at liquidation LTV. Unhealthy debt can be liquidated earlier.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @return Grace period, in seconds.
    function getLiquidationGracePeriod(uint64 market) external view returns (uint64);

    /// @notice Sets the delay after maturity before healthy debt becomes liquidatable in future markets.
    /// @dev Only the pool owner may call this method.
    /// Healthy debt has a health factor of at least 1e18 at liquidation LTV.
    /// @param newGracePeriod Grace period in seconds. Must be shorter than the shortest market duration. Zero allows
    /// liquidation at maturity.
    function setLiquidationGracePeriod(uint64 newGracePeriod) external;

    /// @notice Returns the schedule that determines market maturities and active periods.
    /// @dev Each extension advances the opening of its tier's markets. It does not postpone maturity.
    /// @return Configuration containing:
    /// - start: Reference timestamp for the maturity schedule, in Unix seconds.
    /// - durations: Market duration for each tier, in seconds.
    /// - active: Number of active markets per tier before applying extensions.
    /// - extensions: Time by which each tier's markets open earlier, in seconds.
    function getMarketsConfig() external view returns (MarketsConfig memory);

    /// @notice Returns the markets currently open for order placement and matching.
    /// @return Distinct maturity timestamps in ascending order, in Unix seconds.
    function getActiveMarkets() external view returns (uint64[] memory);

    /// @notice Withdraws the final loan token base unit from the underlying pool into the owner's pool balance and
    /// resets its accounting generation.
    /// @dev Only the pool owner may call this method.
    /// Available only when one loan token base unit of active underlying assets remains and the underlying index is
    /// below SCALE. Old unfilled provide-order shares become worthless.
    function settleUnderlyingPoolDust() external;

    /// @notice Sets the caller's action permissions for a delegate, replacing the previous permissions.
    /// @param delegate Delegate address. Must differ from the caller and address(0).
    /// @param actions Bitmask of DELEGATE_* permissions. Zero revokes all permissions.
    function setDelegate(address delegate, uint256 actions) external;

    /// @notice Returns the action permissions explicitly granted to a delegate.
    /// @param account Address of the account granting permissions.
    /// @param delegate Address of the delegate.
    /// @return Stored DELEGATE_* bitmask. The account's implicit self-authorization is not included.
    function getDelegateActions(address account, address delegate) external view returns (uint256);

    /// @notice Returns whether a delegate may perform all requested actions for an account.
    /// @param account Address of the account granting permissions.
    /// @param delegate Address whose authorization is checked.
    /// @param action Nonzero bitmask of DELEGATE_* permissions to check.
    /// @return True if every requested action is approved, or if account and delegate are the same address.
    function isDelegateApproved(address account, address delegate, uint256 action) external view returns (bool);

    /// @notice Returns an account's available pool balance.
    /// @param account Address of the balance owner.
    /// @return Account's pool balance, in loan token base units.
    function balanceOf(address account) external view returns (uint128);

    /// @notice Deposits loan tokens from the caller into the recipient's pool balance.
    /// @dev The caller must approve the pool to transfer the loan tokens. No delegation from recipient is required.
    /// @param recipient Address receiving the pool balance credit.
    /// @param amount Amount to deposit, in loan token base units.
    function deposit(address recipient, uint128 amount) external;

    /// @notice Withdraws loan tokens from an account's pool balance to a recipient.
    /// @dev Callable by account or a delegate approved for DELEGATE_WITHDRAW.
    /// @param account Address whose pool balance is debited.
    /// @param to Address receiving the loan tokens.
    /// @param amount Amount to withdraw, in loan token base units. type(uint128).max withdraws the full pool balance.
    function withdraw(address account, address to, uint128 amount) external;

    /// @notice Places a provide order or increases an existing one using the lender's pool balance.
    /// @dev Callable by account or a delegate approved for DELEGATE_PLACE_PROVIDE_ORDER. Requires an active market.
    /// Assets are deposited into the underlying pool without immediate matching.
    /// Deposit rounding may change the amount credited to the order.
    /// @param account Address of the lender who owns the order.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate, where 100 represents 1%. Must be a multiple of APR_TICK_SPACING
    ///  and at most MAX_APR.
    /// @param amount Assets to debit from the pool balance, in loan token base units.
    function placeProvideOrder(address account, uint64 market, uint256 APR, uint128 amount) external;

    /// @notice Reduces or cancels a provide order, returning assets to the lender's pool balance.
    /// @dev Callable by account or a delegate approved for DELEGATE_CANCEL_PROVIDE_ORDER.
    /// Cancelling the order burns all remaining shares. Any nonzero remainder must meet
    /// the minimum order size.
    /// @param account Address of the lender who owns the order.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param amount Reduction in the order's asset amount, in loan token base units. type(uint128).max cancels the order.
    function cancelProvideOrder(address account, uint64 market, uint256 APR, uint128 amount) external;

    /// @notice Returns the remaining asset balance of a provide order.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param account Address of the lender who owns the order.
    /// @return balance Remaining order's assets after underlying pool gains and losses, in loan token base units.
    function getProvideOrderBalance(uint64 market, uint256 APR, address account) external view returns (uint128 balance);

    /// @notice Places a borrow order or increases an existing one in an active market.
    /// @dev Callable by account or a delegate approved for DELEGATE_PLACE_BORROW_ORDER.
    /// Checks collateral against existing debt plus this order's full debt using borrow LTV, the maximum
    /// loan-to-value allowed for borrowing. Assets and debt are credited only when the order is filled.
    /// @param account Address of the borrower who owns the order.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate, where 100 represents 1%. Must be a multiple of APR_TICK_SPACING and at most
    /// MAX_APR.
    /// @param amount Increase in requested assets, in loan token base units.
    function placeBorrowOrder(address account, uint64 market, uint256 APR, uint128 amount) external;

    /// @notice Places a reloan order or increases an existing one to exchange a loan claim for assets.
    /// @dev Callable by account or a delegate approved for DELEGATE_PLACE_RELOAN_ORDER.
    /// Requires an active market and sufficient loan claim backing. Each account may have only one reloan APR per
    /// market.
    /// @param account Address of the lender who owns the order.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate, where 100 represents 1%. Must be a multiple of APR_TICK_SPACING and at most
    /// MAX_APR.
    /// @param amount Increase in the loan claim offered for exchange, in loan token base units.
    function placeReloanOrder(address account, uint64 market, uint256 APR, uint128 amount) external;

    /// @notice Reduces or cancels an account's borrow order.
    /// @dev Callable by account or a delegate approved for DELEGATE_CANCEL_BORROW_ORDER.
    /// Requires an active market. Any nonzero remainder must meet the borrow-side minimum size, measured in assets.
    /// @param account Address of the borrower who owns the order.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param amount Reduction in the requested asset amount, in loan token base units. type(uint128).max cancels the
    /// order.
    function cancelBorrowOrder(address account, uint64 market, uint256 APR, uint128 amount) external;

    /// @notice Reduces or cancels an account's reloan order.
    /// @dev Callable by account or a delegate approved for DELEGATE_CANCEL_RELOAN_ORDER.
    /// Requires an active market. Any nonzero remainder must meet the borrow-side minimum size, measured in assets.
    /// @param account Address of the lender who owns the order.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param amount Reduction in the offered loan claim, in loan token base units. type(uint128).max cancels the
    /// order.
    function cancelReloanOrder(address account, uint64 market, uint256 APR, uint128 amount) external;

    /// @notice Reduces or removes a reloan order to reflect its available backing.
    /// @dev Permissionless. Caps the order by the available loan claim and removes it at maturity or when a
    /// required reduction leaves it below the minimum size. Does nothing if no adjustment is needed.
    /// @param account Address of the lender who owns the order.
    /// @param market Market maturity timestamp, in Unix seconds.
    function reconcileReloanOrder(address account, uint64 market) external;

    /// @notice Returns the remaining balance of a borrow or reloan order.
    /// @dev Reloan balances are capped by the loan claim already credited to the account and return zero at maturity.
    /// Uncredited provide-order fills are excluded. Borrow balances do not check collateral.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param account Address of the borrower or lender who owns the order.
    /// @return balance Requested assets for a borrow order or offered loan claim for a reloan order, in loan token
    /// base units.
    function getBorrowOrderBalance(uint64 market, uint256 APR, address account) external view returns (uint128 balance);

    /// @notice Returns the stored type of an order on the borrow side.
    /// @dev Does not establish that an order exists or has a nonzero balance. An unset entry defaults to Borrow.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param APR Annual percentage rate of the order, where 100 represents 1%.
    /// @param account Address of the borrower or lender who owns the order.
    /// @return orderType Borrow for an asset request or Reloan for a loan claim offer.
    function getBorrowOrderType(uint64 market, uint256 APR, address account) external view returns (ICreditPoolTypes.BOrderType orderType);

    /// @notice Returns an account's current loan claim in a market.
    /// @dev Includes claims from provide-order fills even before they are credited to the account's loan shares.
    /// Reflects shared bad-debt losses. The full claim may not be immediately redeemable.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param account Address of the lender.
    /// @return loan Loan claim amount, in loan token base units, rounded down from loan shares.
    function loanOf(uint64 market, address account) external view returns (uint128 loan);

    /// @notice Transfers part or all of the caller's loan claim to another account.
    /// @dev Partial transfers round loan shares up, so the transferred claim may slightly exceed the requested
    /// amount. Reconciles the caller's reloan order afterward.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param to Address receiving the loan shares.
    /// @param amount Loan claim to transfer, in loan token base units. type(uint128).max transfers the full claim.
    function transferLoan(uint64 market, address to, uint128 amount) external;

    /// @notice Claims assets for a matured loan claim, crediting the lender's pool balance.
    /// @dev Callable by account or a delegate approved for DELEGATE_CLAIM.
    /// Requires enough repaid assets in the market to cover the requested amount. Partial redemption rounds the
    /// burned loan shares up.
    /// @param account Address of the lender whose loan shares are burned and pool balance is credited.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Loan claim to redeem, in loan token base units. type(uint128).max requests the full claim.
    function claim(address account, uint64 market, uint128 amount) external;

    /// @notice Returns an account's outstanding debt in a market.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param account Address of the borrower.
    /// @return Debt including interest fixed at borrowing, in loan token base units.
    function debtOf(uint64 market, address account) external view returns (uint128);

    /// @notice Repays a borrower's debt using an account's pool balance.
    /// @dev Callable by account. A delegate needs DELEGATE_REPAY when account is the borrower, or DELEGATE_REPAY_ANY
    /// when paying another borrower's debt.
    /// @param account Address whose pool balance funds repayment.
    /// @param borrower Address whose debt is repaid.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Debt to repay, in loan token base units. type(uint128).max repays the borrower's full debt.
    function repay(address account, address borrower, uint64 market, uint128 amount) external;

    /// @notice Reduces an account's debt by consuming its loan claim in the same market.
    /// @dev Callable by account or a delegate approved for DELEGATE_OFFSET.
    /// Available before or after maturity without transferring loan tokens. Reconciles any affected reloan order.
    /// @param account Address whose debt and loan claim are reduced.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Amount to offset, in loan token base units. type(uint128).max uses the smaller of the debt and
    /// loan claim.
    function offset(address account, uint64 market, uint128 amount) external;

    /// @notice Returns the collateral assigned to an account in a market.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param account Address of the collateral owner.
    /// @return Collateral amount, in collateral token base units.
    function collateralOf(uint64 market, address account) external view returns (uint128);

    /// @notice Deposits collateral from the caller into an account's market position.
    /// @dev The caller must approve the pool to transfer the collateral tokens. No delegation from account is
    /// required. The pool-wide collateral cap applies.
    /// @param account Address receiving the collateral credit.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Amount of collateral to deposit, in collateral token base units.
    function depositCollateral(address account, uint64 market, uint128 amount) external;

    /// @notice Withdraws collateral from an account's market position to a recipient.
    /// @dev Callable by account or a delegate approved for DELEGATE_WITHDRAW_COLLATERAL.
    /// The remaining loan-to-value must not exceed borrow LTV, the maximum allowed for borrowing. Borrow orders
    /// that no longer have enough collateral are invalidated.
    /// @param account Address whose collateral is withdrawn.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param to Address receiving the collateral tokens.
    /// @param amount Collateral to withdraw, in collateral token base units. type(uint128).max requests all
    /// collateral in the position.
    function withdrawCollateral(address account, uint64 market, address to, uint128 amount) external;

    /// @notice Moves an account's collateral between two markets without transferring tokens.
    /// @dev Callable by account or a delegate approved for DELEGATE_MOVE_COLLATERAL.
    /// The source position's loan-to-value must not exceed borrow LTV, the maximum allowed for borrowing. Borrow
    /// orders in the source market that no longer have enough collateral are invalidated.
    /// @param account Address whose collateral is moved.
    /// @param fromMarket Source maturity timestamp, in Unix seconds.
    /// @param toMarket Destination maturity timestamp, in Unix seconds. Must differ from fromMarket.
    /// @param amount Collateral to move, in collateral token base units. type(uint128).max requests all source
    /// collateral.
    function moveCollateral(address account, uint64 fromMarket, uint64 toMarket, uint128 amount) external;

    /// @notice Provides an exact asset amount for a loan claim by matching against existing borrow or reloan orders.
    /// @dev Callable by account or a delegate approved for DELEGATE_PROVIDE.
    /// Requires an active market and skips account's own orders. Reverts unless the full asset amount is spent and
    /// the minimum loan is reached.
    /// @param account Address of the lender funding the operation and receiving the loan shares.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param assetsAmount Exact assets to spend from the pool balance, in loan token base units.
    /// @param minLoanAmount Minimum acceptable loan claim, net of protocol fees and before share rounding, in loan
    /// token base units.
    /// @param maxCrossedOrders Maximum number of borrow-side orders crossed, including skipped and invalidated
    /// orders.
    function provideExactIn(address account, uint64 market, uint128 assetsAmount, uint128 minLoanAmount, uint16 maxCrossedOrders) external;

    /// @notice Previews providing an exact asset amount by matching against existing borrow or reloan orders.
    /// @dev Requires an active market. May return a partial result when liquidity or the crossing limit is
    /// insufficient. Does not check the account's pool balance or authorization.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param assetsAmount Exact assets to match, in loan token base units.
    /// @param minLoanAmount Loan claim minimum passed to provideExactIn, net of protocol fees and before share
    /// rounding, in loan token base units. Ignored by this preview.
    /// @param maxCrossedOrders Maximum number of borrow-side orders crossed, including skipped and invalidated
    /// orders.
    /// @param account Address whose own orders are excluded from matching.
    /// @return collectedLoan Loan claim produced, net of protocol fees and before share rounding, in loan token
    /// base units.
    /// @return consumedAssets Assets consumed by matching, in loan token base units.
    /// @return crossedOrders Number of borrow-side orders crossed, including skipped and invalidated orders.
    function previewProvideExactIn(uint64 market, uint128 assetsAmount, uint128 minLoanAmount, uint16 maxCrossedOrders, address account) external view returns (uint128 collectedLoan, uint128 consumedAssets, uint16 crossedOrders);

    /// @notice Provides assets for a target loan claim by matching against existing borrow or reloan orders.
    /// @dev Callable by account or a delegate approved for DELEGATE_PROVIDE. Requires an active market and skips
    /// account's own orders. Reverts unless the target is reached. Unused assets stay in the pool balance.
    /// @param account Address of the lender funding the operation and receiving the loan shares.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param maxAssetsAmount Maximum assets to spend from the pool balance, in loan token base units.
    /// @param loanAmount Target loan claim, net of protocol fees and before share rounding, in loan token base
    /// units.
    /// @param maxCrossedOrders Maximum number of borrow-side orders crossed, including skipped and invalidated
    /// orders.
    function provideExactOut(address account, uint64 market, uint128 maxAssetsAmount, uint128 loanAmount, uint16 maxCrossedOrders) external;

    /// @notice Previews providing assets for a target loan claim by matching against existing borrow or reloan orders.
    /// @dev Requires an active market. May return a partial result when liquidity or the crossing limit is
    /// insufficient. Does not check the account's pool balance or authorization.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param maxAssetsAmount Maximum assets to match, in loan token base units.
    /// @param loanAmount Target loan claim, net of protocol fees and before share rounding, in loan token base
    /// units.
    /// @param maxCrossedOrders Maximum number of borrow-side orders crossed, including skipped and invalidated
    /// orders.
    /// @param account Address whose own orders are excluded from matching.
    /// @return collectedLoan Loan claim produced, net of protocol fees and before share rounding, in loan token
    /// base units.
    /// @return consumedAssets Assets consumed by matching, in loan token base units.
    /// @return crossedOrders Number of borrow-side orders crossed, including skipped and invalidated orders.
    function previewProvideExactOut(uint64 market, uint128 maxAssetsAmount, uint128 loanAmount, uint16 maxCrossedOrders, address account) external view returns (uint128 collectedLoan, uint128 consumedAssets, uint16 crossedOrders);

    /// @notice Borrows an exact asset amount by matching against existing provide orders.
    /// @dev Callable by account or a delegate approved for DELEGATE_BORROW.
    /// Requires an active market and full execution. The resulting loan-to-value must not exceed borrow LTV, the
    /// maximum allowed for borrowing. Skips account's own provide orders.
    /// @param account Address whose debt increases and pool balance receives the borrowed assets.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Assets to borrow, in loan token base units.
    /// @param maxDebt Maximum new debt including fixed-term interest, in loan token base units.
    function borrow(address account, uint64 market, uint128 amount, uint128 maxDebt) external;

    /// @notice Previews the assets borrowed and debt incurred by matching against existing provide orders.
    /// @dev Requires an active market but does not check collateral, authorization or a maximum debt. May return
    /// less than amount when liquidity is insufficient.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Requested assets, in loan token base units.
    /// @param borrower Address whose own provide orders are excluded from matching.
    /// @return borrowed Assets obtainable from matching, in loan token base units.
    /// @return debt New debt including fixed-term interest, in loan token base units.
    function previewBorrow(uint64 market, uint128 amount, address borrower) external view returns (uint128 borrowed, uint128 debt);

    /// @notice Refinances matured debt into active markets and redistributes its collateral.
    /// @dev Callable by account or a delegate approved for DELEGATE_BORROW, DELEGATE_REPAY and
    /// DELEGATE_MOVE_COLLATERAL. Excess borrowed assets credit account's pool balance. Repeated destinations are
    /// allowed. An empty array performs no refinancing. The loan-to-value of each resulting position must not
    /// exceed borrow LTV, the maximum allowed for borrowing.
    /// Collateral is apportioned by new debt, with any rounding remainder assigned to the last entry.
    /// @param account Address of the borrower whose debt and collateral are moved.
    /// @param fromMarket Matured source-market timestamp, in Unix seconds.
    /// @param maxDebtFactor Maximum proportional increase of total new debt over total repaid debt, where 1e18
    /// permits a 100% increase.
    /// @param refinances Destination operations in execution order. Each entry contains:
    /// - toMarket: Active destination maturity timestamp, in Unix seconds, different from fromMarket.
    /// - debtToRepay: Source debt to repay, in loan token base units.
    /// - assetsToBorrow: Assets to borrow, in loan token base units. Must be at least debtToRepay.
    /// @return results Results in input order. Each entry contains:
    /// - newDebt: Debt created in the destination market, including fixed-term interest, in loan token base units.
    /// - collateralMoved: Collateral moved from the source to the destination market, in collateral token base units.
    function refinanceDebts(address account, uint64 fromMarket, uint256 maxDebtFactor, RefinanceDebtParams[] calldata refinances) external returns (RefinanceDebtResult[] memory results);

    /// @notice Exchanges an existing loan claim for assets by matching against existing provide orders.
    /// @dev Callable by account or a delegate approved for DELEGATE_RELOAN.
    /// Requires an active market and full execution. Skips account's own provide orders and reconciles its reloan
    /// order afterward.
    /// @param account Address whose loan shares are consumed and pool balance receives the assets.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Loan claim to exchange, in loan token base units. type(uint128).max exchanges the full claim.
    /// @param minAssets Minimum assets to receive in the pool balance, in loan token base units.
    function reloan(address account, uint64 market, uint128 amount, uint128 minAssets) external;

    /// @notice Previews exchanging an existing loan claim for assets by matching against existing provide orders.
    /// @dev Requires an active market but does not check loan ownership, authorization or minimum proceeds. May
    /// return a partial result when liquidity is insufficient.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Loan claim to match, in loan token base units. type(uint128).max is treated as an explicit
    /// amount, not as the account's full claim.
    /// @param account Address whose own provide orders are excluded from matching.
    /// @return Loan claim consumed by matching, in loan token base units.
    /// @return Assets obtainable from matching, in loan token base units.
    function previewReloan(uint64 market, uint128 amount, address account) external view returns (uint128, uint128);

    /// @notice Matches overlapping provide, borrow and reloan orders and credits the residual profit to an account.
    /// @dev Restricted to active markets only. No assets are required from the caller. Zero profit is allowed.
    /// The aggregate Borrowed and Provided events do not create personal
    /// debt or loan claims for the account.
    /// @param account Address receiving the reward in its pool balance, which may differ from the caller.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param amount Exact assets to borrow from provide orders, in loan token base units.
    /// @param maxCrossedOrders Maximum number of crossed provide orders, including skipped and invalidated
    /// orders.
    function sweep(address account, uint64 market, uint128 amount, uint16 maxCrossedOrders) external;

    /// @notice Returns an account's health factor calculated using liquidation LTV.
    /// @dev Computed as liquidation LTV times collateral value divided by debt, rounded down. Does not reflect
    /// liquidation eligibility after the grace period.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param account Address of the borrower.
    /// @return Health factor scaled by 1e18. Values below 1e18 are unhealthy. Returns 1e18 when debt is zero.
    function getHealthFactor(uint64 market, address account) external view returns (uint256);

    /// @notice Returns whether an account's debt meets the liquidation eligibility conditions.
    /// @dev Eligibility does not guarantee successful liquidation. Collateral and the execution parameters are
    /// checked separately.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param account Address of the borrower.
    /// @return True if debt is nonzero and either the health factor based on liquidation LTV is below 1e18 or the
    /// grace period after maturity has ended.
    function isLiquidatable(uint64 market, address account) external view returns (bool);

    /// @notice Executes a sequence of calls to the pool atomically.
    /// @dev Preserves the original caller and reverts the entire batch if any call fails. Price-dependent calls
    /// share the first cached oracle price within the batch.
    /// @param data ABI-encoded pool calls in execution order.
    /// @return results ABI-encoded return data for each call, in input order.
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);
}
