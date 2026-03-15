// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IWindmill
 * @notice Interface for the Windmill lazy auction order book. Pure deterministic on-chain settlement.
 * @dev No keeper, surplus, incentive, or scheduling logic; matching is lazy (caller-triggered).
 */
interface IWindmill {
    /// @notice Single order in the book. Both BUY and SELL escrow tokenIn; price is lazy (startPrice + slope * time).
    struct Order {
        address owner;
        address tokenIn;
        address tokenOut;
        uint256 startPrice;
        int256 slope;
        uint256 startTime;
        uint256 remainingAmount; // remaining tokenIn in escrow (same unit for both sides)
        bool isBuy;
        bool active;
    }

    event OrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        address tokenIn,
        address tokenOut,
        uint256 startPrice,
        int256 slope,
        uint256 startTime,
        uint256 amount,
        bool isBuy
    );

    event OrdersMatched(
        uint256 indexed buyId,
        uint256 indexed sellId,
        address indexed taker,
        uint256 amountOut,
        uint256 amountIn
    );

    event OrderCancelled(uint256 indexed orderId, address indexed owner);

    /// @notice Create an order; transfers tokenIn into escrow.
    /// @param tokenIn Token to escrow (quote for BUY, base for SELL).
    /// @param tokenOut Other leg (base for BUY, quote for SELL).
    /// @param startPrice Initial price (wei per 1e18 base, or equivalent scale).
    /// @param slope Price change per second (negative = Dutch).
    /// @param amount Amount of tokenIn to escrow.
    /// @param isBuy True = BUY order (owner buys tokenOut with tokenIn), false = SELL.
    function createOrder(
        address tokenIn,
        address tokenOut,
        uint256 startPrice,
        int256 slope,
        uint256 amount,
        bool isBuy
    ) external returns (uint256 orderId);

    /// @notice Match a BUY and a SELL order at sellPrice; trade amount = min(buy.remaining, sell.remaining) in base.
    /// @param buyId BUY order id (must have isBuy == true).
    /// @param sellId SELL order id (must have isBuy == false).
    function matchOrders(uint256 buyId, uint256 sellId) external;

    /// @notice Cancel order; refunds remaining escrow and marks inactive.
    /// @param orderId Order to cancel.
    function cancelOrder(uint256 orderId) external;

    /// @notice Price at a given timestamp: startPrice + slope * (timestamp - startTime). Reverts if result < 0.
    /// @param orderId Order id.
    /// @param timestamp Time at which to evaluate price (no block.timestamp in library; caller passes it).
    function priceAt(
        uint256 orderId,
        uint256 timestamp
    ) external view returns (uint256);

    /// @notice Get order by id.
    /// @param orderId Order id.
    function getOrder(uint256 orderId) external view returns (Order memory);
}
