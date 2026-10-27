// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { IERC20Metadata } from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { DataTypes } from "lib/aave-v3-origin/src/contracts/protocol/libraries/types/DataTypes.sol";
import { IPool as IAavePool } from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";

import { DeployCreditPoolFactory } from "script/DeployCreditPoolFactory.s.sol";
import { AaveV3Adapter } from "src/adapters/AaveV3Adapter.sol";
import { ChainlinkPriceOracle } from "src/ChainlinkPriceOracle.sol";
import { ICreditPoolConstants, ICreditPoolTypes } from "src/interfaces/ICreditPool.sol";
import { UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";
import { MarketsConfigParams } from "src/lib/MarketsConfig.sol";
import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolFactory } from "src/CreditPoolFactory.sol";

contract TestDeployCreditPoolFactoryScript is Test, ICreditPoolTypes, ICreditPoolConstants {
    uint256 internal constant FORK_BLOCK = 25_071_151;

    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant AUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant USDC_USD_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    address internal factoryOwner = makeAddr("Factory Owner");
    address internal poolOwner = makeAddr("Pool Owner");
    address internal previousFactory = makeAddr("Previous Factory");

    function setUp() public {
        vm.skip(!vm.envExists("ETH_RPC_URL"), "ETH_RPC_URL is not set");
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), FORK_BLOCK);
    }

    function test_deploy_factory_script_and_create_usdc_weth_pool_on_mainnet_fork() public {
        assertEq(block.chainid, 1);
        assertEq(block.number, 25_071_151);
        assertEq(IERC20Metadata(USDC).decimals(), 6);
        assertEq(IERC20Metadata(WETH).decimals(), 18);
        assertGt(PERMIT2.code.length, 0);

        DataTypes.ReserveDataLegacy memory reserveData = IAavePool(AAVE_POOL).getReserveData(USDC);
        assertEq(reserveData.aTokenAddress, AUSDC);

        ChainlinkPriceOracle oracle = new ChainlinkPriceOracle(WETH, USDC, ETH_USD_FEED, USDC_USD_FEED);
        AaveV3Adapter adapter = new AaveV3Adapter();
        address[] memory underlyingPoolAdapters = new address[](1);
        underlyingPoolAdapters[0] = address(adapter);
        DeployCreditPoolFactory deployScript = new DeployCreditPoolFactory();
        CreditPoolFactory factory =
            deployScript.deployAndCacheForTest(factoryOwner, previousFactory, underlyingPoolAdapters);

        assertEq(factory.owner(), factoryOwner);
        assertEq(factory.previousFactory(), previousFactory);
        assertEq(factory.poolVersion(), 5);
        assertEq(factory.configurationFrozen(), true);
        assertEq(factory.isUnderlyingPoolAdapterApproved(address(adapter)), true);
        assertEq(factory.underlyingPoolAdapterCodeHash(address(adapter)), address(adapter).codehash);
        address[4] memory facets = factory.facets();
        assertEq(facets[0] == address(0), false);
        assertEq(facets[1] == address(0), false);
        assertEq(facets[2] == address(0), false);
        assertEq(facets[3] == address(0), false);

        vm.prank(factoryOwner); address deployed = factory.createPool(_params(address(oracle), address(adapter)));

        CreditPool pool = CreditPool(deployed);

        assertEq(pool.version(), 5);
        assertEq(pool.owner(), poolOwner);
        assertEq(pool.asset(), USDC);
        assertEq(pool.collateral(), WETH);
        UnderlyingPoolConfig memory underlyingPool = pool.underlyingPool();
        assertEq(underlyingPool.adapter, address(adapter));
        assertEq(underlyingPool.config, bytes32(uint256(uint160(AUSDC))));
        assertEq(pool.permit2(), PERMIT2);
        assertEq(pool.priceOracle(), address(oracle));
        assertGt(deployed.code.length, 10_000);
    }

    function _params(address oracle, address adapter) internal view returns (InitializationParams memory) {
        return InitializationParams({
            owner: poolOwner,
            permit2: PERMIT2,
            asset: USDC,
            underlyingPool: UnderlyingPoolConfig({
                adapter: adapter,
                config: bytes32(uint256(uint160(AUSDC)))
            }),
            collateral: WETH,
            priceOracle: oracle,
            stalePriceWindow: 24 hours,
            protocolFee: 0,
            totalCollateralCap: type(uint128).max,
            provideOrderMinAmount: 1e6,
            borrowOrderMinAmount: 1e6,
            maxActiveProvideOrders: 8,
            maxActiveBorrowOrders: 1,
            borrowLTV: UNIT * 50 / 100,
            liquidationLTV: UNIT * 50 / 100,
            liquidationDiscountMin: UNIT * 5 / 100,
            liquidationDiscountMax: UNIT * 20 / 100,
            minDebtRemainingAfterLiquidation: 10e6,
            liquidationGracePeriod: 1 days,
            marketsConfig: MarketsConfigParams({
                durations: [YEAR, YEAR, YEAR],
                active: [uint8(3), 3, 3],
                extensions: [uint64(0), 0, 0]
            })
        });
    }
}
