// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

import { MockToken } from "test/mocks/MockToken.sol";
import { MockAaveToken } from "test/mocks/MockAaveToken.sol";

import { IPool as IAavePool } from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";
import { IPoolAddressesProvider } from "lib/aave-v3-origin/src/contracts/interfaces/IPoolAddressesProvider.sol";
import { DataTypes } from "lib/aave-v3-origin/src/contracts/protocol/libraries/types/DataTypes.sol";

contract MockAavePool is IAavePool {
    MockToken public immutable underlying;
    MockAaveToken public immutable aaveToken;

    constructor(MockToken underlying_, MockAaveToken aaveToken_) {
        underlying = underlying_;
        aaveToken = aaveToken_;
        aaveToken_.setPool(address(this));
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(asset == address(underlying));
        underlying.transferFrom(msg.sender, address(this), amount);
        underlying.approve(address(aaveToken), amount);
        aaveToken.mint(amount);
        aaveToken.transfer(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(underlying));
        aaveToken.burn(msg.sender, amount);
        underlying.transfer(to, amount);
        return amount;
    }

    function supplyWithPermit(address,uint256,address,uint16,uint256,uint8,bytes32,bytes32) external {}
    function borrow(address, uint256, uint256, uint16, address) external {}
    function repay(address, uint256, uint256, address) external returns (uint256) {}
    function repayWithPermit(address,uint256,uint256,address,uint256,uint8,bytes32,bytes32) external returns (uint256) {}
    function repayWithATokens(address, uint256, uint256) external returns (uint256) {}
    function setUserUseReserveAsCollateral(address, bool) external {}
    function liquidationCall(address, address, address, uint256, bool) external {}
    function flashLoan(address,address[] calldata,uint256[] calldata,uint256[] calldata,address,bytes calldata,uint16) external {}
    function flashLoanSimple(address, address, uint256, bytes calldata, uint16) external {}
    function getUserAccountData(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {}
    function initReserve(address, address, address) external {}
    function dropReserve(address) external {}
    function syncIndexesState(address) external {}
    function syncRatesState(address) external {}
    function setConfiguration(address, DataTypes.ReserveConfigurationMap calldata) external {}
    function getConfiguration(address) external view returns (DataTypes.ReserveConfigurationMap memory) {}
    function getUserConfiguration(address) external view returns (DataTypes.UserConfigurationMap memory) {}
    function getReserveNormalizedIncome(address) external view returns (uint256) {}
    function getReserveNormalizedVariableDebt(address) external view returns (uint256) {}
    function getReserveData(address) external view returns (DataTypes.ReserveDataLegacy memory) {}
    function getVirtualUnderlyingBalance(address) external view returns (uint128) {}
    function finalizeTransfer(address, address, address, uint256, uint256) external {}
    function getReservesList() external view returns (address[] memory) {}
    function getReservesCount() external view returns (uint256) {}
    function getReserveAddressById(uint16) external view returns (address) {}
    function ADDRESSES_PROVIDER() external view returns (IPoolAddressesProvider) {}
    function RESERVE_INTEREST_RATE_STRATEGY() external view returns (address) {}
    function updateFlashloanPremium(uint128) external {}
    function configureEModeCategory(uint8, DataTypes.EModeCategoryBaseConfiguration memory) external {}
    function configureEModeCategoryCollateralBitmap(uint8, uint128) external {}
    function configureEModeCategoryBorrowableBitmap(uint8, uint128) external {}
    function configureEModeCategoryLtvzeroBitmap(uint8, uint128) external {}
    function getEModeCategoryData(uint8) external view returns (DataTypes.EModeCategoryLegacy memory) {}
    function getEModeCategoryLabel(uint8) external view returns (string memory) {}
    function getEModeCategoryCollateralConfig(uint8) external view returns (DataTypes.CollateralConfig memory) {}
    function getEModeCategoryCollateralBitmap(uint8) external view returns (uint128) {}
    function getEModeCategoryBorrowableBitmap(uint8) external view returns (uint128) {}
    function getEModeCategoryLtvzeroBitmap(uint8) external view returns (uint128) {}
    function setUserEMode(uint8) external {}
    function getUserEMode(address) external view returns (uint256) {}
    function resetIsolationModeTotalDebt(address) external {}
    function setLiquidationGracePeriod(address, uint40) external {}
    function getLiquidationGracePeriod(address) external view returns (uint40) {}
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128) {}
    function FLASHLOAN_PREMIUM_TO_PROTOCOL() external view returns (uint128) {}
    function MAX_NUMBER_RESERVES() external view returns (uint16) {}
    function mintToTreasury(address[] calldata) external {}
    function rescueTokens(address, address, uint256) external {}
    function deposit(address, uint256, address, uint16) external {}
    function eliminateReserveDeficit(address, uint256) external returns (uint256) {}
    function approvePositionManager(address, bool) external {}
    function renouncePositionManagerRole(address) external {}
    function setUserUseReserveAsCollateralOnBehalfOf(address, bool, address) external {}
    function setUserEModeOnBehalfOf(uint8, address) external {}
    function isApprovedPositionManager(address, address) external view returns (bool) {}
    function getReserveDeficit(address) external view returns (uint256) {}
    function getReserveAToken(address asset) external view returns (address) {
        if (asset != address(underlying)) return address(0);
        return address(aaveToken);
    }
    function getReserveVariableDebtToken(address) external view returns (address) {}
    function getFlashLoanLogic() external view returns (address) {}
    function getBorrowLogic() external view returns (address) {}
    function getLiquidationLogic() external view returns (address) {}
    function getPoolLogic() external view returns (address) {}
    function getSupplyLogic() external view returns (address) {}
}
