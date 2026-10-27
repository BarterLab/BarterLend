// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {Test} from "lib/forge-std/src/Test.sol";
import {
    IMorpho,
    Id,
    MarketParams,
    Position,
    Market
} from "lib/morpho-blue-irm/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IAdaptiveCurveIrm} from "lib/morpho-blue-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol";

import {MorphoMarketV1AdaptiveCurveAdapter} from "src/adapters/MorphoMarketV1AdaptiveCurveAdapter.sol";
import {IUnderlyingPool} from "src/interfaces/IUnderlyingPool.sol";
import {MockAdaptiveCurveIrm} from "test/mocks/MockAdaptiveCurveIrm.sol";
import {MockMorphoMarketV1} from "test/mocks/MockMorphoMarketV1.sol";
import {MockToken} from "test/mocks/MockToken.sol";

contract MorphoMarketV1AdapterHarness {
    IUnderlyingPool public immutable ADAPTER;
    uint256 public sentinel = 123;

    constructor(IUnderlyingPool adapter) {
        ADAPTER = adapter;
    }

    function deposit(address asset, bytes32 config, uint256 assets) external returns (uint256 totalAssetsAfter) {
        return abi.decode(_delegate(abi.encodeCall(IUnderlyingPool.deposit, (asset, config, assets))), (uint256));
    }

    function withdraw(address asset, bytes32 config, uint256 assets, address receiver)
        external
        returns (uint256 totalAssetsAfter)
    {
        return abi.decode(
            _delegate(abi.encodeCall(IUnderlyingPool.withdraw, (asset, config, assets, receiver))), (uint256)
        );
    }

    function _delegate(bytes memory data) private returns (bytes memory result) {
        (bool success, bytes memory returnData) = address(ADAPTER).delegatecall(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        return returnData;
    }
}

contract MorphoMarketV1AdaptiveCurveAdapterTest is Test {
    address private constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    MockToken internal asset;
    MockMorphoMarketV1 internal morpho;
    MockAdaptiveCurveIrm internal irm;
    MorphoMarketV1AdaptiveCurveAdapter internal adapter;
    MorphoMarketV1AdapterHarness internal harness;
    MarketParams internal marketParams;
    MarketParams internal secondMarketParams;
    bytes32 internal marketId;
    bytes32 internal secondMarketId;

    function setUp() public {
        vm.warp(1_000_000);
        asset = new MockToken();
        morpho = new MockMorphoMarketV1();
        irm = new MockAdaptiveCurveIrm(address(morpho));
        adapter = new MorphoMarketV1AdaptiveCurveAdapter(IMorpho(address(morpho)), IAdaptiveCurveIrm(address(irm)));
        harness = new MorphoMarketV1AdapterHarness(adapter);

        marketParams = MarketParams({
            loanToken: address(asset),
            collateralToken: makeAddr("collateral"),
            oracle: makeAddr("oracle"),
            irm: address(irm),
            lltv: 0.8e18
        });
        secondMarketParams = MarketParams({
            loanToken: address(asset),
            collateralToken: makeAddr("second collateral"),
            oracle: makeAddr("second oracle"),
            irm: address(irm),
            lltv: 0.86e18
        });
        marketId = morpho.createMarket(marketParams, 9e18, uint128(9e18 - 999_999), 0, 0, 0);
        secondMarketId = morpho.createMarket(secondMarketParams, 19e18, uint128(19e18 - 999_999), 0, 0, 0);
        morpho.setPosition(marketId, DEAD_ADDRESS, Position({supplyShares: 1e9, borrowShares: 0, collateral: 0}));
        morpho.setPosition(secondMarketId, DEAD_ADDRESS, Position({supplyShares: 1e9, borrowShares: 0, collateral: 0}));

        asset.mint(28e18);
        assertEq(asset.transfer(address(morpho), 28e18), true);
    }

    function test_validate_accepts_matching_seeded_market() public view {
        adapter.validate(address(asset), marketId);
    }

    function test_validate_reverts_for_unknown_market() public {
        bytes32 unknownMarket = keccak256("unknown market");

        vm.expectRevert(
            abi.encodeWithSelector(IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(asset), unknownMarket)
        );
        adapter.validate(address(asset), unknownMarket);
    }

    function test_validate_reverts_for_wrong_asset() public {
        MockToken wrongAsset = new MockToken();

        vm.expectRevert(
            abi.encodeWithSelector(IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(wrongAsset), marketId)
        );
        adapter.validate(address(wrongAsset), marketId);
    }

    function test_validate_reverts_when_params_do_not_hash_to_config() public {
        marketParams.lltv = 0.7e18;
        morpho.setMarketParams(marketId, marketParams);

        vm.expectRevert(
            abi.encodeWithSelector(IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(asset), marketId)
        );
        adapter.validate(address(asset), marketId);
    }

    function test_validate_reverts_for_different_irm() public {
        MockAdaptiveCurveIrm otherIrm = new MockAdaptiveCurveIrm(address(morpho));
        MarketParams memory otherParams = MarketParams({
            loanToken: address(asset),
            collateralToken: makeAddr("other collateral"),
            oracle: makeAddr("other oracle"),
            irm: address(otherIrm),
            lltv: 0.75e18
        });
        bytes32 otherMarketId = morpho.createMarket(otherParams, 1e18, uint128(1e18 - 999_999), 0, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(asset), otherMarketId)
        );
        adapter.validate(address(asset), otherMarketId);
    }

    function test_validate_reverts_for_unseeded_market() public {
        MarketParams memory unseededParams = MarketParams({
            loanToken: address(asset),
            collateralToken: makeAddr("unseeded collateral"),
            oracle: makeAddr("unseeded oracle"),
            irm: address(irm),
            lltv: 0.77e18
        });
        bytes32 unseededMarketId = morpho.createMarket(unseededParams, 0, 0, 0, 0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(asset), unseededMarketId
            )
        );
        adapter.validate(address(asset), unseededMarketId);
    }

    function test_validate_reverts_for_insufficient_dead_seed() public {
        morpho.setPosition(marketId, DEAD_ADDRESS, Position({supplyShares: 1e9 - 1, borrowShares: 0, collateral: 0}));

        vm.expectRevert(
            abi.encodeWithSelector(IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(asset), marketId)
        );
        adapter.validate(address(asset), marketId);
    }

    function test_deposit_and_withdraw_are_exact_and_preserve_harness_storage() public {
        address receiver = makeAddr("receiver");
        asset.mint(100e18);
        assertEq(asset.transfer(address(harness), 100e18), true);

        assertEq(harness.deposit(address(asset), marketId, 100e18), 100e18);
        assertEq(asset.balanceOf(address(harness)), 0);
        assertEq(asset.allowance(address(harness), address(morpho)), 0);
        assertEq(morpho.position(Id.wrap(marketId), address(harness)).supplyShares, 100e18);
        assertEq(adapter.totalAssets(address(harness), marketId), 100e18);
        assertEq(harness.sentinel(), 123);

        assertEq(harness.withdraw(address(asset), marketId, 40e18, receiver), 60e18);
        assertEq(asset.balanceOf(receiver), 40e18);
        assertEq(morpho.position(Id.wrap(marketId), address(harness)).supplyShares, 60e18);
        assertEq(adapter.totalAssets(address(harness), marketId), 60e18);
        assertEq(harness.sentinel(), 123);
        assertEq(asset.balanceOf(address(adapter)), 0);
        assertEq(morpho.position(Id.wrap(marketId), address(adapter)).supplyShares, 0);
    }

    function test_shared_adapter_isolates_pools_and_markets() public {
        MorphoMarketV1AdapterHarness secondHarness = new MorphoMarketV1AdapterHarness(adapter);
        MorphoMarketV1AdapterHarness thirdHarness = new MorphoMarketV1AdapterHarness(adapter);
        asset.mint(600e18);
        assertEq(asset.transfer(address(harness), 100e18), true);
        assertEq(asset.transfer(address(secondHarness), 200e18), true);
        assertEq(asset.transfer(address(thirdHarness), 300e18), true);

        assertEq(harness.deposit(address(asset), marketId, 100e18), 100e18);
        assertEq(secondHarness.deposit(address(asset), marketId, 200e18), 200e18);
        assertEq(thirdHarness.deposit(address(asset), secondMarketId, 300e18), 300e18);

        Market memory firstMarket = morpho.market(Id.wrap(marketId));
        firstMarket.totalSupplyAssets = uint128(154.5e18);
        morpho.setMarket(marketId, firstMarket);

        assertEq(adapter.totalAssets(address(harness), marketId), 50e18);
        assertEq(adapter.totalAssets(address(secondHarness), marketId), 100e18);
        assertEq(adapter.totalAssets(address(thirdHarness), secondMarketId), 300e18);
        assertEq(adapter.totalAssets(address(thirdHarness), marketId), 0);
        assertEq(adapter.totalAssets(address(adapter), marketId), 0);
    }

    function test_total_assets_previews_pending_interest_and_fee_dilution() public {
        morpho.setMarket(
            marketId,
            Market({
                totalSupplyAssets: 1000e18,
                totalSupplyShares: uint128(1000e18 - 999_999),
                totalBorrowAssets: 900e18,
                totalBorrowShares: 900e18,
                lastUpdate: uint128(block.timestamp),
                fee: 0.1e18
            })
        );
        morpho.setPosition(marketId, address(harness), Position({supplyShares: 100e18, borrowShares: 0, collateral: 0}));
        irm.setRateAtTarget(marketId, 1_268_391_679);
        vm.warp(block.timestamp + 30 days);

        assertEq(adapter.totalAssets(address(harness), marketId), 100_266_739_605_197_900_857);

        morpho.accrue(marketId, 1_268_391_679);
        assertEq(morpho.market(Id.wrap(marketId)).totalSupplyAssets, 1_002_963_773_391_087_787_300);
        assertEq(morpho.market(Id.wrap(marketId)).totalSupplyShares, 1_000_295_588_886_478_973_179);
        assertEq(adapter.totalAssets(address(harness), marketId), 100_266_739_605_197_900_857);
    }

    function test_total_assets_uses_adaptive_curve_for_off_target_utilization() public {
        morpho.setMarket(
            marketId,
            Market({
                totalSupplyAssets: 1000e18,
                totalSupplyShares: uint128(1000e18 - 999_999),
                totalBorrowAssets: 950e18,
                totalBorrowShares: 950e18,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        morpho.setPosition(marketId, address(harness), Position({supplyShares: 100e18, borrowShares: 0, collateral: 0}));
        irm.setRateAtTarget(marketId, 1_268_391_679);
        vm.warp(block.timestamp + 7 days);

        assertEq(adapter.totalAssets(address(harness), marketId), 100_235_099_007_453_230_254);
    }

    function test_total_assets_uses_adaptive_curve_for_below_target_utilization() public {
        morpho.setMarket(
            marketId,
            Market({
                totalSupplyAssets: 1000e18,
                totalSupplyShares: uint128(1000e18 - 999_999),
                totalBorrowAssets: 500e18,
                totalBorrowShares: 500e18,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        morpho.setPosition(marketId, address(harness), Position({supplyShares: 100e18, borrowShares: 0, collateral: 0}));
        irm.setRateAtTarget(marketId, 1_268_391_679);
        vm.warp(block.timestamp + 7 days);

        assertEq(adapter.totalAssets(address(harness), marketId), 100_020_911_865_491_463_699);
    }

    function test_total_assets_rounds_down_after_market_loss() public {
        morpho.setPosition(marketId, address(harness), Position({supplyShares: 100e18, borrowShares: 0, collateral: 0}));
        morpho.setMarket(
            marketId,
            Market({
                totalSupplyAssets: uint128(333e18 + 7),
                totalSupplyShares: uint128(1000e18 - 999_999),
                totalBorrowAssets: 0,
                totalBorrowShares: 0,
                lastUpdate: uint128(block.timestamp),
                fee: 0
            })
        );
        assertEq(adapter.totalAssets(address(harness), marketId), 33.3e18);

        Market memory lostMarket = morpho.market(Id.wrap(marketId));
        lostMarket.totalSupplyAssets = 1;
        morpho.setMarket(marketId, lostMarket);
        assertEq(adapter.totalAssets(address(harness), marketId), 0);
    }

    function test_deposit_reverts_if_seed_disappears_before_first_supply() public {
        morpho.setPosition(marketId, DEAD_ADDRESS, Position({supplyShares: 0, borrowShares: 0, collateral: 0}));
        asset.mint(1e18);
        assertEq(asset.transfer(address(harness), 1e18), true);

        vm.expectRevert(
            abi.encodeWithSelector(IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(asset), marketId)
        );
        harness.deposit(address(asset), marketId, 1e18);

        assertEq(asset.balanceOf(address(harness)), 1e18);
        assertEq(harness.sentinel(), 123);
    }

    function test_deposit_can_recapitalize_existing_position_after_full_loss() public {
        Market memory lostMarket = morpho.market(Id.wrap(marketId));
        lostMarket.totalSupplyAssets = 0;
        lostMarket.totalSupplyShares = 1_001_000_000;
        morpho.setMarket(marketId, lostMarket);
        morpho.setPosition(marketId, address(harness), Position({supplyShares: 1e6, borrowShares: 0, collateral: 0}));
        asset.mint(1e18);
        assertEq(asset.transfer(address(harness), 1e18), true);

        assertEq(harness.deposit(address(asset), marketId, 1e18), 1e18);
        assertEq(
            morpho.position(Id.wrap(marketId), address(harness)).supplyShares, 1_002_000_000_000_000_000_001_000_000
        );
        assertEq(asset.balanceOf(address(harness)), 0);
        assertEq(harness.sentinel(), 123);
    }

    function test_state_methods_revert_on_direct_call() public {
        vm.expectRevert(IUnderlyingPool.UnderlyingPoolDelegateCallOnly.selector);
        adapter.deposit(address(asset), marketId, 1e18);

        vm.expectRevert(IUnderlyingPool.UnderlyingPoolDelegateCallOnly.selector);
        adapter.withdraw(address(asset), marketId, 1e18, address(this));
    }

    function test_constructor_reverts_for_non_contract_morpho() public {
        address invalidMorpho = makeAddr("invalid morpho");

        vm.expectRevert(
            abi.encodeWithSelector(MorphoMarketV1AdaptiveCurveAdapter.InvalidMorpho.selector, invalidMorpho)
        );
        new MorphoMarketV1AdaptiveCurveAdapter(IMorpho(invalidMorpho), IAdaptiveCurveIrm(address(irm)));
    }

    function test_constructor_reverts_for_non_contract_irm() public {
        address invalidIrm = makeAddr("invalid irm");

        vm.expectRevert(
            abi.encodeWithSelector(MorphoMarketV1AdaptiveCurveAdapter.InvalidAdaptiveCurveIrm.selector, invalidIrm)
        );
        new MorphoMarketV1AdaptiveCurveAdapter(IMorpho(address(morpho)), IAdaptiveCurveIrm(invalidIrm));
    }

    function test_constructor_reverts_for_irm_linked_to_other_morpho() public {
        MockMorphoMarketV1 otherMorpho = new MockMorphoMarketV1();
        MockAdaptiveCurveIrm wrongIrm = new MockAdaptiveCurveIrm(address(otherMorpho));

        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoMarketV1AdaptiveCurveAdapter.InvalidAdaptiveCurveIrm.selector, address(wrongIrm)
            )
        );
        new MorphoMarketV1AdaptiveCurveAdapter(IMorpho(address(morpho)), IAdaptiveCurveIrm(address(wrongIrm)));
    }
}
