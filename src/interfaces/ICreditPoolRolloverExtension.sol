// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { ICreditPoolExtension } from "src/interfaces/ICreditPoolExtension.sol";

interface ICreditPoolRolloverExtension is ICreditPoolExtension {
    struct ReborrowSolution {
        uint64 market;
        uint256 debtPercent;
    }

    struct RolloverSolution {
        ReborrowSolution[] reborrows;
    }

    struct RolloverConfig {
        bool enabled;
        uint256 maxDebtFactor;
        uint256 keeperFee;
    }

    /// @notice Emitted when a borrower enables, updates or disables rollover for a source market.
    /// @dev The permitted proportional debt increase rises from zero at maturity to newMaxDebtFactor over the grace
    /// period.
    /// A zero grace period applies the full configured limit immediately.
    /// @param pool Address of the credit pool.
    /// @param account Address of the borrower configuring rollover for the source-market position.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param enabled Whether keepers are authorized to execute rollover for this position.
    /// @param newMaxDebtFactor Maximum proportional increase in refinanced debt, where 1e18 represents a 100% increase.
    /// @param newKeeperFee Keeper fee rate applied to debt covered, where 1e18 represents 100%.
    event RolloverConfigUpdated(address indexed pool, address indexed account, uint64 indexed market, bool enabled, uint256 newMaxDebtFactor, uint256 newKeeperFee);

    /// @notice Emitted when rollover repays source-market debt using the borrower's loan claim in the same
    /// market.
    /// @dev Part of the loan claim is redeemed into the borrower's pool balance to fund the keeper fee.
    /// The fee is collected at the end of rollover and may round to zero.
    /// @param pool Address of the credit pool.
    /// @param account Address of the borrower whose loan claim is used to repay debt in the same market.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param debtRepaid Amount of source-market debt repaid using the borrower's loan claim, in loan token
    /// base units.
    /// @param fee Keeper fee funded by redeeming part of the borrower's loan claim, in loan token base units.
    event DebtCoveredWithLoan(address indexed pool, address indexed account, uint64 indexed market, uint128 debtRepaid, uint128 fee);

    /// @notice Emitted when rollover repays source-market debt using the borrower's pool balance.
    /// @dev The keeper fee is reserved from the same pool balance for collection at the end of rollover.
    /// @param pool Address of the credit pool.
    /// @param account Address of the borrower whose pool balance funds the debt repayment and keeper fee.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param debtRepaid Amount of source-market debt repaid using the borrower's pool balance, in loan token base
    /// units.
    /// @param fee Keeper fee reserved from the borrower's pool balance, in loan token base units.
    event DebtCoveredFromPoolBalance(address indexed pool, address indexed account, uint64 indexed market, uint128 debtRepaid, uint128 fee);

    /// @notice Emitted when rollover repays source-market debt using assets transferred from the borrower via Permit2.
    /// @dev The transfer amount equals debtRepaid + fee. The fee remains in the borrower's pool balance until
    /// collection.
    /// @param pool Address of the credit pool.
    /// @param account Address of the borrower supplying tokens via Permit2 to fund the debt repayment and keeper fee.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param debtRepaid Amount of source-market debt repaid using the Permit2 transfer, in loan token base units.
    /// @param fee Keeper fee funded by the Permit2 transfer, in loan token base units.
    event DebtCoveredFromAccountTransfer(address indexed pool, address indexed account, uint64 indexed market, uint128 debtRepaid, uint128 fee);

    /// @notice Emitted each time source-market debt is refinanced by borrowing in an active destination market
    /// during rollover.
    /// @dev Describes the same repayment as the pool's DebtRefinanced event. All pool refinancing events precede these
    /// extension events. Assets borrowed in the destination market equal debtRepaid + fee, financing the keeper fee.
    /// @param pool Address of the credit pool.
    /// @param account Address of the borrower who owns the source and destination debt and collateral positions.
    /// @param fromMarket Source market maturity timestamp, in Unix seconds.
    /// @param toMarket Destination market maturity timestamp, in Unix seconds.
    /// @param debtRepaid Amount of source-market debt repaid by this refinancing leg, in loan token base units.
    /// @param newDebt Debt created in the destination market, including the interest, in loan token base units.
    /// @param collateralMoved Amount of collateral transferred to the destination market, in collateral token base
    /// units.
    /// @param fee Keeper fee financed by borrowing in the destination market, in loan token base units.
    event DebtRolledOver(address indexed pool, address indexed account, uint64 indexed fromMarket, uint64 toMarket, uint128 debtRepaid, uint128 newDebt, uint128 collateralMoved, uint128 fee);

    /// @notice Emitted once a rollover has reduced source-market debt and completed keeper fee collection.
    /// @dev The debtRepaid and fee amounts aggregate all preceding coverage and refinancing steps of the same
    /// rollover. No event is emitted if debt is unchanged. A debt reduction is reported even when the total fee
    /// rounds to zero. Collected fees remain in the extension until withdrawal, which is recorded in FeeWithdrawn.
    /// @param pool Address of the credit pool.
    /// @param account Address of the borrower whose source-market debt is reduced by the rollover.
    /// @param keeper Address of the caller executing rollover, which may differ from feeRecipient.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param feeRecipient Address of the account credited with the collected keeper fee in this extension.
    /// @param debtRepaid Total source-market debt repaid across all coverage and refinancing steps, in loan token base
    /// units.
    /// @param remainingDebt Amount of debt remaining in the source market after rollover, in loan token base units.
    /// @param fee Total keeper fee collected and credited to feeRecipient in this extension, in loan token base units.
    event RolloverExecuted(address indexed pool, address indexed account, address indexed keeper, uint64 market, address feeRecipient, uint128 debtRepaid, uint128 remainingDebt, uint128 fee);

    /// @notice Emitted when a keeper fee is collected from the pool and credited to the recipient's fee balance.
    /// @dev Collection debits the borrower's pool balance and transfers tokens to this extension.
    /// The recipient may differ from the rollover caller. Tokens remain in the extension until withdrawn through
    /// withdrawFee.
    /// @param token Address of the token in which the keeper fee is denominated.
    /// @param recipient Address credited with the keeper fee and entitled to withdraw it.
    /// @param amount Amount credited to the recipient's collected-fee balance, in fee token base units.
    event FeeCollected(address indexed token, address indexed recipient, uint128 amount);

    /// @notice Emitted when collected fees are withdrawn from the recipient's fee balance to an address.
    /// @dev The caller is the owner of the collected-fee balance identified by recipient. The to address may specify
    /// another address.
    /// @param token Address of the token in which the keeper fee is denominated.
    /// @param recipient Address of the caller whose collected-fee balance is debited.
    /// @param to Address receiving the withdrawn fee tokens, which may differ from recipient.
    /// @param amount Amount withdrawn, in fee token base units.
    event FeeWithdrawn(address indexed token, address indexed recipient, address indexed to, uint128 amount);

    error RolloverDisabled(address pool, address borrower, uint64 market);
    error MaxRolloverFactorExceeded(uint256 factor, uint256 maxFactor);
    error RolloverDebtPercentExceeded(uint256 totalPercent, uint256 maxPercent);
    error InvalidKeeperFee(uint256 fee);
    error KeeperFeeTooHigh(uint256 maxKeeperFee, uint256 keeperFee);
    error InvalidPermit2(address permit2);
    error InvalidFactory(address factory);
    error InvalidPool(address pool);
    error InvalidFeeRecipient(address feeRecipient);
    error InvalidWithdrawalRecipient(address to);
    error InvalidFeeAmount(uint256 amount, uint256 available);
    error TokenReceiptMismatch(address token, uint256 expected, uint256 received);

    /// @notice Returns an account's rollover settings for a market.
    /// @param pool Address of the credit pool.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param account Address of the borrower.
    /// @return enabled Whether keepers may execute rollover for this position.
    /// @return maxDebtFactor Maximum proportional increase in refinanced debt, where 1e18 represents a 100%
    /// increase.
    /// @return keeperFee Fee rate applied to debt covered, where 1e18 represents 100%.
    function getRolloverConfig(address pool, uint64 market, address account) external view returns (bool enabled, uint256 maxDebtFactor, uint256 keeperFee);

    /// @notice Sets the caller's rollover settings for a market.
    /// @dev The allowed debt increase rises from zero at maturity to maxDebtFactor over the market's grace period.
    /// A zero grace period applies the full limit immediately.
    /// Enabling rollover does not grant pool delegation or token allowances, and these must be configured separately.
    /// @param pool Address of the credit pool.
    /// @param market Market maturity timestamp, in Unix seconds.
    /// @param enabled Whether keepers may execute rollover for this position.
    /// @param maxDebtFactor Maximum proportional increase in refinanced debt, where 1e18 represents a 100%
    /// increase.
    /// @param keeperFee Fee rate applied to debt covered, where 1e18 represents 100%. When enabled, must be between
    /// 1e13 and 1e18 inclusive.
    function setRolloverConfig(address pool, uint64 market, bool enabled, uint256 maxDebtFactor, uint256 keeperFee) external;

    /// @notice Reduces matured debt using the borrower's available funds and optional refinancing.
    /// @dev Permissionless when enabled. Uses the source-market loan claim, pool balance, Permit2-approved wallet
    /// funds, then the supplied refinancing instructions, in that order. The reborrow fractions must sum to at most
    /// 1e18. A smaller total may leave debt outstanding.
    /// @param pool Address of the credit pool.
    /// @param market Matured source-market timestamp, in Unix seconds.
    /// @param account Address of the borrower with rollover enabled.
    /// @param feeRecipient Recipient of the keeper fee in this extension.
    /// @param minKeeperFee Minimum acceptable keeper fee rate, where 1e18 represents 100%.
    /// @param solution Refinancing instructions. Each entry in the reborrows array contains:
    /// - market: Destination market's maturity timestamp, in Unix seconds.
    /// - debtPercent: Fraction of debt remaining after the funding steps that should be refinanced through the destination market,
    ///  where 1e18 represents 100%.
    function rollover(address pool, uint64 market, address account, address feeRecipient, uint256 minKeeperFee, RolloverSolution calldata solution) external;

    /// @notice Withdraws the caller's fees to a recipient.
    /// @dev When amount is type(uint128).max, the full collected balance is withdrawn.
    /// @param token Address of the fee token.
    /// @param to Address receiving the fee tokens.
    /// @param amount Fees to withdraw, in token base units.
    function withdrawFee(address token, address to, uint128 amount) external;

    /// @notice Returns recipient's fees available for withdrawal.
    /// @param token Address of the fee token.
    /// @param recipient Address of the fee's owner.
    /// @return Collected fee balance, in token base units.
    function getCollectedFee(address token, address recipient) external view returns (uint128);
}
