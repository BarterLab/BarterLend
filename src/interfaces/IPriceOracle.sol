// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.29;

interface IPriceOracle {
    struct Price {
        uint256 numerator;
        uint256 denominator;
        uint256 updatedAt;
    }

    /// @notice Returns the source token whose price is expressed in target tokens.
    /// @return Source token address. CreditPool uses the collateral token as the source token.
    function source() external view returns (address);

    /// @notice Returns the target token in which the source token's price is expressed.
    /// @return Target token address. CreditPool uses the loan token as the target token.
    function target() external view returns (address);

    /// @notice Returns the price of the source token in target tokens.
    /// @dev Converts amounts using targetAmount = sourceAmount * numerator / denominator. The ratio includes token
    /// decimal scaling, so both amounts use token base units. Consumers must check freshness against updatedAt.
    /// @return Price data containing:
    /// - numerator: Numerator of the source-to-target conversion ratio.
    /// - denominator: Denominator of the source-to-target conversion ratio.
    /// - updatedAt: Timestamp of the oldest price update used to calculate the pair price, in Unix seconds.
    function getPrice() external view returns (Price memory);
}
