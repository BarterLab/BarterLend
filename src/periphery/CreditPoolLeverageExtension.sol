// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import {ICreditPool, ICreditPoolConstants} from "src/interfaces/ICreditPool.sol";
import {ICreditPoolExtension} from "src/interfaces/ICreditPoolExtension.sol";
import {ICreditPoolFactory} from "src/interfaces/ICreditPoolFactory.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";

interface IMorphoFlashLender {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

struct LeverageSwapCall {
    address target;
    address spender;
    bytes data;
}

contract CreditPoolLeverageExtension is ICreditPoolExtension, ICreditPoolConstants, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct LeverageParams {
        ICreditPoolFactory factory;
        ICreditPool pool;
        IMorphoFlashLender flashLender;
        uint64 market;
        uint256 leverage;
        uint128 collateralIn;
        uint128 flashAmount;
        uint128 minCollateralOut;
        uint128 maxDebt;
        uint256 minHealthFactor;
        uint256 deadline;
    }

    struct RepayParams {
        ICreditPoolFactory factory;
        ICreditPool pool;
        IMorphoFlashLender flashLender;
        uint64 market;
        uint128 debtToRepay;
        uint256 minHealthFactor;
        uint256 deadline;
    }

    enum Operation {
        Leverage,
        Deleverage,
        ReducePosition
    }

    struct FlashLoanContext {
        ICreditPool pool;
        uint64 market;
        uint128 flashAmount;
        address account;
        IERC20 asset;
        IERC20 collateral;
        uint256 assetBefore;
        uint256 collateralBefore;
    }

    struct LeverageAmounts {
        uint128 collateralIn;
        uint128 minCollateralOut;
        uint128 maxDebt;
    }

    struct RepayAmounts {
        uint128 collateralToWithdraw;
        uint128 maxCollateralIn;
        uint128 minCollateralOut;
    }

    mapping(ICreditPoolFactory factory => bool allowed) public isFactoryAllowed;
    LeverageSwapExecutor public immutable swapExecutor;
    bytes32 private transient _expectedCallback;

    error EmptyFactoryAllowlist();
    error InvalidFactory(address factory);
    error InvalidPool(address pool);
    error Expired();
    error InvalidPositionParams();
    error InvalidOraclePrice();
    error FlashAmountExceedsLeverage();
    error UnexpectedFlashLoanCallback();
    error MissingFlashLoanCallback();
    error BalanceMismatch(address token, uint256 expected, uint256 actual);
    error InsufficientCollateralOut(uint256 minimum, uint256 actual);
    error InsufficientHealthFactor(uint256 minimum, uint256 actual);
    error LeverageNotReduced();
    error InvalidProportionalWithdrawal(uint128 expected, uint128 actual);
    error UnexpectedPositionAfterRepayment();

    constructor(ICreditPoolFactory[] memory factories) {
        if (factories.length == 0) revert EmptyFactoryAllowlist();
        for (uint256 i = 0; i < factories.length; ++i) {
            ICreditPoolFactory factory = factories[i];
            if (address(factory).code.length == 0) revert InvalidFactory(address(factory));
            isFactoryAllowed[factory] = true;
        }
        swapExecutor = new LeverageSwapExecutor();

    }

    function requiredActions() external pure override returns (uint256) {
        return DELEGATE_BORROW | DELEGATE_WITHDRAW | DELEGATE_WITHDRAW_COLLATERAL;
    }

    function description() external pure override returns (string memory) {
        return "CreditPool leverage extension";
    }

    function leverage(LeverageParams calldata params, LeverageSwapCall calldata swap) external nonReentrant {
        _validateLeverage(params);

        FlashLoanContext memory context = _flashLoanContext(params.pool, params.market, params.flashAmount);
        context.collateral.safeTransferFrom(msg.sender, address(this), params.collateralIn);
        _requireBalance(context.collateral, address(this), context.collateralBefore + params.collateralIn);

        LeverageAmounts memory amounts = LeverageAmounts(params.collateralIn, params.minCollateralOut, params.maxDebt);
        _flashLoan(context, params.flashLender, Operation.Leverage, swap, abi.encode(amounts));
        _requireHealthFactor(context, params.minHealthFactor);
    }

    function deleverage(RepayParams calldata params, uint128 maxCollateralIn, LeverageSwapCall calldata swap)
        external nonReentrant
    {
        _validatePool(params.factory, params.pool, params.deadline);
        uint128 debtBefore = params.pool.debtOf(params.market, msg.sender);
        if (params.debtToRepay == 0 || params.debtToRepay > debtBefore || maxCollateralIn == 0)
            revert InvalidPositionParams();
        uint128 collateralBefore = params.pool.collateralOf(params.market, msg.sender);

        FlashLoanContext memory context = _flashLoanContext(params.pool, params.market, params.debtToRepay);
        RepayAmounts memory amounts = RepayAmounts(maxCollateralIn, maxCollateralIn, 0);
        _flashLoan(context, params.flashLender, Operation.Deleverage, swap, abi.encode(amounts));

        uint128 debtAfter = params.pool.debtOf(params.market, msg.sender);
        if (debtAfter != 0) {
            uint128 collateralAfter = params.pool.collateralOf(params.market, msg.sender);
            // Compare both positions at the same collateral price.
            if (uint256(debtAfter) * collateralBefore >= uint256(debtBefore) * collateralAfter)
                revert LeverageNotReduced();
        }
        _requireHealthFactor(context, params.minHealthFactor);
    }

    function reducePosition(
        RepayParams calldata params,
        uint128 collateralToWithdraw,
        uint128 minCollateralOut,
        LeverageSwapCall calldata swap
    ) external nonReentrant {
        _validatePool(params.factory, params.pool, params.deadline);
        uint128 debtBefore = params.pool.debtOf(params.market, msg.sender);
        if (params.debtToRepay == 0 || params.debtToRepay >= debtBefore || minCollateralOut == 0 ||
            minCollateralOut >= collateralToWithdraw)
            revert InvalidPositionParams();
        uint128 collateralBefore = params.pool.collateralOf(params.market, msg.sender);
        // Round the proportional withdrawal down so rounding cannot increase LTV.
        uint128 proportionalCollateral = (uint256(collateralBefore) * params.debtToRepay / debtBefore).toUint128();
        if (collateralToWithdraw != proportionalCollateral)
            revert InvalidProportionalWithdrawal(proportionalCollateral, collateralToWithdraw);

        FlashLoanContext memory context = _flashLoanContext(params.pool, params.market, params.debtToRepay);
        RepayAmounts memory amounts = RepayAmounts(
            collateralToWithdraw, collateralToWithdraw - minCollateralOut, minCollateralOut
        );
        _flashLoan(context, params.flashLender, Operation.ReducePosition, swap, abi.encode(amounts));

        if (params.pool.debtOf(params.market, msg.sender) != debtBefore - params.debtToRepay ||
            params.pool.collateralOf(params.market, msg.sender) != collateralBefore - collateralToWithdraw)
            revert UnexpectedPositionAfterRepayment();
        _requireHealthFactor(context, params.minHealthFactor);
    }

    function onMorphoFlashLoan(uint256 amount, bytes calldata data) external {
        bytes32 expected = _expectedCallback;
        if (expected == bytes32(0) || expected != keccak256(abi.encode(msg.sender, amount, keccak256(data))))
            revert UnexpectedFlashLoanCallback();
        _expectedCallback = bytes32(0);

        (Operation operation, FlashLoanContext memory context, LeverageSwapCall memory swap, bytes memory amounts) =
            abi.decode(data, (Operation, FlashLoanContext, LeverageSwapCall, bytes));
        _requireBalance(context.asset, address(this), context.assetBefore + amount);

        if (operation == Operation.Leverage) {
            _executeLeverage(context, abi.decode(amounts, (LeverageAmounts)), swap);
        } else {
            _executeRepayment(context, abi.decode(amounts, (RepayAmounts)), swap, operation == Operation.ReducePosition);
        }

        _requireBalance(context.asset, address(this), context.assetBefore + amount);
        context.asset.forceApprove(msg.sender, amount);
    }

    function _flashLoanContext(ICreditPool pool, uint64 market, uint128 flashAmount)
        private view returns (FlashLoanContext memory)
    {
        IERC20 asset = IERC20(pool.asset());
        IERC20 collateral = IERC20(pool.collateral());
        if (asset == collateral) revert InvalidPositionParams();

        return FlashLoanContext({
            pool: pool,
            market: market,
            flashAmount: flashAmount,
            account: msg.sender,
            asset: asset,
            collateral: collateral,
            assetBefore: asset.balanceOf(address(this)),
            collateralBefore: collateral.balanceOf(address(this))
        });
    }

    function _flashLoan(
        FlashLoanContext memory context,
        IMorphoFlashLender lender,
        Operation operation,
        LeverageSwapCall calldata swap,
        bytes memory amounts
    ) private {
        bytes memory data = abi.encode(operation, context, swap, amounts);
        _expectedCallback = keccak256(abi.encode(address(lender), uint256(context.flashAmount), keccak256(data)));
        lender.flashLoan(address(context.asset), context.flashAmount, data);
        if (_expectedCallback != bytes32(0)) revert MissingFlashLoanCallback();

        context.asset.forceApprove(address(lender), 0);
        _requireBalance(context.asset, address(this), context.assetBefore);
        _requireBalance(context.collateral, address(this), context.collateralBefore);
    }

    function _executeLeverage(
        FlashLoanContext memory context, LeverageAmounts memory amounts, LeverageSwapCall memory swap
    ) private {
        _requireBalance(context.collateral, address(this), context.collateralBefore + amounts.collateralIn);
        _executeSwap(context.asset, context.collateral, context.flashAmount, swap);
        _requireBalance(context.asset, address(this), context.assetBefore);

        uint256 totalCollateral = context.collateral.balanceOf(address(this)) - context.collateralBefore;
        uint256 collateralOut = totalCollateral - amounts.collateralIn;
        if (collateralOut < amounts.minCollateralOut)
            revert InsufficientCollateralOut(amounts.minCollateralOut, collateralOut);
        _depositCollateral(context, totalCollateral.toUint128());

        context.pool.borrow(context.account, context.market, context.flashAmount, amounts.maxDebt);
        context.pool.withdraw(context.account, address(this), context.flashAmount);
    }

    function _executeRepayment(
        FlashLoanContext memory context, RepayAmounts memory amounts, LeverageSwapCall memory swap, bool returnCollateral
    ) private {
        _requireBalance(context.collateral, address(this), context.collateralBefore);
        _repayDebt(context);
        context.pool.withdrawCollateral(context.account, context.market, address(this), amounts.collateralToWithdraw);
        _requireBalance(context.collateral, address(this), context.collateralBefore + amounts.collateralToWithdraw);
        _executeSwap(context.collateral, context.asset, amounts.maxCollateralIn, swap);

        uint256 remainingCollateral = context.collateral.balanceOf(address(this)) - context.collateralBefore;
        if (returnCollateral) {
            _returnCollateral(context, remainingCollateral, amounts.minCollateralOut);
        } else if (remainingCollateral != 0) {
            _depositCollateral(context, remainingCollateral.toUint128());
        }
    }

    function _repayDebt(FlashLoanContext memory context) private {
        context.asset.forceApprove(address(context.pool), context.flashAmount);
        context.pool.deposit(address(this), context.flashAmount);
        context.asset.forceApprove(address(context.pool), 0);
        context.pool.repay(address(this), context.account, context.market, context.flashAmount);
        _requireBalance(context.asset, address(this), context.assetBefore);
    }

    function _executeSwap(IERC20 tokenIn, IERC20 tokenOut, uint128 maxAmountIn, LeverageSwapCall memory swap) private {
        address executor = address(swapExecutor);
        uint256 inputBefore = tokenIn.balanceOf(executor);
        tokenIn.safeTransfer(executor, maxAmountIn);
        _requireBalance(tokenIn, executor, inputBefore + maxAmountIn);

        swapExecutor.execute(tokenIn, tokenOut, maxAmountIn, inputBefore, swap);
        _requireBalance(tokenIn, executor, inputBefore);
    }

    function _depositCollateral(FlashLoanContext memory context, uint128 amount) private {
        IERC20 collateral = context.collateral;
        collateral.forceApprove(address(context.pool), amount);
        context.pool.depositCollateral(context.account, context.market, amount);
        collateral.forceApprove(address(context.pool), 0);
        _requireBalance(collateral, address(this), context.collateralBefore);
    }

    function _returnCollateral(FlashLoanContext memory context, uint256 amount, uint128 minimum) private {
        IERC20 collateral = context.collateral;
        if (amount < minimum) revert InsufficientCollateralOut(minimum, amount);
        uint256 balanceBefore = collateral.balanceOf(context.account);
        collateral.safeTransfer(context.account, amount);
        uint256 received = collateral.balanceOf(context.account) - balanceBefore;
        if (received < minimum) revert InsufficientCollateralOut(minimum, received);
    }

    function _validateLeverage(LeverageParams calldata params) private view {
        _validatePool(params.factory, params.pool, params.deadline);
        if (params.leverage <= UNIT || params.collateralIn == 0 || params.flashAmount == 0 ||
            params.minCollateralOut == 0 || params.maxDebt < params.flashAmount)
            revert InvalidPositionParams();

        IPriceOracle.Price memory price = IPriceOracle(params.pool.priceOracle()).getPrice();
        if (price.numerator == 0 || price.denominator == 0 || price.updatedAt > block.timestamp ||
            block.timestamp - price.updatedAt >= params.pool.getStalePriceWindow())
            revert InvalidOraclePrice();

        // The quote already includes token decimals. The offchain flash amount may use at most
        // (leverage - 1) times the oracle value of the user's contribution, rounded down.
        uint256 depositValue = Math.mulDiv(params.collateralIn, price.numerator, price.denominator);
        if (depositValue == 0) revert FlashAmountExceedsLeverage();
        uint256 flashToDepositRatio = Math.mulDiv(params.flashAmount, UNIT, depositValue, Math.Rounding.Ceil);
        if (flashToDepositRatio > params.leverage - UNIT) revert FlashAmountExceedsLeverage();
    }

    function _validatePool(ICreditPoolFactory factory, ICreditPool pool, uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
        if (!isFactoryAllowed[factory]) revert InvalidFactory(address(factory));
        if (!factory.isPool(address(pool))) revert InvalidPool(address(pool));
    }

    function _requireHealthFactor(FlashLoanContext memory context, uint256 minimum) private view {
        if (minimum != 0) {
            uint256 healthFactor = context.pool.getHealthFactor(context.market, context.account);
            if (healthFactor < minimum) revert InsufficientHealthFactor(minimum, healthFactor);
        }
    }

    function _requireBalance(IERC20 token, address account, uint256 expected) private view {
        uint256 actual = token.balanceOf(account);
        if (actual != expected) revert BalanceMismatch(address(token), expected, actual);
    }
}

// The extension holds the user's pool permissions. Arbitrary swap calldata runs from this executor.
contract LeverageSwapExecutor {
    using SafeERC20 for IERC20;

    address private immutable _controller = msg.sender;

    error Unauthorized();
    error OutputBalanceMismatch();

    function execute(
        IERC20 tokenIn, IERC20 tokenOut, uint128 maxAmountIn, uint256 inputBefore, LeverageSwapCall calldata swap
    ) external {
        if (msg.sender != _controller) revert Unauthorized();

        uint256 outputBefore = tokenOut.balanceOf(address(this));
        if (swap.spender != address(0)) tokenIn.forceApprove(swap.spender, maxAmountIn);
        Address.functionCall(swap.target, swap.data);
        if (swap.spender != address(0)) tokenIn.forceApprove(swap.spender, 0);

        uint256 inputLeft = tokenIn.balanceOf(address(this)) - inputBefore;
        if (inputLeft != 0) tokenIn.safeTransfer(_controller, inputLeft);
        uint256 output = tokenOut.balanceOf(address(this)) - outputBefore;
        if (output != 0) tokenOut.safeTransfer(_controller, output);
        if (tokenOut.balanceOf(address(this)) != outputBefore) revert OutputBalanceMismatch();
    }
}
