// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {Id, MarketParams, Position, Market} from "lib/morpho-blue-irm/lib/morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "lib/morpho-blue-irm/lib/morpho-blue/src/libraries/MarketParamsLib.sol";

contract MockMorphoMarketV1 {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    mapping(bytes32 id => MarketParams params) private marketParamsById;
    mapping(bytes32 id => Market state) private markets;
    mapping(bytes32 id => mapping(address user => Position state)) private positions;

    function createMarket(
        MarketParams memory marketParams,
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares,
        uint128 fee
    ) external returns (bytes32 id) {
        id = Id.unwrap(marketParams.id());
        marketParamsById[id] = marketParams;
        markets[id] = Market({
            totalSupplyAssets: totalSupplyAssets,
            totalSupplyShares: totalSupplyShares,
            totalBorrowAssets: totalBorrowAssets,
            totalBorrowShares: totalBorrowShares,
            lastUpdate: uint128(block.timestamp),
            fee: fee
        });
    }

    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied)
    {
        bytes32 id = Id.unwrap(marketParams.id());
        Market storage marketState = markets[id];
        require(marketState.lastUpdate != 0, "market not created");
        require((assets == 0) != (shares == 0), "inconsistent input");

        if (assets != 0) {
            shares = _toSharesDown(assets, marketState.totalSupplyAssets, marketState.totalSupplyShares);
        } else {
            assets = _toAssetsUp(shares, marketState.totalSupplyAssets, marketState.totalSupplyShares);
        }

        positions[id][onBehalf].supplyShares += shares;
        marketState.totalSupplyAssets += _toUint128(assets);
        marketState.totalSupplyShares += _toUint128(shares);
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        return (assets, shares);
    }

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn) {
        bytes32 id = Id.unwrap(marketParams.id());
        Market storage marketState = markets[id];
        require(marketState.lastUpdate != 0, "market not created");
        require((assets == 0) != (shares == 0), "inconsistent input");
        require(msg.sender == onBehalf, "unauthorized");

        if (assets != 0) {
            shares = _toSharesUp(assets, marketState.totalSupplyAssets, marketState.totalSupplyShares);
        } else {
            assets = _toAssetsDown(shares, marketState.totalSupplyAssets, marketState.totalSupplyShares);
        }

        positions[id][onBehalf].supplyShares -= shares;
        marketState.totalSupplyAssets -= _toUint128(assets);
        marketState.totalSupplyShares -= _toUint128(shares);
        require(marketState.totalBorrowAssets <= marketState.totalSupplyAssets, "insufficient liquidity");
        IERC20(marketParams.loanToken).safeTransfer(receiver, assets);

        return (assets, shares);
    }

    function accrue(bytes32 id, uint256 borrowRate) external {
        Market storage marketState = markets[id];
        uint256 elapsed = block.timestamp - marketState.lastUpdate;
        if (elapsed != 0 && marketState.totalBorrowAssets != 0) {
            uint256 firstTerm = borrowRate * elapsed;
            uint256 secondTerm = firstTerm * firstTerm / (2e18);
            uint256 thirdTerm = secondTerm * firstTerm / (3e18);
            uint256 interest = uint256(marketState.totalBorrowAssets) * (firstTerm + secondTerm + thirdTerm) / 1e18;
            marketState.totalBorrowAssets += _toUint128(interest);
            marketState.totalSupplyAssets += _toUint128(interest);

            if (marketState.fee != 0) {
                uint256 feeAmount = interest * marketState.fee / 1e18;
                uint256 feeShares = feeAmount * (uint256(marketState.totalSupplyShares) + 1e6)
                    / (uint256(marketState.totalSupplyAssets) - feeAmount + 1);
                marketState.totalSupplyShares += _toUint128(feeShares);
            }
        }
        marketState.lastUpdate = uint128(block.timestamp);
    }

    function setMarket(bytes32 id, Market memory marketState) external {
        markets[id] = marketState;
    }

    function setPosition(bytes32 id, address user, Position memory positionState) external {
        positions[id][user] = positionState;
    }

    function setMarketParams(bytes32 id, MarketParams memory marketParams) external {
        marketParamsById[id] = marketParams;
    }

    function position(Id id, address user) external view returns (Position memory) {
        return positions[Id.unwrap(id)][user];
    }

    function market(Id id) external view returns (Market memory) {
        return markets[Id.unwrap(id)];
    }

    function idToMarketParams(Id id) external view returns (MarketParams memory) {
        return marketParamsById[Id.unwrap(id)];
    }

    function _toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) private pure returns (uint256) {
        return assets * (totalShares + 1e6) / (totalAssets + 1);
    }

    function _toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) private pure returns (uint256) {
        return (assets * (totalShares + 1e6) + totalAssets) / (totalAssets + 1);
    }

    function _toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) private pure returns (uint256) {
        return shares * (totalAssets + 1) / (totalShares + 1e6);
    }

    function _toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) private pure returns (uint256) {
        return (shares * (totalAssets + 1) + totalShares + 1e6 - 1) / (totalShares + 1e6);
    }

    function _toUint128(uint256 value) private pure returns (uint128) {
        require(value <= type(uint128).max, "max uint128 exceeded");
        return uint128(value);
    }
}
