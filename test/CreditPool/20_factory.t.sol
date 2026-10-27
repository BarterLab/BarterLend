// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Test } from "lib/forge-std/src/Test.sol";
import { Vm } from "lib/forge-std/src/Vm.sol";
import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import { DeployPermit2 } from "lib/permit2/test/utils/DeployPermit2.sol";

import { IPermit2 } from "lib/permit2/src/interfaces/IPermit2.sol";

import { MarketsConfigParams } from "src/lib/MarketsConfig.sol";
import { ICreditPoolConstants, ICreditPoolTypes, ICreditPoolErrors } from "src/interfaces/ICreditPool.sol";
import { UnderlyingPoolConfig } from "src/interfaces/IUnderlyingPool.sol";
import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolFactory } from "src/CreditPoolFactory.sol";
import { AaveV3Adapter } from "src/adapters/AaveV3Adapter.sol";
import { CreditPoolFacet1 } from "src/facets/CreditPoolFacet1.sol";
import { CreditPoolFacet2 } from "src/facets/CreditPoolFacet2.sol";
import { CreditPoolFacet3 } from "src/facets/CreditPoolFacet3.sol";
import { CreditPoolFacet4 } from "src/facets/CreditPoolFacet4.sol";

import { MockToken } from "test/mocks/MockToken.sol";
import { MockAaveToken } from "test/mocks/MockAaveToken.sol";
import { MockAavePool } from "test/mocks/MockAavePool.sol";
import { MockPriceOracle } from "test/mocks/MockPriceOracle.sol";

contract TestCreditPoolFactory is Test, ICreditPoolTypes, ICreditPoolConstants {
    uint256 internal constant CHUNK_SIZE = 24_000;

    event FacetDeployed(uint8 codeId, address indexed facet);
    event UnderlyingPoolAdapterUpdated(address indexed adapter, bool approved);
    event ConfigurationFrozen(uint256 underlyingPoolAdapterCount);
    event PoolDeployed(
        address indexed pool,
        address indexed owner,
        address indexed asset,
        address collateral,
        address underlyingPoolAdapter,
        bytes32 underlyingPoolConfig,
        uint256 version
    );

    MockToken internal collateral;
    MockToken internal asset;
    MockAaveToken internal aaveToken;
    MockAavePool internal aavePool;
    AaveV3Adapter internal aaveAdapter;
    MockPriceOracle internal priceOracle;
    DeployPermit2 internal deployPermit2;
    IPermit2 internal permit2;
    CreditPoolFactory internal factory;

    address internal factoryOwner = makeAddr("Factory Owner");
    address internal poolOwner = makeAddr("Pool Owner");
    address internal user = makeAddr("User");

    function setUp() public {
        vm.warp(1);

        collateral = new MockToken();
        asset = new MockToken();
        aaveToken = new MockAaveToken(asset, 10);
        aavePool = new MockAavePool(asset, aaveToken);
        aaveAdapter = new AaveV3Adapter();
        priceOracle = new MockPriceOracle(address(collateral), address(asset));
        deployPermit2 = new DeployPermit2();
        permit2 = IPermit2(deployPermit2.run());
        factory = new CreditPoolFactory(factoryOwner, address(0));
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(aaveAdapter), true);
    }

    function test_version_returns_current_pool_version() public {
        CreditPool pool = new CreditPool(_params(), _directFacets());

        assertEq(pool.getBorrowLTV(), 0.5e18);
        assertEq(pool.getLiquidationLTV(), 0.5e18);
        assertEq(pool.version(), 5);
        assertEq(factory.poolVersion(), 5);
    }

    function test_previous_factory_can_be_empty() public view {
        assertEq(factory.previousFactory(), address(0));
    }

    function test_previous_factory_is_stored() public {
        CreditPoolFactory nextFactory = new CreditPoolFactory(factoryOwner, address(factory));

        assertEq(nextFactory.previousFactory(), address(factory));
    }

    function test_only_owner_can_cache_creation_code() public {
        bytes[] memory chunks = _chunks(type(CreditPool).creationCode);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user); factory.cacheCreationCode(0, chunks);
    }

    function test_only_owner_can_deploy_facet() public {
        _cacheCreationCode(factory, 1, type(CreditPoolFacet1).creationCode);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user); factory.deployFacet(1);
    }

    function test_deploy_facet_reverts_for_invalid_code_id() public {
        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.InvalidCodeId.selector, 0));
        vm.prank(factoryOwner); factory.deployFacet(0);

        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.InvalidCodeId.selector, 5));
        vm.prank(factoryOwner); factory.deployFacet(5);
    }

    function test_deploy_facet_reverts_without_cached_creation_code() public {
        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.EmptyCreationCode.selector, 1));
        vm.prank(factoryOwner); factory.deployFacet(1);
    }

    function test_deploy_facet_reverts_when_creation_code_returns_empty_runtime() public {
        bytes[] memory chunks = new bytes[](1);
        chunks[0] = hex"00";
        vm.prank(factoryOwner); factory.cacheCreationCode(1, chunks);

        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.DeploymentFailed.selector, 1));
        vm.prank(factoryOwner); factory.deployFacet(1);

        _cacheCreationCode(factory, 1, type(CreditPoolFacet1).creationCode);
        vm.prank(factoryOwner); address facet = factory.deployFacet(1);

        assertGt(facet.code.length, 0);
    }

    function test_deploy_facet_emits_event_and_stores_address() public {
        _cacheCreationCode(factory, 1, type(CreditPoolFacet1).creationCode);

        vm.expectEmit(false, false, false, true, address(factory));
        emit FacetDeployed(1, address(0));
        vm.prank(factoryOwner); address facet = factory.deployFacet(1);

        address[4] memory deployedFacets = factory.facets();
        assertEq(deployedFacets[0], facet);
        assertGt(facet.code.length, 0);
    }

    function test_deploy_facet_reverts_when_code_id_is_already_deployed() public {
        _cacheCreationCode(factory, 1, type(CreditPoolFacet1).creationCode);
        vm.prank(factoryOwner); address facet = factory.deployFacet(1);

        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.FacetAlreadyDeployed.selector, 1, facet));
        vm.prank(factoryOwner); factory.deployFacet(1);
    }

    function test_only_owner_can_create_pool() public {
        InitializationParams memory params = _params();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user); factory.createPool(params);
    }

    function test_only_owner_can_set_underlying_pool_adapter() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user); factory.setUnderlyingPoolAdapter(address(aaveAdapter), false);
    }

    function test_only_owner_can_freeze_configuration() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user); factory.freezeConfiguration();
    }

    function test_set_underlying_pool_adapter_enables_and_disables_adapter() public {
        vm.expectEmit(true, false, false, true, address(factory));
        emit UnderlyingPoolAdapterUpdated(address(aaveAdapter), false);
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(aaveAdapter), false);

        assertEq(factory.isUnderlyingPoolAdapterApproved(address(aaveAdapter)), false);
        assertEq(factory.underlyingPoolAdapterCodeHash(address(aaveAdapter)), bytes32(0));

        vm.expectEmit(true, false, false, true, address(factory));
        emit UnderlyingPoolAdapterUpdated(address(aaveAdapter), true);
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(aaveAdapter), true);

        assertEq(factory.isUnderlyingPoolAdapterApproved(address(aaveAdapter)), true);
        assertEq(factory.underlyingPoolAdapterCodeHash(address(aaveAdapter)), address(aaveAdapter).codehash);
    }

    function test_set_underlying_pool_adapter_reverts_for_invalid_address() public {
        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.InvalidUnderlyingPoolAdapter.selector, address(0)));
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(0), true);

        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.InvalidUnderlyingPoolAdapter.selector, user));
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(user, true);
    }

    function test_owner_can_reapprove_changed_adapter_before_freeze() public {
        bytes32 initialCodeHash = address(aaveAdapter).codehash;
        vm.etch(address(aaveAdapter), hex"00");

        assertEq(address(aaveAdapter).codehash == initialCodeHash, false);

        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(aaveAdapter), true);

        assertEq(factory.isUnderlyingPoolAdapterApproved(address(aaveAdapter)), true);
        assertEq(factory.underlyingPoolAdapterCodeHash(address(aaveAdapter)), address(aaveAdapter).codehash);
    }

    function test_freeze_configuration_reverts_without_underlying_pool_adapters() public {
        _cacheAllCreationCode(factory);
        _deployAllFacets(factory);
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(aaveAdapter), false);

        vm.expectRevert(CreditPoolFactory.NoUnderlyingPoolAdapters.selector);
        vm.prank(factoryOwner); factory.freezeConfiguration();
    }

    function test_freeze_configuration_reverts_without_pool_creation_code() public {
        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.EmptyCreationCode.selector, 0));
        vm.prank(factoryOwner); factory.freezeConfiguration();
    }

    function test_freeze_configuration_reverts_until_all_facets_are_deployed() public {
        _cacheAllCreationCode(factory);

        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.FacetNotDeployed.selector, 1));
        vm.prank(factoryOwner); factory.freezeConfiguration();

        for (uint8 codeId = 1; codeId <= 3; ++codeId) {
            vm.prank(factoryOwner); factory.deployFacet(codeId);
        }

        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.FacetNotDeployed.selector, 4));
        vm.prank(factoryOwner); factory.freezeConfiguration();
    }

    function test_freeze_configuration_emits_event_and_sets_state() public {
        _cacheAllCreationCode(factory);
        _deployAllFacets(factory);

        vm.expectEmit(false, false, false, true, address(factory));
        emit ConfigurationFrozen(1);
        vm.prank(factoryOwner); factory.freezeConfiguration();

        assertEq(factory.configurationFrozen(), true);
    }

    function test_freeze_configuration_reverts_when_already_frozen() public {
        _freezeFactoryConfiguration(factory);

        vm.expectRevert(CreditPoolFactory.ConfigurationAlreadyFrozen.selector);
        vm.prank(factoryOwner); factory.freezeConfiguration();
    }

    function test_frozen_configuration_rejects_adapter_code_and_facet_changes() public {
        _freezeFactoryConfiguration(factory);

        vm.expectRevert(CreditPoolFactory.ConfigurationAlreadyFrozen.selector);
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(aaveAdapter), false);

        bytes[] memory chunks = _chunks(type(CreditPool).creationCode);
        vm.expectRevert(CreditPoolFactory.ConfigurationAlreadyFrozen.selector);
        vm.prank(factoryOwner); factory.cacheCreationCode(0, chunks);

        vm.expectRevert(CreditPoolFactory.ConfigurationAlreadyFrozen.selector);
        vm.prank(factoryOwner); factory.deployFacet(1);
    }

    function test_create_pool_reverts_before_configuration_is_frozen() public {
        vm.expectRevert(CreditPoolFactory.ConfigurationNotFrozen.selector);
        vm.prank(factoryOwner); factory.createPool(_params());
    }

    function test_create_pool_reverts_when_underlying_pool_adapter_is_not_approved() public {
        AaveV3Adapter unapprovedAdapter = new AaveV3Adapter();
        InitializationParams memory params = _params(address(unapprovedAdapter));
        _freezeFactoryConfiguration(factory);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditPoolFactory.UnderlyingPoolAdapterNotApproved.selector,
                address(unapprovedAdapter)
            )
        );
        vm.prank(factoryOwner); factory.createPool(params);
    }

    function test_create_pool_reverts_after_underlying_pool_adapter_is_disabled() public {
        AaveV3Adapter approvedAdapter = new AaveV3Adapter();
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(approvedAdapter), true);
        vm.prank(factoryOwner); factory.setUnderlyingPoolAdapter(address(aaveAdapter), false);
        _freezeFactoryConfiguration(factory);

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditPoolFactory.UnderlyingPoolAdapterNotApproved.selector,
                address(aaveAdapter)
            )
        );
        vm.prank(factoryOwner); factory.createPool(_params());
    }

    function test_create_pool_reverts_when_approved_adapter_code_changes_after_freeze() public {
        _freezeFactoryConfiguration(factory);
        bytes32 expectedCodeHash = address(aaveAdapter).codehash;
        vm.etch(address(aaveAdapter), hex"00");
        bytes32 actualCodeHash = address(aaveAdapter).codehash;

        vm.expectRevert(
            abi.encodeWithSelector(
                CreditPoolFactory.UnderlyingPoolAdapterCodeHashMismatch.selector,
                address(aaveAdapter),
                expectedCodeHash,
                actualCodeHash
            )
        );
        vm.prank(factoryOwner); factory.createPool(_params());
    }

    function test_cache_creation_code_reverts_when_chunk_is_too_large() public {
        bytes[] memory chunks = new bytes[](1);
        chunks[0] = new bytes(24_001);

        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.CreationCodeChunkTooLarge.selector, 0, 24_001));
        vm.prank(factoryOwner); factory.cacheCreationCode(0, chunks);
    }

    function test_cache_creation_code_reverts_when_init_code_is_too_large() public {
        bytes[] memory chunks = new bytes[](3);
        chunks[0] = new bytes(20_000);
        chunks[1] = new bytes(20_000);
        chunks[2] = new bytes(20_000);

        vm.expectRevert(abi.encodeWithSelector(CreditPoolFactory.InitCodeTooLarge.selector, 0, 60_000));
        vm.prank(factoryOwner); factory.cacheCreationCode(0, chunks);
    }

    function test_initialization_rejects_borrow_ltv_above_liquidation_ltv() public {
        InitializationParams memory params = _params();
        params.borrowLTV = params.liquidationLTV + 1;
        vm.expectRevert(ICreditPoolErrors.InvalidBorrowLTV.selector);
        new CreditPool(params, new address[](4));
    }

    function test_create_pool_accepts_zero_borrow_ltv() public {
        _freezeFactoryConfiguration(factory);
        InitializationParams memory params = _params();
        params.borrowLTV = 0;
        vm.prank(factoryOwner); address deployed = factory.createPool(params);
        assertEq(CreditPool(deployed).getBorrowLTV(), 0);
        assertEq(CreditPool(deployed).getLiquidationLTV(), 0.5e18);
    }

    function test_create_pool_uses_deployed_facets_emits_event_and_initializes_pool() public {
        _freezeFactoryConfiguration(factory);
        InitializationParams memory params = _params();

        vm.expectEmit(false, true, true, true, address(factory));
        emit PoolDeployed(
            address(0),
            params.owner,
            params.asset,
            params.collateral,
            params.underlyingPool.adapter,
            params.underlyingPool.config,
            5
        );
        vm.recordLogs();
        vm.prank(factoryOwner); address deployed = factory.createPool(params);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 deploymentEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == PoolDeployed.selector) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(deployed))));
                ++deploymentEvents;
            }
        }
        assertEq(deploymentEvents, 1);

        CreditPool pool = CreditPool(deployed);
        address[4] memory cachedFacets = factory.facets();

        assertEq(pool.getBorrowLTV(), 0.5e18);
        assertEq(pool.getLiquidationLTV(), 0.5e18);
        assertEq(pool.version(), 5);
        assertEq(pool.owner(), poolOwner);
        assertEq(pool.asset(), address(asset));
        assertEq(pool.collateral(), address(collateral));
        assertEq(pool.permit2(), address(permit2));
        assertEq(pool.priceOracle(), address(priceOracle));
        assertEq(factory.isPool(deployed), true);
        assertEq(factory.isPool(user), false);
        UnderlyingPoolConfig memory underlyingPool = pool.underlyingPool();
        assertEq(underlyingPool.adapter, address(aaveAdapter));
        assertEq(underlyingPool.config, bytes32(uint256(uint160(address(aaveToken)))));
        assertEq(cachedFacets[0] == address(0), false);
        assertEq(cachedFacets[1] == address(0), false);
        assertEq(cachedFacets[2] == address(0), false);
        assertEq(cachedFacets[3] == address(0), false);
        assertGt(deployed.code.length, 10_000);
    }

    function test_create_pool_reuses_deployed_facets() public {
        _freezeFactoryConfiguration(factory);

        vm.prank(factoryOwner); address firstPool = factory.createPool(_params());
        address[4] memory firstFacets = factory.facets();

        vm.prank(factoryOwner); address secondPool = factory.createPool(_params());
        address[4] memory secondFacets = factory.facets();

        assertEq(firstPool == secondPool, false);
        assertEq(secondFacets[0], firstFacets[0]);
        assertEq(secondFacets[1], firstFacets[1]);
        assertEq(secondFacets[2], firstFacets[2]);
        assertEq(secondFacets[3], firstFacets[3]);
    }

    function test_factory_deploys_local_facets_when_previous_factory_is_set() public {
        _freezeFactoryConfiguration(factory);
        vm.prank(factoryOwner); factory.createPool(_params());
        address[4] memory previousFacets = factory.facets();

        CreditPoolFactory nextFactory = new CreditPoolFactory(factoryOwner, address(factory));
        _cacheAllCreationCode(nextFactory);
        _deployAllFacets(nextFactory);
        vm.prank(factoryOwner); nextFactory.setUnderlyingPoolAdapter(address(aaveAdapter), true);
        vm.prank(factoryOwner); nextFactory.freezeConfiguration();

        vm.prank(factoryOwner); address deployed = nextFactory.createPool(_params());
        address[4] memory localFacets = nextFactory.facets();

        assertEq(CreditPool(deployed).version(), 5);
        assertEq(nextFactory.previousFactory(), address(factory));
        assertEq(localFacets[0] == address(0), false);
        assertEq(localFacets[1] == address(0), false);
        assertEq(localFacets[2] == address(0), false);
        assertEq(localFacets[3] == address(0), false);
        assertEq(localFacets[0] == previousFacets[0], false);
        assertEq(localFacets[1] == previousFacets[1], false);
        assertEq(localFacets[2] == previousFacets[2], false);
        assertEq(localFacets[3] == previousFacets[3], false);
    }

    function _params() internal view returns (InitializationParams memory) {
        return _params(address(aaveAdapter));
    }

    function _params(address underlyingPoolAdapter) internal view returns (InitializationParams memory) {
        return InitializationParams({
            owner: poolOwner,
            permit2: address(permit2),
            asset: address(asset),
            underlyingPool: UnderlyingPoolConfig({
                adapter: underlyingPoolAdapter,
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
    }

    function _directFacets() internal returns (address[] memory facets) {
        facets = new address[](4);
        facets[0] = address(new CreditPoolFacet1());
        facets[1] = address(new CreditPoolFacet2());
        facets[2] = address(new CreditPoolFacet3());
        facets[3] = address(new CreditPoolFacet4());
    }

    function _cacheAllCreationCode(CreditPoolFactory target) internal {
        _cacheCreationCode(target, 0, type(CreditPool).creationCode);
        _cacheCreationCode(target, 1, type(CreditPoolFacet1).creationCode);
        _cacheCreationCode(target, 2, type(CreditPoolFacet2).creationCode);
        _cacheCreationCode(target, 3, type(CreditPoolFacet3).creationCode);
        _cacheCreationCode(target, 4, type(CreditPoolFacet4).creationCode);
    }

    function _deployAllFacets(CreditPoolFactory target) internal {
        for (uint8 codeId = 1; codeId <= 4; ++codeId) {
            vm.prank(factoryOwner); target.deployFacet(codeId);
        }
    }

    function _freezeFactoryConfiguration(CreditPoolFactory target) internal {
        _cacheAllCreationCode(target);
        _deployAllFacets(target);
        vm.prank(factoryOwner); target.freezeConfiguration();
    }

    function _cacheCreationCode(CreditPoolFactory target, uint8 codeId, bytes memory creationCode) internal {
        vm.prank(factoryOwner); target.cacheCreationCode(codeId, _chunks(creationCode));
    }

    function _chunks(bytes memory creationCode) internal pure returns (bytes[] memory chunks) {
        uint256 count = (creationCode.length + CHUNK_SIZE - 1) / CHUNK_SIZE;
        chunks = new bytes[](count);

        for (uint256 i = 0; i < count; ++i) {
            uint256 offset = i * CHUNK_SIZE;
            uint256 chunkSize = CHUNK_SIZE;
            if (offset + chunkSize > creationCode.length) chunkSize = creationCode.length - offset;

            bytes memory chunk = new bytes(chunkSize);
            for (uint256 j = 0; j < chunkSize; ++j) {
                chunk[j] = creationCode[offset + j];
            }
            chunks[i] = chunk;
        }
    }
}
