// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import { SafeCast } from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import { IPermit2 } from "lib/permit2/src/interfaces/IPermit2.sol";

import { ICreditPool, ICreditPoolExplorerAPI, ICreditPoolConstants, ICreditPoolTypes } from "src/interfaces/ICreditPool.sol";
import { ICreditPoolFactory } from "src/interfaces/ICreditPoolFactory.sol";
import { ICreditPoolRolloverExtension } from "src/interfaces/ICreditPoolRolloverExtension.sol";

contract CreditPoolRolloverExtension is ICreditPoolRolloverExtension, ICreditPoolConstants, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    error ActiveMarket(uint64 market);

    IPermit2 public immutable PERMIT2;
    ICreditPoolFactory public immutable FACTORY;

    mapping(address pool => mapping(address account => mapping(uint64 market => RolloverConfig))) private _configs;
    mapping(address token => mapping(address recipient => uint128 amount)) private _collectedFee;

    struct RolloverState {
        uint128 remainingDebt;
        uint128 totalDebt;
        uint128 totalFee;
    }

    constructor(IPermit2 permit2, ICreditPoolFactory factory) {
        if (address(permit2) == address(0) || address(permit2).code.length == 0) {
            revert InvalidPermit2(address(permit2));
        }
        if (address(factory) == address(0) || address(factory).code.length == 0) {
            revert InvalidFactory(address(factory));
        }

        PERMIT2 = permit2;
        FACTORY = factory;
    }

    function requiredActions() external pure override returns (uint256) {
        return DELEGATE_CLAIM
            | DELEGATE_REPAY
            | DELEGATE_OFFSET
            | DELEGATE_WITHDRAW
            | DELEGATE_BORROW
            | DELEGATE_MOVE_COLLATERAL;
    }

    function description() external pure override returns (string memory) {
        return "CreditPool rollover extension";
    }

    function getRolloverConfig(address pool, uint64 market, address account)
        external
        view
        override
        returns (bool enabled, uint256 maxDebtFactor, uint256 keeperFee)
    {
        RolloverConfig storage config = _configs[pool][account][market];
        return (config.enabled, config.maxDebtFactor, config.keeperFee);
    }

    function setRolloverConfig(address pool, uint64 market, bool enabled, uint256 maxDebtFactor, uint256 keeperFee) external override {
        _requirePool(pool);
        if (enabled) _checkKeeperFee(keeperFee);

        _configs[pool][msg.sender][market] = RolloverConfig({
            enabled: enabled,
            maxDebtFactor: maxDebtFactor,
            keeperFee: keeperFee
        });

        emit RolloverConfigUpdated(pool, msg.sender, market, enabled, maxDebtFactor, keeperFee);
    }

    function rollover(
        address pool,
        uint64 market,
        address account,
        address feeRecipient,
        uint256 minKeeperFee,
        RolloverSolution calldata solution
    )
        external
        override
        nonReentrant
    {
        _requirePool(pool);
        if (feeRecipient == address(0)) revert InvalidFeeRecipient(feeRecipient);

        RolloverConfig memory config = _configs[pool][account][market];
        if (!config.enabled) revert RolloverDisabled(pool, account, market);
        if (config.keeperFee < minKeeperFee) revert KeeperFeeTooHigh(config.keeperFee, minKeeperFee);
        if (block.timestamp < market) revert ActiveMarket(market);

        ICreditPool creditPool = ICreditPool(pool);
        IERC20 asset = IERC20(creditPool.asset());
        RolloverState memory state;
        state.remainingDebt = creditPool.debtOf(market, account);

        if (state.remainingDebt > 0) {
            _coverWithLoan(creditPool, market, account, config.keeperFee, state);
        }
        if (state.remainingDebt > 0) {
            _coverFromPoolBalance(creditPool, market, account, config.keeperFee, state);
        }
        if (state.remainingDebt > 0) {
            _coverFromAccount(creditPool, asset, market, account, config.keeperFee, state);
        }
        if (state.remainingDebt > 0) {
            _refinance(creditPool, market, account, config.maxDebtFactor, config.keeperFee, solution, state);
        }
        if (state.totalDebt == 0) return;

        _withdrawAndCollectFee(creditPool, asset, account, feeRecipient, state.totalFee);
        emit RolloverExecuted(pool, account, msg.sender, market, feeRecipient, state.totalDebt, state.remainingDebt, state.totalFee);
    }

    function withdrawFee(address token, address to, uint128 amount) external override nonReentrant {
        if (to == address(0)) revert InvalidWithdrawalRecipient(to);

        uint128 available = _collectedFee[token][msg.sender];
        if (amount == type(uint128).max) amount = available;
        if (amount == 0 || amount > available) revert InvalidFeeAmount(amount, available);

        _collectedFee[token][msg.sender] = available - amount;
        IERC20(token).safeTransfer(to, amount);

        emit FeeWithdrawn(token, msg.sender, to, amount);
    }

    function getCollectedFee(address token, address recipient) external view override returns (uint128) {
        return _collectedFee[token][recipient];
    }

    function _coverWithLoan(
        ICreditPool creditPool,
        uint64 market,
        address account,
        uint256 keeperFee,
        RolloverState memory state
    )
        private
    {
        uint128 loan = creditPool.loanOf(market, account);
        uint128 marketBalance = ICreditPoolExplorerAPI(address(creditPool)).getMarketBalance(market);
        uint256 maxMoveRaw = Math.mulDiv(marketBalance, UNIT + keeperFee, keeperFee, Math.Rounding.Floor);
        if (maxMoveRaw > loan) maxMoveRaw = loan;
        if (maxMoveRaw > type(uint128).max) maxMoveRaw = type(uint128).max;

        (uint128 move, uint128 debt, uint128 fee) = _cover(state.remainingDebt, maxMoveRaw.toUint128(), keeperFee);
        if (move == 0) return;

        creditPool.offset(account, market, debt);
        if (fee > 0) creditPool.claim(account, market, fee);
        _recordCover(state, debt, fee);

        emit DebtCoveredWithLoan(address(creditPool), account, market, debt, fee);
    }

    function _coverFromPoolBalance(
        ICreditPool creditPool,
        uint64 market,
        address account,
        uint256 keeperFee,
        RolloverState memory state
    )
        private
    {
        uint128 balance = creditPool.balanceOf(account);
        uint128 available = balance > state.totalFee ? balance - state.totalFee : 0;
        (uint128 move, uint128 debt, uint128 fee) = _cover(state.remainingDebt, available, keeperFee);
        if (move == 0) return;

        creditPool.repay(account, account, market, debt);
        _recordCover(state, debt, fee);

        emit DebtCoveredFromPoolBalance(address(creditPool), account, market, debt, fee);
    }

    function _coverFromAccount(
        ICreditPool creditPool,
        IERC20 asset,
        uint64 market,
        address account,
        uint256 keeperFee,
        RolloverState memory state
    )
        private
    {
        (uint128 move, uint128 debt, uint128 fee) =
            _cover(state.remainingDebt, _accountTransferCapacity(asset, account), keeperFee);
        if (move == 0) return;

        _transferAndDeposit(creditPool, asset, account, move);
        creditPool.repay(account, account, market, debt);
        _recordCover(state, debt, fee);

        emit DebtCoveredFromAccountTransfer(address(creditPool), account, market, debt, fee);
    }

    function _accountTransferCapacity(IERC20 asset, address account) private view returns (uint128) {
        uint256 walletBalance = asset.balanceOf(account);
        (uint256 allowance, uint256 expiration,) = PERMIT2.allowance(account, address(asset), address(this));
        if (expiration <= block.timestamp) allowance = 0;

        uint256 capacity = Math.min(walletBalance, allowance);
        return capacity > type(uint128).max ? type(uint128).max : capacity.toUint128();
    }

    function _transferAndDeposit(ICreditPool creditPool, IERC20 asset, address account, uint128 amount) private {
        uint256 balanceBefore = asset.balanceOf(address(this));
        PERMIT2.transferFrom(account, address(this), amount, address(asset));
        _requireTokenReceipt(asset, balanceBefore, amount);
        asset.safeIncreaseAllowance(address(creditPool), amount);
        creditPool.deposit(account, amount);
    }

    function _refinance(
        ICreditPool creditPool,
        uint64 market,
        address account,
        uint256 maxDebtFactor,
        uint256 keeperFee,
        RolloverSolution calldata solution,
        RolloverState memory state
    )
        private
    {
        if (solution.reborrows.length == 0) return;

        ICreditPoolTypes.RefinanceDebtParams[] memory refinances =
            new ICreditPoolTypes.RefinanceDebtParams[](solution.reborrows.length);
        uint128 savedRemainingDebt = state.remainingDebt;
        uint256 totalDebtPercent;

        for (uint256 i = 0; i < solution.reborrows.length; i++) {
            ReborrowSolution calldata reborrow = solution.reborrows[i];
            totalDebtPercent += reborrow.debtPercent;
            if (totalDebtPercent > UNIT) revert RolloverDebtPercentExceeded(totalDebtPercent, UNIT);

            uint128 debt = i == solution.reborrows.length - 1 && totalDebtPercent == UNIT
                ? state.remainingDebt
                : Math.mulDiv(savedRemainingDebt, reborrow.debtPercent, UNIT, Math.Rounding.Floor).toUint128();
            uint128 fee = Math.mulDiv(debt, keeperFee, UNIT, Math.Rounding.Ceil).toUint128();

            refinances[i] = ICreditPoolTypes.RefinanceDebtParams({
                toMarket: reborrow.market,
                debtToRepay: debt,
                assetsToBorrow: (uint256(debt) + fee).toUint128()
            });

            _recordCover(state, debt, fee);
        }

        uint256 currentMaxDebtFactor = _currentFactorFor(creditPool, market, maxDebtFactor);
        ICreditPoolTypes.RefinanceDebtResult[] memory results =
            creditPool.refinanceDebts(account, market, currentMaxDebtFactor, refinances);

        for (uint256 i = 0; i < refinances.length; i++) {
            _emitDebtRolledOver(address(creditPool), account, market, refinances[i], results[i]);
        }
    }

    function _emitDebtRolledOver(
        address pool,
        address account,
        uint64 fromMarket,
        ICreditPoolTypes.RefinanceDebtParams memory refinance,
        ICreditPoolTypes.RefinanceDebtResult memory result
    )
        private
    {
        emit DebtRolledOver(
            pool,
            account,
            fromMarket,
            refinance.toMarket,
            refinance.debtToRepay,
            result.newDebt,
            result.collateralMoved,
            refinance.assetsToBorrow - refinance.debtToRepay
        );
    }

    function _cover(uint128 remainingDebt, uint128 maxMove, uint256 keeperFee)
        private
        pure
        returns (uint128 move, uint128 debt, uint128 fee)
    {
        uint256 moveRaw = Math.mulDiv(remainingDebt, UNIT + keeperFee, UNIT, Math.Rounding.Floor);
        if (moveRaw > maxMove) moveRaw = maxMove;
        if (moveRaw == 0) return (0, 0, 0);

        move = moveRaw.toUint128();
        debt = Math.mulDiv(move, UNIT, UNIT + keeperFee, Math.Rounding.Ceil).toUint128();
        fee = move - debt;
    }

    function _recordCover(RolloverState memory state, uint128 debt, uint128 fee) private pure {
        state.remainingDebt -= debt;
        state.totalDebt += debt;
        state.totalFee += fee;
    }

    function _withdrawAndCollectFee(ICreditPool creditPool, IERC20 asset, address account, address feeRecipient, uint128 fee) private {
        if (fee == 0) return;

        uint256 balanceBefore = asset.balanceOf(address(this));
        creditPool.withdraw(account, address(this), fee);
        _requireTokenReceipt(asset, balanceBefore, fee);
        _collectedFee[address(asset)][feeRecipient] += fee;

        emit FeeCollected(address(asset), feeRecipient, fee);
    }

    function _requirePool(address pool) private view {
        if (pool == address(0) || pool.code.length == 0 || !FACTORY.isPool(pool)) revert InvalidPool(pool);
    }

    function _requireTokenReceipt(IERC20 token, uint256 balanceBefore, uint256 expected) private view {
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != expected) revert TokenReceiptMismatch(address(token), expected, received);
    }

    function _currentFactorFor(ICreditPool creditPool, uint64 market, uint256 maxDebtFactor) private view returns (uint256) {
        uint256 gracePeriod = creditPool.getLiquidationGracePeriod(market);
        if (gracePeriod == 0) return maxDebtFactor;

        uint256 elapsed = block.timestamp > market ? block.timestamp - market : 0;
        if (elapsed >= gracePeriod) return maxDebtFactor;

        return Math.mulDiv(maxDebtFactor, elapsed, gracePeriod, Math.Rounding.Ceil);
    }

    function _checkKeeperFee(uint256 fee) private pure {
        if (fee < UNIT / 100000 || fee > UNIT) revert InvalidKeeperFee(fee);
    }
}
