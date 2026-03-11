// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Core order struct with tightly-packed fields.
/// @dev    `maker` (20 bytes) + `isBuy` (1 byte) + `active` (1 byte) = 22 bytes,
///         which fits in a single 32-byte storage slot together.
struct Order {
    uint256 id;
    address maker;
    bool    isBuy;
    bool    active;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 remainingIn;
    uint256 startPrice;
    int256  slope;
    uint256 minPrice;
    uint256 maxPrice;
    uint256 createdAt;
    uint256 expiry;
}

function pairKeyOf(address tokenA, address tokenB) pure returns (bytes32) {
    (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    return keccak256(abi.encodePacked(t0, t1));
}
