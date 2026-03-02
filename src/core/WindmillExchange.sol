// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interface/IWindmill.sol";
import "../libraries/PriceLib.sol";

contract WindmillExchange is IWindmill, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Order {
        address maker;
        address buyToken;
        address sellToken;
        uint256 buyAmount;
        uint256 sellAmount;
        uint256 expiry;
        bool active;
        uint256 startPrice;
        int256 slope;
        uint256 endPrice;
        uint256 placedAt;
        Side side;
        uint256 remainingBuy;
        uint256 remainingSell;
    }

    uint256 public nextOrderId;
    mapping(uint256 => Order) internal _orders;
    mapping(bytes32 => uint256[]) public pairOrders;

    //  placeOrder
    function placeOrder(
        address buyToken,
        address sellToken,
        uint256 buyAmount,
        uint256 sellAmount,
        uint256 startPrice,
        int256 slope,
        uint256 endPrice,
        uint256 expiry
    ) external nonReentrant returns (uint256 orderId) {
        require(expiry > block.timestamp, "Expiry in the past");
        require(buyAmount > 0, "buyAmount is zero");
        require(sellAmount > 0, "sellAmount is zero");
        require(startPrice > 0, "startPrice is zero");
        require(endPrice > 0, "endPrice is zero");
        require(buyToken != address(0), "buyToken is zero address");
        require(sellToken != address(0), "sellToken is zero address");
        require(buyToken != sellToken, "buyToken == sellToken");
        require(slope != 0, "slope is zero");

        uint256 slopeAbs = slope < 0 ? uint256(-slope) : uint256(slope);
        require(
            slopeAbs <= uint256(type(uint128).max),
            "slope magnitude overflow"
        );

        if (slope < 0) {
            require(
                endPrice < startPrice,
                "BUY: endPrice must be below startPrice"
            );
        } else {
            require(
                endPrice > startPrice,
                "SELL: endPrice must be above startPrice"
            );
        }

        orderId = nextOrderId;
        nextOrderId++;

        _orders[orderId] = Order({
            maker: msg.sender,
            buyToken: buyToken,
            sellToken: sellToken,
            buyAmount: buyAmount,
            sellAmount: sellAmount,
            expiry: expiry,
            active: true,
            startPrice: startPrice,
            slope: slope,
            endPrice: endPrice,
            placedAt: block.timestamp,
            side: slope < 0 ? Side.BUY : Side.SELL,
            remainingBuy: buyAmount,
            remainingSell: sellAmount
        });

        bytes32 key = keccak256(abi.encode(buyToken, sellToken));
        pairOrders[key].push(orderId);

        emit OrderPlaced(
            orderId,
            msg.sender,
            buyToken,
            sellToken,
            buyAmount,
            sellAmount,
            startPrice,
            slope,
            expiry
        );

        // Interaction last — CEI: all state written before external call
        IERC20(sellToken).safeTransferFrom(
            msg.sender,
            address(this),
            sellAmount
        );
    }

    //  cancelOrder 
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        require(o.maker == msg.sender, "Not order maker");
        require(o.active, "Order not active");

        o.active = false;
        uint256 refund = o.remainingSell;
        o.remainingSell = 0;

        emit OrderCancelled(orderId, msg.sender, refund);

        IERC20(o.sellToken).safeTransfer(msg.sender, refund);
    }

    //  withdrawResidual — lets maker recover escrowed sellToken after auto-deactivation
    function withdrawResidual(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        require(o.maker == msg.sender, "Not order maker");
        uint256 residual = o.remainingSell;
        require(residual > 0, "No residual to withdraw");

        o.remainingSell = 0;

        emit ResidualWithdrawn(orderId, msg.sender, residual);

        IERC20(o.sellToken).safeTransfer(msg.sender, residual);
    }

    //  matchOrders 
    function matchOrders(
        uint256 buyOrderId,
        uint256 sellOrderId
    ) external nonReentrant {
        Order storage buy = _orders[buyOrderId];
        Order storage sell = _orders[sellOrderId];

        require(buy.active && sell.active, "Order not active");
        require(buy.maker != sell.maker, "Self-match not allowed");
        require(buy.side == Side.BUY, "buyOrderId is not a BUY order");
        require(sell.side == Side.SELL, "sellOrderId is not a SELL order");
        require(block.timestamp < buy.expiry, "Buy order expired");
        require(block.timestamp < sell.expiry, "Sell order expired");
        require(
            buy.buyToken == sell.sellToken && buy.sellToken == sell.buyToken,
            "Token pair mismatch"
        );

        uint256 bp = PriceLib.priceAt(
            buy.startPrice,
            buy.slope,
            buy.endPrice,
            buy.placedAt,
            block.timestamp
        );
        uint256 sp = PriceLib.priceAt(
            sell.startPrice,
            sell.slope,
            sell.endPrice,
            sell.placedAt,
            block.timestamp
        );

        require(bp >= sp, "Prices have not crossed");

        uint256 settlementPrice = (bp + sp) / 2;

        uint256 maxSellFromBuyer = (buy.remainingSell * 1e18) / settlementPrice;
        // Cap by seller's remaining demand (in commodity units) to prevent sell.remainingBuy underflow
        uint256 maxSellBySellerDemand = (sell.remainingBuy * 1e18) / settlementPrice;
        uint256 fillSell = maxSellFromBuyer;
        if (buy.remainingBuy < fillSell) fillSell = buy.remainingBuy;         // cap: buyer demand
        if (sell.remainingSell < fillSell) fillSell = sell.remainingSell;     // cap: seller supply
        if (maxSellBySellerDemand < fillSell) fillSell = maxSellBySellerDemand; // cap: seller demand
        uint256 fillBuy = (fillSell * settlementPrice) / 1e18;

        buy.remainingSell -= fillBuy;
        buy.remainingBuy -= fillSell;
        sell.remainingSell -= fillSell;
        sell.remainingBuy -= fillBuy;

        if (buy.remainingBuy == 0 || buy.remainingSell == 0) buy.active = false;
        if (sell.remainingBuy == 0 || sell.remainingSell == 0)
            sell.active = false;

        emit OrderMatched(
            buyOrderId,
            sellOrderId,
            fillSell,
            fillBuy,
            settlementPrice,
            msg.sender
        );

        IERC20(buy.sellToken).safeTransfer(sell.maker, fillBuy);
        IERC20(sell.sellToken).safeTransfer(buy.maker, fillSell);
    }

    //  Read functions 
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
        )
    {
        Order storage o = _orders[orderId];
        return (
            o.maker,
            o.buyToken,
            o.sellToken,
            o.buyAmount,
            o.sellAmount,
            o.expiry,
            o.active
        );
    }

    function priceAt(
        uint256 orderId,
        uint256 timestamp
    ) external view returns (uint256) {
        Order storage o = _orders[orderId];
        return
            PriceLib.priceAt(
                o.startPrice,
                o.slope,
                o.endPrice,
                o.placedAt,
                timestamp
            );
    }
}
