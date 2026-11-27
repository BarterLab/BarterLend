// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { IMorphoFlashLender, CreditPoolLeverageExtension, LeverageSwapCall } from "./CreditPoolLeverageExtension.sol";
import { ICreditPoolExtension } from "src/interfaces/ICreditPoolExtension.sol";
import { ICreditPoolFactory } from "src/interfaces/ICreditPoolFactory.sol";
import { CreditPoolTestSuite, MockCreditPoolFactoryRegistry } from "test/CreditPool/0_base.t.sol";

contract LeverageTestLender is IMorphoFlashLender {
    bool private _alterCallbackData;

    function alterCallbackData() external {
        _alterCallbackData = true;
    }

    function flashLoan(address token, uint256 amount, bytes calldata data) external {
        IERC20(token).transfer(msg.sender, amount);
        bytes memory callbackData = _alterCallbackData ? bytes.concat(data, hex"00") : data;
        CreditPoolLeverageExtension(msg.sender).onMorphoFlashLoan(amount, callbackData);
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}

contract LeverageTestSpender {
    function pull(IERC20 token, address from, address recipient, uint256 amount) external {
        token.transferFrom(from, recipient, amount);
    }
}

contract LeverageTestRouter {
    LeverageTestSpender public immutable spender = new LeverageTestSpender();
    address public lastCaller;

    function swap(IERC20 input, IERC20 output, uint256 amountIn, uint256 amountOut, address recipient) external {
        lastCaller = msg.sender;
        spender.pull(input, msg.sender, address(this), amountIn);
        output.transfer(recipient, amountOut);
    }
}

contract CreditPoolLeverageExtensionTest is CreditPoolTestSuite {
    CreditPoolLeverageExtension private _extension;
    MockCreditPoolFactoryRegistry private _secondFactory;
    LeverageTestLender private _lender;
    LeverageTestRouter private _swapRouter;
    address private _spender;
    address private _user;

    function beforeEach() public override {
        _secondFactory = new MockCreditPoolFactoryRegistry();
        ICreditPoolFactory[] memory factories = new ICreditPoolFactory[](2);
        factories[0] = rolloverFactory;
        factories[1] = _secondFactory;
        _extension = new CreditPoolLeverageExtension(factories);
        _lender = new LeverageTestLender();
        _swapRouter = new LeverageTestRouter();
        _spender = address(_swapRouter.spender());
        _user = makeAddr("leveraged depositor");

        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);
        _deposit(_user, 7e18);
        uint256 actions = _extension.requiredActions();
        vm.prank(_user); pool.setDelegate(address(_extension), actions);
        vm.prank(_user); collateral.mint(100e18);
        vm.prank(_user); collateral.approve(address(_extension), 100e18);
        vm.prank(address(_lender)); asset.mint(100e18);
        vm.prank(address(_swapRouter)); collateral.mint(100e18);
    }

    function test_required_actions_and_description() public view {
        ICreditPoolExtension extension = _extension;
        assertEq(extension.requiredActions(), DELEGATE_BORROW | DELEGATE_WITHDRAW | DELEGATE_WITHDRAW_COLLATERAL);
        assertEq(extension.description(), "CreditPool leverage extension");
    }

    function test_opens_position_and_repays_loan_from_new_borrow_only() public {
        address executor = address(_extension.swapExecutor());
        vm.prank(_user); _extension.leverage(_params(), _swap(80e18, 80e18, executor));

        assertEq(pool.collateralOf(markets[0], _user), 180e18);
        assertEq(pool.debtOf(markets[0], _user), 88e18);
        assertEq(pool.getHealthFactor(markets[0], _user), 1_022_727_272_727_272_727);
        assertEq(pool.balanceOf(_user), 7e18);
        assertEq(asset.balanceOf(address(_lender)), 100e18);
        assertEq(asset.balanceOf(address(_extension)), 0);
        assertEq(collateral.balanceOf(address(_extension)), 0);
        assertEq(asset.balanceOf(executor), 0);
        assertEq(collateral.balanceOf(executor), 0);
        assertEq(asset.allowance(executor, _spender), 0);
        assertEq(asset.allowance(address(_extension), address(_lender)), 0);
        assertEq(collateral.allowance(address(_extension), address(pool)), 0);
        assertEq(_swapRouter.lastCaller(), executor);
        assertEq(pool.getDelegateActions(_user, executor), 0);
    }

    function test_accepts_a_pool_registered_by_the_second_allowed_factory() public {
        _secondFactory.setPool(address(pool), true);
        CreditPoolLeverageExtension.LeverageParams memory params = _params();
        params.factory = _secondFactory;
        vm.prank(_user); _extension.leverage(params, _swap(80e18, 80e18, address(_extension)));

        assertEq(pool.collateralOf(markets[0], _user), 180e18);
    }

    function test_rejects_a_pool_from_an_unlisted_factory() public {
        MockCreditPoolFactoryRegistry unlistedFactory = new MockCreditPoolFactoryRegistry();
        unlistedFactory.setPool(address(pool), true);
        CreditPoolLeverageExtension.LeverageParams memory params = _params();
        params.factory = unlistedFactory;
        vm.expectRevert(abi.encodeWithSelector(CreditPoolLeverageExtension.InvalidFactory.selector, address(unlistedFactory)));
        vm.prank(_user); _extension.leverage(params, _swap(80e18, 80e18, address(_extension)));
    }

    function test_rejects_a_pool_missing_from_the_selected_factory_registry() public {
        CreditPoolLeverageExtension.LeverageParams memory params = _params();
        params.factory = _secondFactory;
        vm.expectRevert(abi.encodeWithSelector(CreditPoolLeverageExtension.InvalidPool.selector, address(pool)));
        vm.prank(_user); _extension.leverage(params, _swap(80e18, 80e18, address(_extension)));
    }

    function test_low_swap_output_reverts_even_with_preexisting_collateral() public {
        vm.prank(address(_extension)); collateral.mint(10e18);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolLeverageExtension.InsufficientCollateralOut.selector, 80e18, 79e18));
        vm.prank(_user); _extension.leverage(_params(), _swap(80e18, 79e18, address(_extension)));

        assertEq(pool.collateralOf(markets[0], _user), 0);
        assertEq(pool.debtOf(markets[0], _user), 0);
        assertEq(collateral.balanceOf(_user), 100e18);
        assertEq(asset.balanceOf(address(_lender)), 100e18);
    }

    function test_swap_must_spend_the_full_flash_loan() public {
        vm.expectRevert(abi.encodeWithSelector(CreditPoolLeverageExtension.BalanceMismatch.selector, address(asset), 0, 1e18));
        vm.prank(_user); _extension.leverage(_params(), _swap(79e18, 80e18, address(_extension)));
    }

    function test_debt_above_limit_reverts_the_swap_and_deposit() public {
        CreditPoolLeverageExtension.LeverageParams memory params = _params();
        params.maxDebt = 87e18;
        vm.expectRevert(abi.encodeWithSelector(BorrowDebtExceeded.selector, 88e18, 87e18));
        vm.prank(_user); _extension.leverage(params, _swap(80e18, 80e18, address(_extension)));

        assertEq(collateral.balanceOf(_user), 100e18);
        assertEq(collateral.balanceOf(address(_swapRouter)), 100e18);
        assertEq(pool.collateralOf(markets[0], _user), 0);
    }

    function test_health_factor_below_minimum_reverts_the_position_and_swap() public {
        CreditPoolLeverageExtension.LeverageParams memory params = _params();
        params.minHealthFactor = 1.03e18;
        vm.expectRevert(
            abi.encodeWithSelector(CreditPoolLeverageExtension.InsufficientHealthFactor.selector, 1.03e18, 1_022_727_272_727_272_727)
        );
        vm.prank(_user); _extension.leverage(params, _swap(80e18, 80e18, address(_extension)));

        assertEq(pool.debtOf(markets[0], _user), 0);
        assertEq(pool.collateralOf(markets[0], _user), 0);
        assertEq(collateral.balanceOf(_user), 100e18);
        assertEq(collateral.balanceOf(address(_swapRouter)), 100e18);
    }

    function test_leverage_cap_uses_pool_oracle() public {
        priceOracle.setPriceFraction(79, 80);
        vm.expectRevert(CreditPoolLeverageExtension.FlashAmountExceedsLeverage.selector);
        vm.prank(_user); _extension.leverage(_params(), _swap(80e18, 80e18, address(_extension)));
    }

    function test_accepts_an_offchain_flash_amount_below_the_leverage_cap() public {
        priceOracle.setPriceFraction(6, 5);
        vm.prank(_user); _extension.leverage(_params(), _swap(80e18, 80e18, address(_extension)));

        assertEq(pool.collateralOf(markets[0], _user), 180e18);
        assertEq(pool.debtOf(markets[0], _user), 88e18);
    }

    function test_callback_rejects_altered_data_from_selected_lender() public {
        _lender.alterCallbackData();
        vm.expectRevert(CreditPoolLeverageExtension.UnexpectedFlashLoanCallback.selector);
        vm.prank(_user); _extension.leverage(_params(), _swap(80e18, 80e18, address(_extension)));
    }

    function test_callback_requires_an_active_flash_loan() public {
        vm.expectRevert(CreditPoolLeverageExtension.UnexpectedFlashLoanCallback.selector);
        vm.prank(address(_lender)); _extension.onMorphoFlashLoan(80e18, "");
    }

    function test_deleverage_reduces_ltv_and_redeposits_unused_collateral() public {
        _openPositionForRepayment();
        CreditPoolLeverageExtension.RepayParams memory params = _repayParams();
        params.minHealthFactor = 1.5e18;
        address executor = address(_extension.swapExecutor());
        vm.prank(_user); _extension.deleverage(params, 55e18, _repaymentSwap(45e18, 44e18, executor));

        assertEq(pool.debtOf(markets[0], _user), 44e18);
        assertEq(pool.collateralOf(markets[0], _user), 135e18);
        assertEq(pool.getHealthFactor(markets[0], _user), 1_534_090_909_090_909_090);
        assertEq(collateral.balanceOf(_user), 0);
        assertEq(pool.balanceOf(_user), 7e18);
        assertEq(pool.balanceOf(address(_extension)), 0);
        assertEq(asset.balanceOf(address(_lender)), 100e18);
        assertEq(asset.balanceOf(address(_extension)), 0);
        assertEq(collateral.balanceOf(address(_extension)), 0);
        assertEq(asset.balanceOf(executor), 0);
        assertEq(collateral.balanceOf(executor), 0);
        assertEq(asset.allowance(address(_extension), address(pool)), 0);
        assertEq(asset.allowance(address(_extension), address(_lender)), 0);
        assertEq(collateral.allowance(executor, _spender), 0);
    }

    function test_deleverage_reverts_when_the_swap_would_increase_ltv() public {
        _openPositionForRepayment();
        vm.expectRevert(CreditPoolLeverageExtension.LeverageNotReduced.selector);
        vm.prank(_user); _extension.deleverage(_repayParams(), 91e18, _repaymentSwap(91e18, 44e18, address(_extension)));

        assertEq(pool.debtOf(markets[0], _user), 88e18);
        assertEq(pool.collateralOf(markets[0], _user), 180e18);
    }

    function test_repayment_swap_cannot_use_preexisting_extension_assets() public {
        _openPositionForRepayment();
        vm.prank(address(_extension)); asset.mint(1e18);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolLeverageExtension.BalanceMismatch.selector, address(asset), 45e18, 44e18));
        vm.prank(_user); _extension.deleverage(_repayParams(), 45e18, _repaymentSwap(44e18, 43e18, address(_extension)));

        assertEq(pool.debtOf(markets[0], _user), 88e18);
        assertEq(asset.balanceOf(address(_extension)), 1e18);
    }

    function test_reduce_position_preserves_ltv_and_returns_excess_collateral() public {
        _openPositionForRepayment();
        CreditPoolLeverageExtension.RepayParams memory params = _repayParams();
        params.minHealthFactor = 1_022_727_272_727_272_727;
        vm.prank(_user); _extension.reducePosition(params, 90e18, 45e18, _repaymentSwap(44e18, 44e18, address(_extension)));

        assertEq(pool.debtOf(markets[0], _user), 44e18);
        assertEq(pool.collateralOf(markets[0], _user), 90e18);
        assertEq(pool.getHealthFactor(markets[0], _user), 1_022_727_272_727_272_727);
        assertEq(collateral.balanceOf(_user), 46e18);
        assertEq(pool.balanceOf(_user), 7e18);
        assertEq(asset.balanceOf(address(_lender)), 100e18);
        assertEq(asset.balanceOf(address(_extension)), 0);
        assertEq(collateral.balanceOf(address(_extension)), 0);
    }

    function test_reduce_position_rejects_withdrawal_above_the_rounded_proportion() public {
        _openPositionForRepayment();
        CreditPoolLeverageExtension.RepayParams memory params = _repayParams();
        params.debtToRepay = 44e18 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(CreditPoolLeverageExtension.InvalidProportionalWithdrawal.selector, 90e18 + 2, 90e18 + 3)
        );
        vm.prank(_user); _extension.reducePosition(params, 90e18 + 3, 45e18, _repaymentSwap(44e18, 44e18 + 1, address(_extension)));
    }

    function test_reduce_position_reserves_the_users_minimum_collateral_from_the_swap() public {
        _openPositionForRepayment();
        address executor = address(_extension.swapExecutor());
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientAllowance.selector, _spender, 43e18, 44e18));
        vm.prank(_user); _extension.reducePosition(_repayParams(), 90e18, 47e18, _repaymentSwap(44e18, 44e18, executor));

        assertEq(pool.debtOf(markets[0], _user), 88e18);
        assertEq(pool.collateralOf(markets[0], _user), 180e18);
    }

    function _openPositionForRepayment() private {
        vm.prank(_user); _extension.leverage(_params(), _swap(80e18, 80e18, address(_extension)));
    }

    function _params() private view returns (CreditPoolLeverageExtension.LeverageParams memory) {
        return CreditPoolLeverageExtension.LeverageParams({
            factory: rolloverFactory,
            pool: pool,
            flashLender: _lender,
            market: markets[0],
            leverage: 1.8e18,
            collateralIn: 100e18,
            flashAmount: 80e18,
            minCollateralOut: 80e18,
            maxDebt: 88e18,
            minHealthFactor: 1_022_727_272_727_272_727,
            deadline: block.timestamp
        });
    }

    function _swap(uint256 amountIn, uint256 amountOut, address recipient) private view returns (LeverageSwapCall memory) {
        return LeverageSwapCall({
            target: address(_swapRouter),
            spender: _spender,
            data: abi.encodeCall(_swapRouter.swap, (asset, collateral, amountIn, amountOut, recipient))
        });
    }

    function _repayParams() private view returns (CreditPoolLeverageExtension.RepayParams memory) {
        return CreditPoolLeverageExtension.RepayParams({
            factory: rolloverFactory,
            pool: pool,
            flashLender: _lender,
            market: markets[0],
            debtToRepay: 44e18,
            minHealthFactor: 0,
            deadline: block.timestamp
        });
    }

    function _repaymentSwap(uint256 collateralIn, uint256 assetOut, address recipient)
        private view returns (LeverageSwapCall memory)
    {
        return LeverageSwapCall({
            target: address(_swapRouter),
            spender: _spender,
            data: abi.encodeCall(_swapRouter.swap, (collateral, asset, collateralIn, assetOut, recipient))
        });
    }
}
