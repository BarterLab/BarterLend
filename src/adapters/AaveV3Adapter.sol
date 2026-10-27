// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPool } from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";

import { IAaveV3AToken } from "src/interfaces/IAaveV3AToken.sol";
import { IUnderlyingPool } from "src/interfaces/IUnderlyingPool.sol";

contract AaveV3Adapter is IUnderlyingPool {
    using SafeERC20 for IERC20;

    address private immutable SELF;

    constructor() {
        // Capturing the implementation address keeps state methods delegatecall-only without storage writes.
        SELF = address(this);
    }

    modifier onlyDelegateCall() {
        _checkDelegateCall();
        _;
    }

    function validate(address asset, bytes32 config) external view {
        _reserve(asset, config);
    }

    function totalAssets(address account, bytes32 config) external view returns (uint256) {
        return IERC20(_aToken(address(0), config)).balanceOf(account);
    }

    function deposit(address asset, bytes32 config, uint256 assets)
        external
        onlyDelegateCall
        returns (uint256 totalAssetsAfter)
    {
        (address aToken, IPool aavePool) = _reserve(asset, config);
        IERC20 underlying = IERC20(asset);
        uint256 balanceBefore = underlying.balanceOf(address(this));

        underlying.forceApprove(address(aavePool), assets);
        aavePool.supply(asset, assets, address(this), 0);

        uint256 balanceAfter = underlying.balanceOf(address(this));
        uint256 deposited = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : 0;
        if (deposited != assets) revert UnderlyingPoolDepositFailed(assets, deposited);

        return IERC20(aToken).balanceOf(address(this));
    }

    function withdraw(address asset, bytes32 config, uint256 assets, address receiver)
        external
        onlyDelegateCall
        returns (uint256 totalAssetsAfter)
    {
        (address aToken, IPool aavePool) = _reserve(asset, config);
        uint256 balanceBefore = IERC20(asset).balanceOf(receiver);
        uint256 withdrawn = aavePool.withdraw(asset, assets, receiver);
        uint256 balanceAfter = IERC20(asset).balanceOf(receiver);

        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (withdrawn != assets || received != assets) revert UnderlyingPoolWithdrawFailed(assets, received);

        return IERC20(aToken).balanceOf(address(this));
    }

    function _reserve(address asset, bytes32 config) private view returns (address aToken, IPool aavePool) {
        aToken = _aToken(asset, config);
        if (asset == address(0) || asset.code.length == 0 || aToken.code.length == 0) {
            revert InvalidUnderlyingPoolConfig(asset, config);
        }

        try IAaveV3AToken(aToken).POOL() returns (IPool pool) {
            aavePool = pool;
        } catch {
            revert InvalidUnderlyingPoolConfig(asset, config);
        }
        if (address(aavePool) == address(0) || address(aavePool).code.length == 0) {
            revert InvalidUnderlyingPoolConfig(asset, config);
        }

        try aavePool.getReserveAToken(asset) returns (address reserveAToken) {
            if (reserveAToken != aToken) revert InvalidUnderlyingPoolConfig(asset, config);
        } catch {
            revert InvalidUnderlyingPoolConfig(asset, config);
        }
        try IAaveV3AToken(aToken).UNDERLYING_ASSET_ADDRESS() returns (address underlying) {
            if (underlying != asset) revert InvalidUnderlyingPoolConfig(asset, config);
        } catch {
            revert InvalidUnderlyingPoolConfig(asset, config);
        }
    }

    function _checkDelegateCall() private view {
        if (address(this) == SELF) revert UnderlyingPoolDelegateCallOnly();
    }

    function _aToken(address asset, bytes32 config) private pure returns (address aToken) {
        if (uint256(config) >> 160 != 0) revert InvalidUnderlyingPoolConfig(asset, config);
        return address(uint160(uint256(config)));
    }
}
