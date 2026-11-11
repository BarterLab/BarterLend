// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

interface IPendlePrincipalToken {
    function SY() external view returns (address);
    function YT() external view returns (address);
}

interface IPendleYieldToken {
    function PT() external view returns (address);
    function SY() external view returns (address);
    function pyIndexStored() external view returns (uint256);
}

interface IPendleStandardizedYield {
    function assetInfo() external view returns (uint8 assetType, address assetAddress, uint8 assetDecimals);
    function exchangeRate() external view returns (uint256);
}
