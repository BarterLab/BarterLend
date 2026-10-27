// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { IERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { IUnderlyingPool } from "src/interfaces/IUnderlyingPool.sol";
import { MockToken } from "test/mocks/MockToken.sol";

contract MockVariablePosition {
    address public immutable asset;

    uint256 public depositLoss;
    int256 public withdrawAdjustment;

    mapping(address account => uint256 assets) public position;

    error InvalidPositionChange();

    constructor(address asset_) {
        asset = asset_;
    }

    function setDepositLoss(uint256 loss) external {
        depositLoss = loss;
    }

    function setWithdrawAdjustment(int256 adjustment) external {
        withdrawAdjustment = adjustment;
    }

    function deposit(uint256 assets) external returns (uint256 totalAssetsAfter) {
        if (depositLoss > assets) revert InvalidPositionChange();

        totalAssetsAfter = position[msg.sender] + assets - depositLoss;
        position[msg.sender] = totalAssetsAfter;
    }

    function withdraw(uint256 assets) external returns (uint256 totalAssetsAfter) {
        if (assets > uint256(type(int256).max)) revert InvalidPositionChange();

        int256 reduction = int256(assets) + withdrawAdjustment;
        if (reduction < 0 || uint256(reduction) > position[msg.sender]) revert InvalidPositionChange();

        totalAssetsAfter = position[msg.sender] - uint256(reduction);
        position[msg.sender] = totalAssetsAfter;
    }

    function rebase(address account, int256 delta) external {
        if (delta >= 0) {
            position[account] += uint256(delta);
        } else {
            if (delta == type(int256).min || uint256(-delta) > position[account]) revert InvalidPositionChange();
            position[account] -= uint256(-delta);
        }
    }
}

contract MockVariableUnderlyingPoolAdapter is IUnderlyingPool {
    using SafeERC20 for IERC20;

    address private immutable SELF;

    constructor() {
        // The implementation address distinguishes direct calls from delegatecalls.
        SELF = address(this);
    }

    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert UnderlyingPoolDelegateCallOnly();
        _;
    }

    function validate(address asset, bytes32 config) external view {
        _position(asset, config);
    }

    function totalAssets(address account, bytes32 config) external view returns (uint256) {
        return _position(address(0), config).position(account);
    }

    function deposit(address asset, bytes32 config, uint256 assets)
        external
        onlyDelegateCall
        returns (uint256 totalAssetsAfter)
    {
        MockVariablePosition positionSource = _position(asset, config);

        MockToken(asset).burn(assets);
        return positionSource.deposit(assets);
    }

    function withdraw(address asset, bytes32 config, uint256 assets, address receiver)
        external
        onlyDelegateCall
        returns (uint256 totalAssetsAfter)
    {
        MockVariablePosition positionSource = _position(asset, config);
        totalAssetsAfter = positionSource.withdraw(assets);

        MockToken(asset).mint(assets);
        if (receiver != address(this)) IERC20(asset).safeTransfer(receiver, assets);
    }

    function _position(address asset, bytes32 config) private view returns (MockVariablePosition positionSource) {
        if (uint256(config) >> 160 != 0) revert InvalidUnderlyingPoolConfig(asset, config);

        positionSource = MockVariablePosition(address(uint160(uint256(config))));
        if (
            address(positionSource) == address(0) || address(positionSource).code.length == 0
                || (asset != address(0) && positionSource.asset() != asset)
        ) {
            revert InvalidUnderlyingPoolConfig(asset, config);
        }
    }
}
