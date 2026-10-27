// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { console } from "lib/forge-std/src/console.sol";
import { Test } from "lib/forge-std/src/Test.sol";
import { MockToken } from "test/mocks/MockToken.sol";
import { MockAaveToken } from "test/mocks/MockAaveToken.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";
import { MockPriceOracle } from "test/mocks/MockPriceOracle.sol";
import { DeployPermit2 } from "lib/permit2/test/utils/DeployPermit2.sol";

import { IPermit2 } from "lib/permit2/src/interfaces/IPermit2.sol";
import { IERC20, IERC20Errors } from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { MarketsConfigParams } from "src/lib/MarketsConfig.sol";

import { IPriceOracle } from "src/interfaces/IPriceOracle.sol";
import { UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";
import { ICreditPoolTypes, ICreditPoolErrors, ICreditPoolEvents, ICreditPoolConstants } from "src/interfaces/ICreditPool.sol";
import { ICreditPoolExplorerAPITypes } from "src/interfaces/ICreditPool.sol";
import { ICreditPoolFactory } from "src/interfaces/ICreditPoolFactory.sol";
import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolRolloverExtension } from "src/CreditPoolRolloverExtension.sol";
import { AaveV3Adapter } from "src/adapters/AaveV3Adapter.sol";

import { CreditPoolFacet1 } from "src/facets/CreditPoolFacet1.sol";
import { CreditPoolFacet2 } from "src/facets/CreditPoolFacet2.sol";
import { CreditPoolFacet3 } from "src/facets/CreditPoolFacet3.sol";
import { CreditPoolFacet4 } from "src/facets/CreditPoolFacet4.sol";

uint256 constant MARKETS_BUFFER = 32;

abstract contract RolloverExtensionTestTypes {
    struct ReborrowSolution {
        uint64 market;
        uint256 debtPercent;
    }

    struct RolloverSolution {
        ReborrowSolution[] reborrows;
    }

    event RolloverConfigUpdated(address indexed pool, address indexed account, uint64 indexed market, bool enabled, uint256 newMaxDebtFactor, uint256 newKeeperFee);
    event DebtCoveredWithLoan(address indexed pool, address indexed account, uint64 indexed market, uint128 debtRepaid, uint128 fee);
    event DebtCoveredFromPoolBalance(address indexed pool, address indexed account, uint64 indexed market, uint128 debtRepaid, uint128 fee);
    event DebtCoveredFromAccountTransfer(address indexed pool, address indexed account, uint64 indexed market, uint128 debtRepaid, uint128 fee);
    event DebtRolledOver(address indexed pool, address indexed account, uint64 indexed fromMarket, uint64 toMarket, uint128 debtRepaid, uint128 newDebt, uint128 collateralMoved, uint128 fee);
    event RolloverExecuted(address indexed pool, address indexed account, address indexed keeper, uint64 market, address feeRecipient, uint128 debtRepaid, uint128 remainingDebt, uint128 fee);
    event FeeCollected(address indexed token, address indexed recipient, uint128 amount);

    error RolloverDisabled(address pool, address borrower, uint64 market);
    error RolloverDebtPercentExceeded(uint256 totalPercent, uint256 maxPercent);
    error InvalidKeeperFee(uint256 fee);
    error KeeperFeeTooHigh(uint256 maxKeeperFee, uint256 keeperFee);
    error InvalidPermit2(address permit2);
    error InvalidFactory(address factory);
    error InvalidPool(address pool);
    error InvalidFeeAmount(uint256 amount, uint256 available);
    error TokenReceiptMismatch(address token, uint256 expected, uint256 received);
}

contract MockCreditPoolFactoryRegistry is ICreditPoolFactory {
    mapping(address pool => bool) public override isPool;

    function setPool(address pool, bool registered) external {
        isPool[pool] = registered;
    }
}

contract MockCreditPool is CreditPool {
    AddressQueue internal _testAddressQueue;

    constructor(InitializationParams memory params, address[] memory facets) CreditPool(params, facets) {}

    function protocolFeeAssets(uint128 principal, uint128 grossLoan, uint256 protocolFee) external pure returns (uint128) {
        return _protocolFeeAssets(principal, grossLoan, protocolFee);
    }

    function grossLoanForNetLoan(uint128 netLoan, uint256 APR, uint256 duration, uint256 protocolFee, uint128 maxGrossLoan)
        external pure
        returns (uint128)
    {
        return _grossLoanForNetLoan(netLoan, APR, duration, protocolFee, maxGrossLoan);
    }

    function badDebt(uint64 market, uint128 amount) external {
        _socializeBadDebt(market, amount);
    }

    function viewLoanPool(uint64 market) external view returns (uint128 totalAssets, uint256 totalShares) {
        LoanPool storage loanPool = _markets[market].loanPool;
        return (loanPool.totalAssets, loanPool.totalShares);
    }


    function transferConfiguredReceiptTokenTo(address to, uint256 amount) external {
        IERC20(address(uint160(uint256(_underlyingPoolConfig)))).transfer(to, amount);
    }


    function viewProvideLiquidityForTick(uint64 market, uint256 APR) external view returns (uint256) {
        POrderbookTick storage tick = _markets[market].porderbook.tickByAPR[APR];
        (uint256 index, uint64 generation,) = _previewUnderlyingPoolState();
        if (tick.underlyingPoolGeneration != generation) return 0;
        return _previewIndexedAmount(tick.assets, tick.indexSnapshot, index);
    }

    function viewProvideLiquidityForBucket(uint64 market, uint256 bucketId) external view returns (uint256) {
        POrderbookBucket storage bucket = _markets[market].porderbook.bucketById[bucketId];
        (uint256 index, uint64 generation,) = _previewUnderlyingPoolState();
        if (bucket.underlyingPoolGeneration != generation) return 0;
        return _previewIndexedAmount(bucket.assets, bucket.indexSnapshot, index);
    }

    function bucketIdForAPR(uint256 APR) external pure returns (uint256) {
        return _aprToBucketId(APR);
    }

    function getAvailableToClaim(uint64 market) external view returns (uint128) {
        return _markets[market].loanPool.balance;
    }

    function setAvailableToClaim(uint64 market, uint128 amount) external {
        _markets[market].loanPool.balance = amount;
    }



    struct TickBorrowOrderView {
        address borrower;
        uint128 amount;
        BOrderType orderType;
    }

    function viewBorrowOrderbookForTick(uint64 market, uint256 APR) public view returns (TickBorrowOrderView[] memory queue) {
        BOrderbookTick storage tick = _markets[market].borderbook.tickByAPR[APR];

        uint256 count = 0;
        for (uint48 i = tick.borrowers.head; i != 0; i = tick.borrowers.nodes[i].next) {
            uint128 amount = _getBorrowOrderBalance(market, APR, tick.borrowers.nodes[i].value);
            if (amount == 0) continue;
            count++;
        }

        queue = new TickBorrowOrderView[](count);

        uint256 j = 0;
        for (uint48 i = tick.borrowers.head; i != 0; i = tick.borrowers.nodes[i].next) {
            address borrower = tick.borrowers.nodes[i].value;
            uint128 amount = _getBorrowOrderBalance(market, APR, borrower);
            BOrderType orderType = _users[borrower].borders.byMarket[market].byAPR[APR].orderType;
            if (amount == 0) continue;

            queue[j++] = TickBorrowOrderView({ borrower: borrower, amount: amount, orderType: orderType });
        }
    }

    function viewBorrowOrderNodeId(uint64 market, uint256 APR, address account) external view returns (uint48) {
        return _users[account].borders.byMarket[market].byAPR[APR].queueNodeId;
    }

    function viewBorrowOrderNodeLinks(uint64 market, uint256 APR, uint48 id) external view returns (uint48 prev, uint48 next) {
        AddressQueueNode storage node = _markets[market].borderbook.tickByAPR[APR].borrowers.nodes[id];
        return (node.prev, node.next);
    }

    function addressQueuePush(address value) external returns (uint48) {
        return _queue_push(_testAddressQueue, value);
    }

    function addressQueueRemove(uint48 id) external {
        _queue_remove(_testAddressQueue, id);
    }

    function addressQueueHead() external view returns (uint48) {
        return _testAddressQueue.head;
    }

    function addressQueueTail() external view returns (uint48) {
        return _testAddressQueue.tail;
    }

    function addressQueueNode(uint48 id) external view returns (address value, uint48 next, uint48 prev) {
        AddressQueueNode storage node = _testAddressQueue.nodes[id];
        return (node.value, node.next, node.prev);
    }
}

contract CreditPoolTestSuite is
    Test,
    ICreditPoolTypes, IERC20Errors, ICreditPoolErrors, ICreditPoolEvents, ICreditPoolConstants,
    ICreditPoolExplorerAPITypes, RolloverExtensionTestTypes
{
    MockToken internal collateral;
    MockToken internal asset;
    MockAaveToken internal aaveToken;
    MockAavePool internal aavePool;
    AaveV3Adapter internal aaveAdapter;
    MockPriceOracle internal priceOracle;
    DeployPermit2 internal deployPermit2;
    IPermit2 internal permit2;

    MockCreditPool public pool;
    MockCreditPoolFactoryRegistry internal rolloverFactory;
    CreditPoolRolloverExtension internal rolloverExtension;

    address provider_A = makeAddr("Provider A");
    address provider_B = makeAddr("Provider B");
    address provider_C = makeAddr("Provider C");
    address provider_D = makeAddr("Provider D");

    address borrower_A = makeAddr("Borrower A");
    address borrower_B = makeAddr("Borrower B");
    address borrower_C = makeAddr("Borrower C");
    address borrower_D = makeAddr("Borrower D");

    uint64[MARKETS_BUFFER] internal markets;
    uint256 internal marketStep;

    function reconfigure(InitializationParams memory params) internal pure virtual { }

    function beforeEach() public virtual {}

    function _owner() internal view virtual returns (address) {
        return address(this);
    }

    function setUp() public {
        vm.warp(1);

        address[] memory facets = new address[](4);
        facets[0] = address(new CreditPoolFacet1());
        facets[1] = address(new CreditPoolFacet2());
        facets[2] = address(new CreditPoolFacet3());
        facets[3] = address(new CreditPoolFacet4());

        collateral = new MockToken(); vm.label(address(collateral), "Collateral");
        asset = new MockToken(); vm.label(address(asset), "Asset");
        aaveToken = new MockAaveToken(asset, 10); vm.label(address(aaveToken), "Aave Token");
        aavePool = new MockAavePool(asset, aaveToken); vm.label(address(aavePool), "Aave Pool");
        aaveAdapter = new AaveV3Adapter(); vm.label(address(aaveAdapter), "Aave Adapter");
        priceOracle = new MockPriceOracle(address(collateral), address(asset)); vm.label(address(priceOracle), "Price Oracle");
        deployPermit2 = new DeployPermit2();
        permit2 = IPermit2(deployPermit2.run()); vm.label(address(permit2), "Permit2");

        InitializationParams memory params = InitializationParams({
            owner: _owner(),
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

        reconfigure(params);

        marketStep = params.marketsConfig.durations[0];
        for (uint256 i = 0; i < MARKETS_BUFFER; ++i) {
            markets[i] = uint64(block.timestamp + (i + 1) * marketStep);
        }

        pool = new MockCreditPool(params, facets); vm.label(address(pool), "Credit Pool");
        rolloverFactory = new MockCreditPoolFactoryRegistry();
        rolloverFactory.setPool(address(pool), true);
        rolloverExtension = new CreditPoolRolloverExtension(permit2, rolloverFactory); vm.label(address(rolloverExtension), "Rollover Extension");

        beforeEach();
    }

    function _mint(address user, uint256 amount) internal {
        vm.prank(user); asset.mint(amount);
        vm.prank(user); asset.approve(address(pool), amount);
    }

    function _deposit(address user, uint256 amount) internal {
        _mint(user, amount);
        vm.prank(user); pool.deposit(user, uint128(amount));
    }

    function _withdraw_and_burn(address user, uint128 amount) internal {
        vm.prank(user); pool.withdraw(user, user, amount);
        vm.prank(user); asset.burn(amount);
    }

    function _mint_collateral(address user, uint256 amount) internal {
        vm.prank(user); collateral.mint(amount);
        vm.prank(user); collateral.approve(address(pool), amount);
    }

    function _deposit_collateral(address user, uint64 market, uint128 amount) internal {
        _mint_collateral(user, amount);
        vm.prank(user); pool.depositCollateral(user, market, amount);
    }

    function _borrow(uint64 market, address borrower, uint128 amount) internal {
        _deposit_collateral(borrower, market, amount * 4);
        vm.prank(borrower); pool.borrow(borrower, market, amount, amount * 2);
    }

    function _rollover_extension(
        address pool_,
        uint64 market,
        address account,
        address feeRecipient,
        uint256 minKeeperFee,
        RolloverSolution memory solution
    ) internal {
        (bool success, bytes memory data) = address(rolloverExtension).call(
            abi.encodeWithSelector(
                rolloverExtension.rollover.selector,
                pool_,
                market,
                account,
                feeRecipient,
                minKeeperFee,
                solution
            )
        );
        if (!success) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    function _approve_rollover_extension(address account) internal {
        uint256 actions = rolloverExtension.requiredActions();
        vm.prank(account); pool.setDelegate(address(rolloverExtension), actions);
    }

    function _provide(uint64 market, address provider, uint128 amount) internal {
        _deposit(provider, amount);
        vm.prank(provider); pool.provideExactIn(provider, market, amount, 0, 10);
    }

    function assertEq_(uint256 a, uint256 b) public pure {
        assertApproxEqAbs(a, b, 1);
    }

    function assertEq(BOrderType a, BOrderType b) internal pure {
        assertEq(uint256(a), uint256(b));
    }

    function assertEq(BOrderType a, BOrderType b, string memory err) internal pure {
        assertEq(uint256(a), uint256(b), err);
    }
}
