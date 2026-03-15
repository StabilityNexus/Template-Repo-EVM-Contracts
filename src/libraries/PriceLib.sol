// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interface/IWindmill.sol";

/// @title PriceLib
/// @notice Pure WAD price math for Windmill ductch auction orders not storage reads , no transfers - just the math

library PriceLib {
    uint256 internal constant WAD = 1e18;
    /// @notice Returns the WAD price of an order at a given timestamp
    /// @param startPrice  WAD price at placeAt
    /// @param slope WAD/seconds; negative = buy , positive = sell
    /// @param endPrice the floor (for buy) or ceiling (for sell) price that the order will asymptotically approach but never cross
    /// @param placedAt block.timestamp when order was created
    /// @param endPriceTimestamp the timestamp to evaluate at (usually block.timestamp)

    function priceAt(
        uint256 startPrice,
        int256 slope,
        uint256 endPrice,
        uint256 placedAt,
        uint256 endPriceTimestamp
    ) internal pure returns (uint256) {
        // no time has passed - return starting price
        if (endPriceTimestamp <= placedAt) return startPrice;

        uint256 timeElapsed = endPriceTimestamp - placedAt;

        if (slope < 0) {
            // BUY order : price falls , slope is negative so we negate it
            uint256 decay = uint256(-slope) * timeElapsed;
            // Clamp : if decay exceeds startPrice, return 0 (fully decayed)
            uint256 raw = decay >= startPrice ? 0 : startPrice - decay;
            // never go below endPrice floor

            return raw < endPrice ? endPrice : raw;
        } else {
            // sell order : price rises
            uint256 raw = startPrice + uint256(slope) * timeElapsed;
            // never go above endPrice ceiling
            return raw > endPrice ? endPrice : raw;
        }
    }

    /// @notice Returns true when price has hit its boundary and can move no further.An order AT boundary is still matchable if bp >= sp holds. Keeper must NOT skip boundary-price orders — always check bp >= sp directly.

    function atPriceBoundary(
        uint256 startPrice,
        int256 slope,
        uint256 endPrice,
        uint256 placedAt,
        uint256 endPriceTimestamp
    ) internal pure returns (bool) {
        uint256 currentPrice = priceAt(
            startPrice,
            slope,
            endPrice,
            placedAt,
            endPriceTimestamp
        );
        return currentPrice == endPrice;
    }
}
