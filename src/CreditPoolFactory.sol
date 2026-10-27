// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

import { ICreditPoolTypes } from "src/interfaces/ICreditPool.sol";

contract CodeChunk {
    constructor(bytes memory data) {
        // Store the payload as contract runtime so factories can read it with extcodecopy.
        assembly {
            return(add(data, 0x20), mload(data))
        }
    }
}

contract CreditPoolFactory is Ownable {
    uint256 public constant POOL_VERSION = 5;
    uint256 public constant MAX_CHUNK_SIZE = 24_000;
    uint256 public constant MAX_INIT_CODE_SIZE = 49_152;

    uint8 private constant POOL_CODE_ID = 0;
    uint8 private constant FACET_1_CODE_ID = 1;
    uint8 private constant FACET_4_CODE_ID = 4;

    // Only an off-chain indexer breadcrumb: walk previous factories and index PoolDeployed events.
    // Implementation facets are always deployed from this factory's own cached creation code.
    address private _previousFactory;
    address[4] private _facets;
    mapping(uint8 codeId => address[] chunks) private _creationCodeChunks;
    mapping(address pool => bool) public isPool;
    mapping(address adapter => bool approved) public isUnderlyingPoolAdapterApproved;
    mapping(address adapter => bytes32 codeHash) public underlyingPoolAdapterCodeHash;
    uint256 private _approvedUnderlyingPoolAdapterCount;
    bool public configurationFrozen;

    event CreationCodeCached(uint8 codeId, uint256 chunkCount, uint256 totalSize);
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

    error InvalidCodeId(uint8 codeId);
    error EmptyCreationCode(uint8 codeId);
    error CreationCodeChunkTooLarge(uint8 codeId, uint256 size);
    error InitCodeTooLarge(uint8 codeId, uint256 size);
    error DeploymentFailed(uint8 codeId);
    error FacetAlreadyDeployed(uint8 codeId, address facet);
    error FacetNotDeployed(uint8 codeId);
    error ConfigurationAlreadyFrozen();
    error ConfigurationNotFrozen();
    error InvalidUnderlyingPoolAdapter(address adapter);
    error NoUnderlyingPoolAdapters();
    error UnderlyingPoolAdapterNotApproved(address adapter);
    error UnderlyingPoolAdapterCodeHashMismatch(address adapter, bytes32 expected, bytes32 actual);

    constructor(address owner_, address previousFactory_) Ownable(owner_) {
        _previousFactory = previousFactory_;
    }

    function poolVersion() external pure returns (uint256) {
        return POOL_VERSION;
    }

    function previousFactory() external view returns (address) {
        return _previousFactory;
    }

    function facets() external view returns (address[4] memory) {
        return _facets;
    }

    function setUnderlyingPoolAdapter(address adapter, bool approved) external onlyOwner {
        if (configurationFrozen) revert ConfigurationAlreadyFrozen();
        if (approved && (adapter == address(0) || adapter.code.length == 0)) {
            revert InvalidUnderlyingPoolAdapter(adapter);
        }

        bool wasApproved = isUnderlyingPoolAdapterApproved[adapter];
        if (approved) {
            if (!wasApproved) ++_approvedUnderlyingPoolAdapterCount;
            isUnderlyingPoolAdapterApproved[adapter] = true;
            underlyingPoolAdapterCodeHash[adapter] = adapter.codehash;
        } else if (wasApproved) {
            --_approvedUnderlyingPoolAdapterCount;
            isUnderlyingPoolAdapterApproved[adapter] = false;
            delete underlyingPoolAdapterCodeHash[adapter];
        }
        emit UnderlyingPoolAdapterUpdated(adapter, approved);
    }

    function freezeConfiguration() external onlyOwner {
        if (configurationFrozen) revert ConfigurationAlreadyFrozen();
        if (_creationCodeChunks[POOL_CODE_ID].length == 0) revert EmptyCreationCode(POOL_CODE_ID);
        _requireDeployedFacets();
        if (_approvedUnderlyingPoolAdapterCount == 0) revert NoUnderlyingPoolAdapters();

        configurationFrozen = true;
        emit ConfigurationFrozen(_approvedUnderlyingPoolAdapterCount);
    }

    function cacheCreationCode(uint8 codeId, bytes[] calldata chunks) external onlyOwner {
        if (configurationFrozen) revert ConfigurationAlreadyFrozen();
        _requireValidCodeId(codeId);
        if (chunks.length == 0) revert EmptyCreationCode(codeId);

        uint256 totalSize;
        for (uint256 i = 0; i < chunks.length; ++i) {
            uint256 chunkSize = chunks[i].length;
            if (chunkSize == 0) revert EmptyCreationCode(codeId);
            if (chunkSize > MAX_CHUNK_SIZE) revert CreationCodeChunkTooLarge(codeId, chunkSize);
            totalSize += chunkSize;
        }

        if (totalSize > MAX_INIT_CODE_SIZE) revert InitCodeTooLarge(codeId, totalSize);

        delete _creationCodeChunks[codeId];

        for (uint256 i = 0; i < chunks.length; ++i) {
            address chunk = address(new CodeChunk(chunks[i]));
            _creationCodeChunks[codeId].push(chunk);
        }

        emit CreationCodeCached(codeId, chunks.length, totalSize);
    }

    function deployFacet(uint8 codeId) external onlyOwner returns (address facet) {
        if (configurationFrozen) revert ConfigurationAlreadyFrozen();
        _requireValidFacetCodeId(codeId);

        uint256 facetIndex = codeId - FACET_1_CODE_ID;
        address deployedFacet = _facets[facetIndex];
        if (deployedFacet != address(0)) revert FacetAlreadyDeployed(codeId, deployedFacet);

        facet = _deploy(codeId, _readCreationCode(codeId));
        _facets[facetIndex] = facet;
        emit FacetDeployed(codeId, facet);
    }

    function createPool(ICreditPoolTypes.InitializationParams calldata params) external onlyOwner returns (address pool) {
        if (!configurationFrozen) revert ConfigurationNotFrozen();

        address adapter = params.underlyingPool.adapter;
        if (!isUnderlyingPoolAdapterApproved[adapter]) revert UnderlyingPoolAdapterNotApproved(adapter);

        bytes32 expectedCodeHash = underlyingPoolAdapterCodeHash[adapter];
        bytes32 actualCodeHash = adapter.codehash;
        if (actualCodeHash != expectedCodeHash) {
            revert UnderlyingPoolAdapterCodeHashMismatch(adapter, expectedCodeHash, actualCodeHash);
        }

        address[4] memory cachedFacets = _requireDeployedFacets();

        address[] memory poolFacets = new address[](4);
        poolFacets[0] = cachedFacets[0];
        poolFacets[1] = cachedFacets[1];
        poolFacets[2] = cachedFacets[2];
        poolFacets[3] = cachedFacets[3];

        bytes memory initCode = bytes.concat(
            _readCreationCode(POOL_CODE_ID),
            abi.encode(params, poolFacets)
        );
        if (initCode.length > MAX_INIT_CODE_SIZE) revert InitCodeTooLarge(POOL_CODE_ID, initCode.length);

        pool = _deploy(POOL_CODE_ID, initCode);
        isPool[pool] = true;
        emit PoolDeployed(
            pool,
            params.owner,
            params.asset,
            params.collateral,
            adapter,
            params.underlyingPool.config,
            POOL_VERSION
        );
    }

    function _requireDeployedFacets() private view returns (address[4] memory cachedFacets) {
        cachedFacets = _facets;
        for (uint8 i = 0; i < cachedFacets.length; ++i) {
            address facet = cachedFacets[i];
            if (facet == address(0) || facet.code.length == 0) {
                revert FacetNotDeployed(i + FACET_1_CODE_ID);
            }
        }
    }

    function _readCreationCode(uint8 codeId) private view returns (bytes memory creationCode) {
        address[] storage chunks = _creationCodeChunks[codeId];
        if (chunks.length == 0) revert EmptyCreationCode(codeId);

        uint256 totalSize;
        for (uint256 i = 0; i < chunks.length; ++i) {
            totalSize += chunks[i].code.length;
        }
        if (totalSize == 0) revert EmptyCreationCode(codeId);
        if (totalSize > MAX_INIT_CODE_SIZE) revert InitCodeTooLarge(codeId, totalSize);

        creationCode = new bytes(totalSize);

        uint256 offset;
        for (uint256 i = 0; i < chunks.length; ++i) {
            address chunk = chunks[i];
            uint256 chunkSize = chunk.code.length;
            if (chunkSize == 0) revert EmptyCreationCode(codeId);

            // Copy raw cached creation code from chunk runtime into the assembled byte array.
            assembly {
                extcodecopy(chunk, add(add(creationCode, 0x20), offset), 0, chunkSize)
            }
            offset += chunkSize;
        }
    }

    function _deploy(uint8 codeId, bytes memory initCode) private returns (address deployed) {
        if (initCode.length == 0) revert EmptyCreationCode(codeId);
        if (initCode.length > MAX_INIT_CODE_SIZE) revert InitCodeTooLarge(codeId, initCode.length);

        // Deploy assembled initcode without embedding that initcode in the factory runtime.
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        if (deployed == address(0) || deployed.code.length == 0) revert DeploymentFailed(codeId);
    }

    function _requireValidCodeId(uint8 codeId) private pure {
        if (codeId > FACET_4_CODE_ID) revert InvalidCodeId(codeId);
    }

    function _requireValidFacetCodeId(uint8 codeId) private pure {
        if (codeId < FACET_1_CODE_ID || codeId > FACET_4_CODE_ID) revert InvalidCodeId(codeId);
    }
}
