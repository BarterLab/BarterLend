// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";

import { AaveV3Adapter } from "src/adapters/AaveV3Adapter.sol";
import { IUnderlyingPool } from "src/interfaces/IUnderlyingPool.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";
import { MockAaveToken } from "test/mocks/MockAaveToken.sol";
import { MockToken } from "test/mocks/MockToken.sol";

contract AaveV3AdapterHarness {
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

contract AaveV3AdapterTest is Test {
    MockToken internal asset;
    MockAaveToken internal aToken;
    MockAavePool internal aavePool;
    AaveV3Adapter internal adapter;
    AaveV3AdapterHarness internal harness;
    bytes32 internal config;

    function setUp() public {
        asset = new MockToken();
        aToken = new MockAaveToken(asset, 0);
        aavePool = new MockAavePool(asset, aToken);
        adapter = new AaveV3Adapter();
        harness = new AaveV3AdapterHarness(adapter);
        config = bytes32(uint256(uint160(address(aToken))));
    }

    function test_validate_accepts_matching_reserve() public view {
        adapter.validate(address(asset), config);
    }

    function test_validate_reverts_for_config_with_high_bits() public {
        bytes32 invalidConfig = bytes32((uint256(1) << 160) | uint160(address(aToken)));

        vm.expectRevert(
            abi.encodeWithSelector(IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(asset), invalidConfig)
        );
        adapter.validate(address(asset), invalidConfig);
    }

    function test_validate_reverts_for_wrong_asset() public {
        MockToken wrongAsset = new MockToken();

        vm.expectRevert(
            abi.encodeWithSelector(
                IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(wrongAsset), config
            )
        );
        adapter.validate(address(wrongAsset), config);
    }

    function test_validate_reverts_for_a_token_without_pool() public {
        MockAaveToken wrongAToken = new MockAaveToken(asset, 0);
        bytes32 wrongConfig = bytes32(uint256(uint160(address(wrongAToken))));

        vm.expectRevert(
            abi.encodeWithSelector(
                IUnderlyingPool.InvalidUnderlyingPoolConfig.selector, address(asset), wrongConfig
            )
        );
        adapter.validate(address(asset), wrongConfig);
    }

    function test_deposit_and_withdraw_use_harness_position_without_writing_storage() public {
        address receiver = makeAddr("receiver");
        asset.mint(150e18);
        assertEq(asset.transfer(address(harness), 150e18), true);

        assertEq(harness.deposit(address(asset), config, 100e18), 100e18);
        assertEq(asset.balanceOf(address(harness)), 50e18);
        assertEq(aToken.balanceOf(address(harness)), 100e18);
        assertEq(asset.allowance(address(harness), address(aavePool)), 0);
        assertEq(harness.sentinel(), 123);

        aToken.rebase(address(harness), 10e18);
        assertEq(adapter.totalAssets(address(harness), config), 110e18);

        assertEq(harness.withdraw(address(asset), config, 40e18, receiver), 70e18);
        assertEq(asset.balanceOf(receiver), 40e18);
        assertEq(aToken.balanceOf(address(harness)), 70e18);
        assertEq(harness.sentinel(), 123);
    }

    function test_shared_adapter_keeps_pool_positions_isolated() public {
        AaveV3AdapterHarness otherHarness = new AaveV3AdapterHarness(adapter);
        asset.mint(300e18);
        assertEq(asset.transfer(address(harness), 100e18), true);
        assertEq(asset.transfer(address(otherHarness), 200e18), true);

        assertEq(harness.deposit(address(asset), config, 100e18), 100e18);
        assertEq(otherHarness.deposit(address(asset), config, 200e18), 200e18);

        aToken.rebase(address(harness), 25e18);
        assertEq(adapter.totalAssets(address(harness), config), 125e18);
        assertEq(adapter.totalAssets(address(otherHarness), config), 200e18);
        assertEq(aToken.balanceOf(address(adapter)), 0);
    }

    function test_shared_adapter_supports_multiple_aave_pools() public {
        MockAaveToken secondAToken = new MockAaveToken(asset, 0);
        MockAavePool secondAavePool = new MockAavePool(asset, secondAToken);
        AaveV3AdapterHarness secondHarness = new AaveV3AdapterHarness(adapter);
        bytes32 secondConfig = bytes32(uint256(uint160(address(secondAToken))));

        asset.mint(300e18);
        assertEq(asset.transfer(address(harness), 100e18), true);
        assertEq(asset.transfer(address(secondHarness), 200e18), true);

        assertEq(harness.deposit(address(asset), config, 100e18), 100e18);
        assertEq(secondHarness.deposit(address(asset), secondConfig, 200e18), 200e18);

        aToken.rebase(address(harness), 25e18);
        secondAToken.rebase(address(secondHarness), 50e18);
        assertEq(adapter.totalAssets(address(harness), config), 125e18);
        assertEq(adapter.totalAssets(address(secondHarness), secondConfig), 250e18);
        assertEq(asset.allowance(address(harness), address(aavePool)), 0);
        assertEq(asset.allowance(address(secondHarness), address(secondAavePool)), 0);
        assertEq(aToken.balanceOf(address(adapter)), 0);
        assertEq(secondAToken.balanceOf(address(adapter)), 0);
    }

    function test_state_methods_revert_on_direct_call() public {
        vm.expectRevert(IUnderlyingPool.UnderlyingPoolDelegateCallOnly.selector);
        adapter.deposit(address(asset), config, 1e18);

        vm.expectRevert(IUnderlyingPool.UnderlyingPoolDelegateCallOnly.selector);
        adapter.withdraw(address(asset), config, 1e18, address(this));
    }
}
