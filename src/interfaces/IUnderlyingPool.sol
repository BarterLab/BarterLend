// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

struct UnderlyingPoolConfig {
    address adapter;
    bytes32 config;
}

interface IUnderlyingPool {
    error InvalidUnderlyingPoolConfig(address asset, bytes32 config);
    error UnderlyingPoolDelegateCallOnly();
    error UnderlyingPoolDepositFailed(uint256 requested, uint256 deposited);
    error UnderlyingPoolWithdrawFailed(uint256 requested, uint256 withdrawn);

    /// @notice Checks that the adapter configuration accepts the specified loan token.
    /// @dev Reverts for an invalid configuration. Called directly on the adapter without changing state.
    /// @param asset Loan token address.
    /// @param config Adapter-specific identifier for the underlying position or market.
    function validate(address asset, bytes32 config) external view;

    /// @notice Returns the value of an account's underlying position in loan tokens.
    /// @dev This is the position's asset value, not a guarantee of immediately withdrawable liquidity.
    /// @param account Address holding the underlying position.
    /// @param config Adapter-specific identifier for the underlying position or market.
    /// @return Position value in loan token base units, including accrued interest and adapter rounding.
    function totalAssets(address account, bytes32 config) external view returns (uint256);

    /// @notice Deposits loan tokens from the calling pool into its underlying position.
    /// @dev Must be executed by delegatecall from the pool. The position remains owned by the pool. Rounding may make
    /// the increase in position value differ from the deposited amount.
    /// @param asset Loan token address.
    /// @param config Adapter-specific identifier for the underlying position or market.
    /// @param assets Exact amount of loan tokens to deposit, in loan token base units.
    /// @return totalAssetsAfter Total underlying position value after deposit, in loan token base units.
    function deposit(address asset, bytes32 config, uint256 assets) external returns (uint256 totalAssetsAfter);

    /// @notice Withdraws loan tokens from the calling pool's underlying position to a recipient.
    /// @dev Must be executed by delegatecall from the pool. Reverts if the exact amount cannot be delivered.
    /// @param asset Loan token address.
    /// @param config Adapter-specific identifier for the underlying position or market.
    /// @param assets Exact amount of loan tokens to deliver to receiver, in loan token base units.
    /// @param receiver Address receiving the loan tokens.
    /// @return totalAssetsAfter Total underlying position value after withdrawal, in loan token base units.
    function withdraw(address asset, bytes32 config, uint256 assets, address receiver)
        external
        returns (uint256 totalAssetsAfter);
}
