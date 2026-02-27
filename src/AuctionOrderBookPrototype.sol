// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title AuctionOrderBookPrototype
 * @notice MVP for testing lazy, user-triggered auction-based order execution
 * @dev Each order has a time-dependent price function evaluated at execution time
 */
contract AuctionOrderBookPrototype {
    struct Order {
        address creator;
        bool isBuy;           // true = buy order (decreasing price), false = sell order (increasing price)
        uint256 amount;       // remaining amount in base units
        uint256 startPrice;   // initial price in wei per unit
        int256 priceSlope;    // price change per second (negative for buy orders)
        uint256 startTime;    // block.timestamp when order was created
        uint256 stopPrice;    // auto-cancel threshold (0 = no stop price)
        uint256 expiryTime;   // optional hard expiry timestamp (0 = no expiry)
        uint256 escrowedEth;  // remaining escrow for buy orders
        bool active;          // false if cancelled, expired or fully filled
    }

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId;

    uint256[] public activeOrderIds;
    mapping(uint256 => uint256) private activeOrderIndex; // orderId => index in activeOrderIds

    event OrderCreated(
        uint256 indexed orderId,
        address indexed creator,
        bool isBuy,
        uint256 amount,
        uint256 startPrice,
        int256 priceSlope,
        uint256 stopPrice,
        uint256 expiryTime
    );

    event OrderExecuted(
        uint256 indexed orderId,
        address indexed executor,
        uint256 amount,
        uint256 price,
        uint256 remainingAmount
    );

    event OrderCancelled(uint256 indexed orderId);
    event OrderExpired(uint256 indexed orderId, address indexed caller);

    /**
     * @notice Create a new auction order with time-dependent pricing
     * @param isBuy True for buy order (price typically decreases), false for sell
     * @param amount Amount in base units
     * @param startPrice Initial price in wei per unit
     * @param priceSlope Price change per second (can be negative)
     * @param stopPrice Price threshold for auto-stop (0 to disable)
     * @param expiryTime Optional unix timestamp when order expires (0 = no expiry)
     */
    function createOrder(
        bool isBuy,
        uint256 amount,
        uint256 startPrice,
        int256 priceSlope,
        uint256 stopPrice,
        uint256 expiryTime
    ) external payable returns (uint256 orderId) {
        require(amount > 0, "Amount must be > 0");
        require(startPrice > 0, "Start price must be > 0");
        require(expiryTime == 0 || expiryTime > block.timestamp, "Invalid expiry");

        uint256 escrowedEth = 0;
        if (isBuy) {
            uint256 maxCost = amount * startPrice;
            require(msg.value == maxCost, "Buy order needs exact ETH escrow");
            escrowedEth = maxCost;
        } else {
            require(msg.value == 0, "Sell order should not send ETH");
        }

        orderId = nextOrderId++;

        orders[orderId] = Order({
            creator: msg.sender,
            isBuy: isBuy,
            amount: amount,
            startPrice: startPrice,
            priceSlope: priceSlope,
            startTime: block.timestamp,
            stopPrice: stopPrice,
            expiryTime: expiryTime,
            escrowedEth: escrowedEth,
            active: true
        });

        activeOrderIndex[orderId] = activeOrderIds.length;
        activeOrderIds.push(orderId);

        emit OrderCreated(orderId, msg.sender, isBuy, amount, startPrice, priceSlope, stopPrice, expiryTime);
    }

    /**
     * @notice Calculate current price of an order based on elapsed time
     * @dev Pure calculation - no state changes
     * @param orderId The order to query
     * @return price Current price in wei per unit, or 0 if invalid/stopped/expired
     */
    function currentPrice(uint256 orderId) public view returns (uint256 price) {
        Order storage order = orders[orderId];

        if (!order.active) {
            return 0;
        }
        if (order.expiryTime > 0 && block.timestamp >= order.expiryTime) {
            return 0;
        }

        uint256 elapsed = block.timestamp - order.startTime;

        int256 priceChange = order.priceSlope * int256(elapsed);
        int256 calculatedPrice = int256(order.startPrice) + priceChange;

        if (calculatedPrice <= 0) {
            return 0;
        }

        price = uint256(calculatedPrice);

        if (order.stopPrice > 0) {
            if (order.isBuy && price <= order.stopPrice) {
                return 0;
            } else if (!order.isBuy && price >= order.stopPrice) {
                return 0;
            }
        }
    }

    function isOrderValid(uint256 orderId) public view returns (bool) {
        return orders[orderId].active && currentPrice(orderId) > 0;
    }

    function isExpired(uint256 orderId) public view returns (bool) {
        Order storage order = orders[orderId];
        return order.active && order.expiryTime > 0 && block.timestamp >= order.expiryTime;
    }

    /**
     * @notice Execute (take) an order at its current price
     * @dev User-triggered execution - the core of the lazy approach
     * @param orderId The order to execute
     * @param amount Amount to fill (can be partial)
     */
    function executeOrder(uint256 orderId, uint256 amount) external payable {
        Order storage order = orders[orderId];

        require(order.active, "Order not active");
        require(msg.sender != order.creator, "Creator cannot execute own order");
        require(!isExpired(orderId), "Order expired");
        require(amount > 0, "Amount must be > 0");
        require(amount <= order.amount, "Amount exceeds available");

        uint256 price = currentPrice(orderId);
        require(price > 0, "Order stopped or invalid price");

        uint256 totalCost = amount * price;

        if (order.isBuy) {
            require(msg.value == 0, "Buy execution should not send ETH");
            require(order.escrowedEth >= totalCost, "Escrow depleted");

            order.escrowedEth -= totalCost;
            (bool success,) = payable(msg.sender).call{value: totalCost}("");
            require(success, "ETH transfer failed");

            if (amount == order.amount) {
                uint256 refund = order.escrowedEth;
                order.escrowedEth = 0;
                if (refund > 0) {
                    (success,) = payable(order.creator).call{value: refund}("");
                    require(success, "Refund failed");
                }
            }
        } else {
            require(msg.value == totalCost, "Must pay exact ETH");

            (bool success,) = payable(order.creator).call{value: totalCost}("");
            require(success, "ETH transfer failed");
        }

        order.amount -= amount;

        if (order.amount == 0) {
            _deactivateOrder(orderId);
        }

        emit OrderExecuted(orderId, msg.sender, amount, price, order.amount);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];

        require(order.active, "Order not active");
        require(msg.sender == order.creator, "Not order creator");

        if (order.isBuy) {
            uint256 refund = order.escrowedEth;
            order.escrowedEth = 0;
            (bool success,) = payable(order.creator).call{value: refund}("");
            require(success, "Refund failed");
        }

        _deactivateOrder(orderId);

        emit OrderCancelled(orderId);
    }

    /**
     * @notice Expire and refund an order once expiryTime is reached
     * @dev Callable by anyone, useful for keeper-style cleanup
     */
    function expireOrder(uint256 orderId) external {
        Order storage order = orders[orderId];

        require(order.active, "Order not active");
        require(order.expiryTime > 0 && block.timestamp >= order.expiryTime, "Order not expired");

        if (order.isBuy) {
            uint256 refund = order.escrowedEth;
            order.escrowedEth = 0;
            if (refund > 0) {
                (bool success,) = payable(order.creator).call{value: refund}("");
                require(success, "Refund failed");
            }
        }

        _deactivateOrder(orderId);
        emit OrderExpired(orderId, msg.sender);
    }

    function getActiveOrderIds() external view returns (uint256[] memory) {
        return activeOrderIds;
    }

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function getOrderWithPrice(uint256 orderId) external view returns (Order memory order, uint256 price) {
        order = orders[orderId];
        price = currentPrice(orderId);
    }

    function getActiveOrderCount() external view returns (uint256) {
        return activeOrderIds.length;
    }

    function _deactivateOrder(uint256 orderId) internal {
        orders[orderId].active = false;

        uint256 index = activeOrderIndex[orderId];
        uint256 lastIndex = activeOrderIds.length - 1;

        if (index != lastIndex) {
            uint256 lastOrderId = activeOrderIds[lastIndex];
            activeOrderIds[index] = lastOrderId;
            activeOrderIndex[lastOrderId] = index;
        }

        activeOrderIds.pop();
        delete activeOrderIndex[orderId];
    }
}

