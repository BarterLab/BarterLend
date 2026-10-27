// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { ReentrancyGuard } from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { DeployPermit2 } from "lib/permit2/test/utils/DeployPermit2.sol";

import { IPermit2 } from "lib/permit2/src/interfaces/IPermit2.sol";
import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";
import { ICreditPoolConstants, ICreditPoolTypes } from "src/interfaces/ICreditPool.sol";
import { ILiquidator } from "src/interfaces/ILiquidator.sol";
import { CreditPool } from "src/CreditPool.sol";
import { AaveV3Adapter } from "src/adapters/AaveV3Adapter.sol";

import { MarketsConfigParams } from "src/lib/MarketsConfig.sol";

import { CreditPoolTestSuite, MockCreditPool } from "./0_base.t.sol";
import { MockToken } from "test/mocks/MockToken.sol";
import { MockAaveToken } from "test/mocks/MockAaveToken.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";
import { MockPriceOracle } from "test/mocks/MockPriceOracle.sol";

import { CreditPoolFacet1 } from "src/facets/CreditPoolFacet1.sol";
import { CreditPoolFacet2 } from "src/facets/CreditPoolFacet2.sol";
import { CreditPoolFacet3 } from "src/facets/CreditPoolFacet3.sol";
import { CreditPoolFacet4 } from "src/facets/CreditPoolFacet4.sol";

contract ReentrantMockToken is MockToken {
    address internal _callbackTarget;
    bytes internal _callbackData;
    bool internal _callbackOnTransfer;
    bool internal _callbackOnTransferFrom;
    bool internal _inCallback;

    function setReentrancy(address callbackTarget, bytes calldata callbackData, bool onTransfer, bool onTransferFrom)
        external
    {
        _callbackTarget = callbackTarget;
        _callbackData = callbackData;
        _callbackOnTransfer = onTransfer;
        _callbackOnTransferFrom = onTransferFrom;
    }

    function clearReentrancy() external {
        _callbackTarget = address(0);
        delete _callbackData;
        _callbackOnTransfer = false;
        _callbackOnTransferFrom = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        _reenterIfArmed(false);
        return success;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool success = super.transferFrom(from, to, amount);
        _reenterIfArmed(true);
        return success;
    }

    function _reenterIfArmed(bool isTransferFrom) internal {
        if (_inCallback || _callbackTarget == address(0)) return;
        if (isTransferFrom && !_callbackOnTransferFrom) return;
        if (!isTransferFrom && !_callbackOnTransfer) return;

        _inCallback = true;
        (bool success, bytes memory returndata) = _callbackTarget.call(_callbackData);
        _inCallback = false;

        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}

contract ReentrantLiquidator is ILiquidator {
    CreditPool internal immutable _pool;
    bytes internal _reentryCall;

    constructor(CreditPool pool_) {
        _pool = pool_;
    }

    function setReentry(bytes calldata data) external {
        _reentryCall = data;
    }

    function execute_liquidation(uint64 market, address borrower, uint128 debtAmount, bytes calldata data) external {
        _pool.liquidate(market, borrower, debtAmount, 0, type(uint256).max, data);
    }

    function liquidateCallback(uint128, uint128, bytes calldata) external {
        (bool success, bytes memory returndata) = address(_pool).call(_reentryCall);
        if (!success) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}

abstract contract ReentrantTokenCreditPoolTestSuite is Test, ICreditPoolConstants, ICreditPoolTypes {
    ReentrantMockToken internal collateral;
    ReentrantMockToken internal asset;
    MockAaveToken internal aaveToken;
    MockAavePool internal aavePool;
    AaveV3Adapter internal aaveAdapter;
    MockPriceOracle internal priceOracle;
    DeployPermit2 internal deployPermit2;
    IPermit2 internal permit2;

    MockCreditPool public pool;

    uint64 internal market;

    address internal provider = makeAddr("Provider");
    address internal borrower = makeAddr("Borrower");

    function setUp() public {
        vm.warp(1);

        address[] memory facets = new address[](4);
        facets[0] = address(new CreditPoolFacet1());
        facets[1] = address(new CreditPoolFacet2());
        facets[2] = address(new CreditPoolFacet3());
        facets[3] = address(new CreditPoolFacet4());

        collateral = new ReentrantMockToken();
        asset = new ReentrantMockToken();
        aaveToken = new MockAaveToken(asset, 10);
        aavePool = new MockAavePool(asset, aaveToken);
        aaveAdapter = new AaveV3Adapter();
        priceOracle = new MockPriceOracle(address(collateral), address(asset));
        deployPermit2 = new DeployPermit2();
        permit2 = IPermit2(deployPermit2.run());

        InitializationParams memory params = InitializationParams({
            owner: address(this),
            permit2: address(permit2),
            asset: address(asset),
            underlyingPool: UnderlyingPoolConfig({
                adapter: address(aaveAdapter),
                config: bytes32(uint256(uint160(address(aaveToken))))
            }),
            collateral: address(collateral),
            priceOracle: address(priceOracle),
            stalePriceWindow: 24 hours,
            protocolFee: 0,
            totalCollateralCap: type(uint128).max,
            provideOrderMinAmount: 1e18,
            borrowOrderMinAmount: 1e18,
            maxActiveProvideOrders: 8,
            maxActiveBorrowOrders: 1,
            borrowLTV: UNIT * 50 / 100,
            liquidationLTV: UNIT * 50 / 100,
            liquidationDiscountMin: UNIT * 5 / 100,
            liquidationDiscountMax: UNIT * 20 / 100,
            minDebtRemainingAfterLiquidation: 10e18,
            liquidationGracePeriod: 1 days,

            marketsConfig: MarketsConfigParams({
                durations: [YEAR, YEAR, YEAR],
                active: [uint8(3), 3, 3],
                extensions: [uint64(0), 0, 0]
            })
        });

        market = uint64(block.timestamp + YEAR);

        pool = new MockCreditPool(params, facets);
    }

    function _mint_asset(address user, uint256 amount) internal {
        vm.prank(user); asset.mint(amount);
        vm.prank(user); asset.approve(address(pool), amount);
    }

    function _mint_collateral(address user, uint256 amount) internal {
        vm.prank(user); collateral.mint(amount);
        vm.prank(user); collateral.approve(address(pool), amount);
    }
}

contract TestCreditPool_reentrancy_token_callbacks is ReentrantTokenCreditPoolTestSuite {
    function test_deposit_collateral_rejects_transfer_from_reentrancy() public {
        _mint_collateral(borrower, 10e18);

        collateral.setReentrancy(
            address(pool),
            abi.encodeWithSelector(CreditPool.placeBorrowOrder.selector, borrower, market, 10 * APR_PERCENT, 1e18),
            false,
            true
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(borrower); pool.depositCollateral(borrower, market, 10e18);

        assertEq(pool.collateralOf(market, borrower), 0);
        assertEq(collateral.balanceOf(borrower), 10e18);
    }

    function test_cancel_provide_order_rejects_transfer_reentrancy() public {
        _mint_asset(provider, 100e18);
        vm.prank(provider); pool.deposit(provider, 100e18);
        vm.prank(provider); pool.placeProvideOrder(provider, market, 10 * APR_PERCENT, 100e18);

        asset.setReentrancy(
            address(pool),
            abi.encodeWithSelector(CreditPool.placeBorrowOrder.selector, provider, market, 10 * APR_PERCENT, 1e18),
            true,
            false
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(provider); pool.cancelProvideOrder(provider, market, 10 * APR_PERCENT, 100e18);

        assertEq(pool.getProvideOrderBalance(market, 10 * APR_PERCENT, provider), 100e18);
    }

    function test_cancel_provide_order_rejects_read_only_reentrancy() public {
        _mint_asset(provider, 100e18);
        vm.prank(provider); pool.deposit(provider, 100e18);
        vm.prank(provider); pool.placeProvideOrder(provider, market, 10 * APR_PERCENT, 100e18);

        asset.setReentrancy(
            address(pool),
            abi.encodeWithSelector(CreditPool.getProvideOrderBalance.selector, market, 10 * APR_PERCENT, provider),
            true,
            false
        );

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(provider); pool.cancelProvideOrder(provider, market, 10 * APR_PERCENT, 100e18);

        assertEq(pool.getProvideOrderBalance(market, 10 * APR_PERCENT, provider), 100e18);
    }
}

contract TestCreditPool_reentrancy_liquidator_callback is CreditPoolTestSuite {
    function beforeEach() public override {
        _deposit(provider_A, 100e18);
        vm.prank(provider_A); pool.placeProvideOrder(provider_A, markets[0], 10 * APR_PERCENT, 100e18);

        _mint_collateral(borrower_A, 220e18);
        vm.prank(borrower_A); pool.depositCollateral(borrower_A, markets[0], 220e18);
        vm.prank(borrower_A); pool.borrow(borrower_A, markets[0], 100e18, 110e18);
    }

    function test_liquidate_callback_rejects_reentrancy() public {
        ReentrantLiquidator liquidator = new ReentrantLiquidator(pool);
        liquidator.setReentry(abi.encodeWithSelector(CreditPool.borrow.selector, borrower_A, markets[0], 1e18, type(uint128).max));

        priceOracle.setPrice(0.9e18);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        liquidator.execute_liquidation(markets[0], borrower_A, 110e18, hex"01");

        assertEq(pool.debtOf(markets[0], borrower_A), 110e18);
        assertEq(pool.collateralOf(markets[0], borrower_A), 220e18);
    }
}
