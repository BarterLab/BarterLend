// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {Test} from "lib/forge-std/src/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IMorpho, Id, MarketParams} from "lib/morpho-blue-irm/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {IAdaptiveCurveIrm} from "lib/morpho-blue-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveIrm.sol";

import {MorphoMarketV1AdaptiveCurveAdapter} from "src/adapters/MorphoMarketV1AdaptiveCurveAdapter.sol";
import {IUnderlyingPool} from "src/interfaces/IUnderlyingPool.sol";

contract MorphoMarketV1ForkHarness {
    IUnderlyingPool private immutable ADAPTER;

    constructor(IUnderlyingPool adapter) {
        ADAPTER = adapter;
    }

    function deposit(address asset, bytes32 config, uint256 assets) external returns (uint256) {
        return abi.decode(_delegate(abi.encodeCall(IUnderlyingPool.deposit, (asset, config, assets))), (uint256));
    }

    function withdraw(address asset, bytes32 config, uint256 assets, address receiver) external returns (uint256) {
        return
            abi.decode(
                _delegate(abi.encodeCall(IUnderlyingPool.withdraw, (asset, config, assets, receiver))), (uint256)
            );
    }

    function _delegate(bytes memory data) private returns (bytes memory returnData) {
        (bool success, bytes memory result) = address(ADAPTER).delegatecall(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }
}

contract MorphoMarketV1AdaptiveCurveAdapterForkTest is Test {
    uint256 private constant FORK_BLOCK = 25_071_151;

    address private constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address private constant ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes32 private constant MARKET_ID = 0xb8fc70e82bc5bb53e773626fcc6a23f7eefa036918d7ef216ecfb1950a94a85e;

    function setUp() public {
        vm.skip(!vm.envExists("ETH_RPC_URL"), "ETH_RPC_URL is not set");
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
    }

    function test_real_morpho_market_supply_accrual_and_withdraw() public {
        IMorpho morpho = IMorpho(MORPHO);
        MorphoMarketV1AdaptiveCurveAdapter adapter =
            new MorphoMarketV1AdaptiveCurveAdapter(morpho, IAdaptiveCurveIrm(ADAPTIVE_CURVE_IRM));
        adapter.validate(WETH, MARKET_ID);

        MarketParams memory params = morpho.idToMarketParams(Id.wrap(MARKET_ID));
        assertEq(params.loanToken, WETH);
        assertEq(params.irm, ADAPTIVE_CURVE_IRM);

        MorphoMarketV1ForkHarness harness = new MorphoMarketV1ForkHarness(adapter);
        deal(WETH, address(harness), 100e18);

        uint256 suppliedAssets = harness.deposit(WETH, MARKET_ID, 100e18);
        assertGt(suppliedAssets, 0);
        assertEq(adapter.totalAssets(address(harness), MARKET_ID), suppliedAssets);

        vm.warp(block.timestamp + 30 days);
        uint256 expectedAssetsAfterAccrual = adapter.totalAssets(address(harness), MARKET_ID);
        morpho.accrueInterest(params);
        assertEq(adapter.totalAssets(address(harness), MARKET_ID), expectedAssetsAfterAccrual);
        assertGe(expectedAssetsAfterAccrual, suppliedAssets);

        address receiver = makeAddr("receiver");
        uint256 remainingAssets = harness.withdraw(WETH, MARKET_ID, 10e18, receiver);
        assertEq(IERC20(WETH).balanceOf(receiver), 10e18);
        assertEq(adapter.totalAssets(address(harness), MARKET_ID), remainingAssets);
    }
}
