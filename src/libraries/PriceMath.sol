// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PriceMath
 * @notice Deterministic linear lazy price: price = startPrice + slope * (timestamp - startTime).
 * @dev Pure library; no storage, no block.timestamp. Reverts if result would be negative (e.g. Dutch below zero).
 */
library PriceMath {
    error PriceMath_NegativePrice();

    /// @notice Compute price at a given timestamp. Reverts if result < 0.
    /// @param startPrice Initial price (uint256).
    /// @param slope Change per second (int256; negative for Dutch).
    /// @param startTime Order start time.
    /// @param timestamp Time at which to evaluate (caller passes; no block.timestamp in library).
    /// @return Price as uint256; reverts if startPrice + slope * elapsed < 0.
    function priceAt(
        uint256 startPrice,
        int256 slope,
        uint256 startTime,
        uint256 timestamp
    ) internal pure returns (uint256) {
        if (timestamp <= startTime) {
            return startPrice;
        }
        uint256 elapsed = timestamp - startTime;
        // casting is safe because elapsed derives from block.timestamp and cannot exceed int256 max
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 elapsedInt = int256(elapsed);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 priceInt = int256(startPrice) + (slope * elapsedInt);
        if (priceInt < 0) revert PriceMath_NegativePrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(priceInt);
    }
}
