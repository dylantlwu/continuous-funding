// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// A pull-oracle price behind an interface, so Pyth can be swapped for Pyth Pro or another source.
interface IPriceSource {
    /// Native-token fee the update costs.
    function updateFee(bytes[] calldata updateData) external view returns (uint256);

    /// Apply the caller's signed update, then return the source's latest price.
    /// Prices are USD per base unit scaled 1e18. Reverts on a non-positive price.
    /// Used where a bot needs the current price (liquidation, poke); the engine bounds its age.
    function update(bytes[] calldata updateData)
        external
        payable
        returns (uint256 priceWad, uint256 confWad, uint64 publishTime);

    /// The FIRST price published at or after `minTime` (and no later than `maxTime`), proven to be the
    /// first by the oracle, so no caller can choose among prints. Used to settle committed orders.
    function firstPriceAfter(bytes[] calldata updateData, uint64 minTime, uint64 maxTime)
        external
        payable
        returns (uint256 priceWad, uint256 confWad, uint64 publishTime);
}
