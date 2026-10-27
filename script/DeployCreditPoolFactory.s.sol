// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { Script, console2 } from "lib/forge-std/src/Script.sol";

import { CreditPool } from "src/CreditPool.sol";
import { CreditPoolFactory } from "src/CreditPoolFactory.sol";
import { CreditPoolFacet1 } from "src/facets/CreditPoolFacet1.sol";
import { CreditPoolFacet2 } from "src/facets/CreditPoolFacet2.sol";
import { CreditPoolFacet3 } from "src/facets/CreditPoolFacet3.sol";
import { CreditPoolFacet4 } from "src/facets/CreditPoolFacet4.sol";

contract DeployCreditPoolFactory is Script {
    uint256 internal constant CHUNK_SIZE = 24_000;

    function run() external returns (CreditPoolFactory factory) {
        address factoryOwner = vm.envAddress("FACTORY_OWNER");
        address previousFactory = vm.envOr("PREVIOUS_FACTORY", address(0));
        address[] memory underlyingPoolAdapters = vm.envAddress("UNDERLYING_POOL_ADAPTERS", ",");

        vm.startBroadcast(factoryOwner);

        factory = new CreditPoolFactory(factoryOwner, previousFactory);
        _cacheAllCreationCode(factory);
        _deployFacets(factory);
        _registerUnderlyingPoolAdapters(factory, underlyingPoolAdapters);
        factory.freezeConfiguration();

        vm.stopBroadcast();

        console2.log("CreditPoolFactory", address(factory));
        console2.log("owner", factoryOwner);
        console2.log("previousFactory", previousFactory);
        for (uint256 i = 0; i < underlyingPoolAdapters.length; ++i) {
            console2.log("underlyingPoolAdapter", underlyingPoolAdapters[i]);
        }
        console2.log("configurationFrozen", factory.configurationFrozen());
        console2.log("poolVersion", factory.poolVersion());
    }

    function deployAndCacheForTest(
        address owner,
        address previousFactory,
        address[] calldata underlyingPoolAdapters
    )
        external
        returns (CreditPoolFactory factory)
    {
        factory = new CreditPoolFactory(address(this), previousFactory);
        _cacheAllCreationCode(factory);
        _deployFacets(factory);
        _registerUnderlyingPoolAdapters(factory, underlyingPoolAdapters);
        factory.freezeConfiguration();
        factory.transferOwnership(owner);
    }

    function _cacheAllCreationCode(CreditPoolFactory factory) internal {
        _cacheCreationCode(factory, 0, type(CreditPool).creationCode);
        _cacheCreationCode(factory, 1, type(CreditPoolFacet1).creationCode);
        _cacheCreationCode(factory, 2, type(CreditPoolFacet2).creationCode);
        _cacheCreationCode(factory, 3, type(CreditPoolFacet3).creationCode);
        _cacheCreationCode(factory, 4, type(CreditPoolFacet4).creationCode);
    }

    function _deployFacets(CreditPoolFactory factory) internal {
        for (uint8 codeId = 1; codeId <= 4; ++codeId) {
            factory.deployFacet(codeId);
        }
    }

    function _registerUnderlyingPoolAdapters(
        CreditPoolFactory factory,
        address[] memory underlyingPoolAdapters
    ) internal {
        for (uint256 i = 0; i < underlyingPoolAdapters.length; ++i) {
            factory.setUnderlyingPoolAdapter(underlyingPoolAdapters[i], true);
        }
    }

    function _cacheCreationCode(CreditPoolFactory factory, uint8 codeId, bytes memory creationCode) internal {
        factory.cacheCreationCode(codeId, _chunks(creationCode));
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
