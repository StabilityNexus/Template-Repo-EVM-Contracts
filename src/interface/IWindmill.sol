// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum Side {
    BUY,
    SELL
}
interface IWindmill {
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        address buyToken,
        address sellToken,
        uint256 buyAmount,
        uint256 sellAmount,
        uint256 startPrice,
        int256 slope,
        uint256 expiry
    );

    event OrderCancelled(
        uint256 indexed orderId,
        address indexed maker,
        uint256 refundAmount
    );

    event OrderMatched(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        uint256 fillSell,
        uint256 fillBuy,
        uint256 settlementPrice,
        address keeper
    );

    event ResidualWithdrawn(
        uint256 indexed orderId,
        address indexed maker,
        uint256 amount
    );

    function nextOrderId() external view returns (uint256);

    function getOrder(
        uint256 orderId
    )
        external
        view
        returns (
            address maker,
            address buyToken,
            address sellToken,
            uint256 buyAmount,
            uint256 sellAmount,
            uint256 expiry,
            bool active
        );

    function priceAt(
        uint256 orderId,
        uint256 timestamp
    ) external view returns (uint256);

    function placeOrder(
        address buyToken,
        address sellToken,
        uint256 buyAmount,
        uint256 sellAmount,
        uint256 startPrice,
        int256 slope,
        uint256 endPrice,
        uint256 expiry
    ) external returns (uint256 orderId);

    function cancelOrder(uint256 orderId) external;
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external;
    function withdrawResidual(uint256 orderId) external;
}
