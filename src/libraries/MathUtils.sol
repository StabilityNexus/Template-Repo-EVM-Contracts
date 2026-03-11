// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library MathUtils {
    uint256 internal constant RAY = 1e27;

    function mulDiv(uint256 a, uint256 b, uint256 denom) internal pure returns (uint256 result) {
        require(denom != 0, "MathUtils: div by zero");
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) {
                return prod0 / denom;
            }

            require(prod1 < denom, "MathUtils: mulDiv overflow");

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denom)
            }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denom & (~denom + 1);
            assembly {
                denom := div(denom, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inv = (3 * denom) ^ 2;
            inv *= 2 - denom * inv;
            inv *= 2 - denom * inv;
            inv *= 2 - denom * inv;
            inv *= 2 - denom * inv;
            inv *= 2 - denom * inv;
            inv *= 2 - denom * inv;

            result = prod0 * inv;
        }
    }

    function midpoint(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a & b) + ((a ^ b) >> 1);
    }

    /// @notice Clamps `value` to the range [`lo`, `hi`].
    /// @dev    A bound value of **0 means "unbounded"** — i.e., 0 disables that bound
    ///         rather than enforcing a literal bound of zero.
    ///         - `lo == 0`: no lower bound is applied; `value` may be any amount ≥ 0.
    ///         - `hi == 0`: no upper bound is applied; `value` may be any amount.
    ///         - Both `lo` and `hi` are 0: `value` is returned unchanged.
    ///
    ///         Examples:
    ///           clamp(5, 10, 20) → 10  (below lower bound)
    ///           clamp(15, 10, 20) → 15 (within range)
    ///           clamp(25, 10, 20) → 20 (above upper bound)
    ///           clamp(5,  0, 20)  → 5  (no lower bound; within upper)
    ///           clamp(25, 0, 20)  → 20 (no lower bound; exceeds upper)
    ///           clamp(5, 10, 0)   → 10 (below lower bound; no upper bound)
    ///           clamp(5,  0,  0)  → 5  (fully unbounded; returned as-is)
    /// @param value The value to clamp.
    /// @param lo    Lower bound (pass 0 to disable).
    /// @param hi    Upper bound (pass 0 to disable).
    /// @return      The clamped value.
    function clamp(uint256 value, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (lo != 0 && value < lo) return lo;
        if (hi != 0 && value > hi) return hi;
        return value;
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
