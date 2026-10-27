// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {Test} from "lib/forge-std/src/Test.sol";
import {IMorpho, Id, MarketParams, Position} from "lib/morpho-blue-irm/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IAdaptiveCurveIrm} from "lib/morpho-blue-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol";

import {ICreditPool} from "src/interfaces/ICreditPool.sol";
import {MorphoMarketV1AdaptiveCurveAdapter} from "src/adapters/MorphoMarketV1AdaptiveCurveAdapter.sol";
import {ICreditPoolTypes} from "src/interfaces/ICreditPool.sol";
import {IUnderlyingPool, UnderlyingPoolConfig} from "src/interfaces/IUnderlyingPool.sol";
import {MarketsConfigParams} from "src/lib/MarketsConfig.sol";

import {MockAdaptiveCurveIrm} from "test/mocks/MockAdaptiveCurveIrm.sol";
import {MockMorphoMarketV1} from "test/mocks/MockMorphoMarketV1.sol";
import {MockPriceOracle} from "test/mocks/MockPriceOracle.sol";
import {MockToken} from "test/mocks/MockToken.sol";

contract TestCreditPool_morpho_underlying_pool is Test {
    address private constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint64 private constant YEAR = 365 days;
    uint256 private constant UNIT = 1e18;
    uint256 private constant APR_PERCENT = 100;

    MockToken private asset;
    MockToken private collateral;
    MockPriceOracle private priceOracle;
    MockMorphoMarketV1 private morpho;
    MockAdaptiveCurveIrm private irm;
    MorphoMarketV1AdaptiveCurveAdapter private adapter;
    ICreditPool private pool;

    bytes32 private marketId;
    uint64 private market;

    address private provider = makeAddr("Provider");
    address private borrower = makeAddr("Borrower");

    function setUp() public {
        vm.warp(1);

        asset = new MockToken();
        collateral = new MockToken();
        priceOracle = new MockPriceOracle(address(collateral), address(asset));
        morpho = new MockMorphoMarketV1();
        irm = new MockAdaptiveCurveIrm(address(morpho));
        adapter = new MorphoMarketV1AdaptiveCurveAdapter(IMorpho(address(morpho)), IAdaptiveCurveIrm(address(irm)));

        MarketParams memory marketParams = MarketParams({
            loanToken: address(asset),
            collateralToken: address(collateral),
            oracle: address(priceOracle),
            irm: address(irm),
            lltv: 0.8e18
        });
        marketId = morpho.createMarket(marketParams, 9e18, uint128(9e18 - 999_999), 0, 0, 0);
        morpho.setPosition(marketId, DEAD_ADDRESS, Position({supplyShares: 1e9, borrowShares: 0, collateral: 0}));

        asset.mint(9e18);
        assertEq(asset.transfer(address(morpho), 9e18), true);

        pool = ICreditPool(this.deploy_pool(_initialization_params(marketId), _facets()));
        market = uint64(block.timestamp + YEAR);
    }

    function test_constructor_validates_morpho_market_config() public view {
        UnderlyingPoolConfig memory configuredPool = pool.underlyingPool();

        assertEq(configuredPool.adapter, address(adapter));
        assertEq(configuredPool.config, marketId);
    }

    function test_constructor_reverts_for_unknown_morpho_market() public {
        bytes32 unknownMarketId = keccak256("unknown market");
        address[] memory facets = _facets();

        vm.expectRevert(
            abi.encodeWithSelector(
                IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(asset), unknownMarketId
            )
        );
        this.deploy_pool(_initialization_params(unknownMarketId), facets);
    }

    function test_borrow_withdraws_from_credit_pool_morpho_position() public {
        vm.prank(provider); asset.mint(100e18);
        vm.prank(provider); asset.approve(address(pool), 100e18);
        vm.prank(provider); pool.deposit(provider, 100e18);
        vm.prank(provider); pool.placeProvideOrder(provider, market, 10 * APR_PERCENT, 100e18);

        vm.prank(borrower); collateral.mint(100e18);
        vm.prank(borrower); collateral.approve(address(pool), 100e18);
        vm.prank(borrower); pool.depositCollateral(borrower, market, 100e18);
        vm.prank(borrower); pool.borrow(borrower, market, 40e18, 44e18);

        assertEq(pool.getProvideOrderBalance(market, 10 * APR_PERCENT, provider), 60e18);
        assertEq(pool.loanOf(market, provider), 44e18);
        assertEq(pool.debtOf(market, borrower), 44e18);
        assertEq(pool.balanceOf(borrower), 40e18);
        assertEq(adapter.totalAssets(address(pool), marketId), 60e18);

        Position memory poolPosition = morpho.position(Id.wrap(marketId), address(pool));
        Position memory adapterPosition = morpho.position(Id.wrap(marketId), address(adapter));
        assertEq(poolPosition.supplyShares, 60e18);
        assertEq(adapterPosition.supplyShares, 0);
    }

    function test_supply_on_behalf_and_cancel_cycles_do_not_block_next_depositor() public {
        pool.setProvideOrderMinAmount(1);
        vm.prank(provider); asset.mint(1e18);
        vm.prank(provider); asset.approve(address(pool), 1e18);
        vm.prank(provider); pool.deposit(provider, 1e18);
        vm.prank(provider); pool.placeProvideOrder(provider, market, 0, 1e18);

        MarketParams memory marketParams = morpho.idToMarketParams(Id.wrap(marketId));
        for (uint256 i = 0; i < 23; i++) {
            uint128 donation = i == 22 ? 9e18 : 99e18;
            vm.prank(provider); asset.mint(donation);
            vm.prank(provider); asset.approve(address(morpho), donation);
            vm.prank(provider); morpho.supply(marketParams, donation, 0, address(pool), "");

            uint128 balance = pool.getProvideOrderBalance(market, 0, provider);
            vm.prank(provider); pool.cancelProvideOrder(provider, market, 0, balance - 1e18);
        }

        address nextProvider = makeAddr("Next provider");
        vm.prank(nextProvider); asset.mint(0.5e18);
        vm.prank(nextProvider); asset.approve(address(pool), 0.5e18);
        vm.prank(nextProvider); pool.deposit(nextProvider, 0.5e18);
        vm.prank(nextProvider); pool.placeProvideOrder(nextProvider, market, 0, 0.5e18);

        assertApproxEqAbs(pool.getProvideOrderBalance(market, 0, nextProvider), 0.5e18, 1);
    }

    function _initialization_params(bytes32 config)
        private
        view
        returns (ICreditPoolTypes.InitializationParams memory)
    {
        return ICreditPoolTypes.InitializationParams({
            owner: address(this),
            permit2: address(1),
            asset: address(asset),
            underlyingPool: UnderlyingPoolConfig({adapter: address(adapter), config: config}),
            priceOracle: address(priceOracle),
            collateral: address(collateral),
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
            liquidationGracePeriod: 1 days,
            minDebtRemainingAfterLiquidation: 1e18,
            marketsConfig: MarketsConfigParams({
                durations: [YEAR, YEAR, YEAR], active: [uint8(3), 3, 3], extensions: [uint64(0), 0, 0]
            })
        });
    }

    function _facets() private returns (address[] memory facets) {
        facets = new address[](4);
        facets[0] = deployCode("src/facets/CreditPoolFacet1.sol:CreditPoolFacet1");
        facets[1] = deployCode("src/facets/CreditPoolFacet2.sol:CreditPoolFacet2");
        facets[2] = deployCode("src/facets/CreditPoolFacet3.sol:CreditPoolFacet3");
        facets[3] = deployCode("src/facets/CreditPoolFacet4.sol:CreditPoolFacet4");
    }

    function deploy_pool(ICreditPoolTypes.InitializationParams memory params, address[] memory facets)
        external
        returns (address deployed)
    {
        bytes memory code = abi.encodePacked(vm.getCode("src/CreditPool.sol:CreditPool"), abi.encode(params, facets));
        // Bubble constructor errors so the invalid-configuration regression retains its exact assertion.
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }
}
