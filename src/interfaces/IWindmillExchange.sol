// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Order} from "../types/OrderTypes.sol";

interface IWindmillExchange {
    function createOrder(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 startPrice,
        int256  slope,
        uint256 minPrice,
        uint256 maxPrice,
        uint256 expiry,
        bool    isBuy
    ) external returns (uint256 orderId);

    function cancelOrder(uint256 orderId) external;

    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external;

    function currentPrice(uint256 orderId, uint256 timestamp)
        external
        view
        returns (uint256 price);

    function getOrder(uint256 orderId) external view returns (Order memory);

    function getOrdersByPair(address tokenA, address tokenB) external view returns (uint256[] memory);

    function totalOrders() external view returns (uint256);
}
