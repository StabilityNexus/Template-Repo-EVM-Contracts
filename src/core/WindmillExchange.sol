// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Order}         from "../types/OrderTypes.sol";
import {OrderStorage}  from "../storage/OrderStorage.sol";
import {PairStorage}   from "../storage/PairStorage.sol";
import {PriceCurve}    from "../libraries/PriceCurve.sol";
import {TokenTransfer} from "../libraries/TokenTransfer.sol";
import {MathUtils}     from "../libraries/MathUtils.sol";
import {IWindmillExchange} from "../interfaces/IWindmillExchange.sol";

error ZeroAddress();
error ZeroAmount();
error ZeroStartPrice();
error InvalidExpiry();
error InvalidPriceBounds();
error SlopeOverflow();
error NotMaker();
error OrderInactive();
error OrderExpired();
error SelfMatch();
error NoCross();
error PairMismatch();
error ZeroSettlementPrice();

contract WindmillExchange is OrderStorage, PairStorage, IWindmillExchange {

    // ─── Inline Reentrancy Guard ─────────────────────────────────────────────
    uint256 private _reentrancyStatus = 1;

    modifier nonReentrant() {
        require(_reentrancyStatus == 1, "WindmillExchange: reentrant call");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    // ─── Events ──────────────────────────────────────────────────────────────
    event OrderCreated(
        uint256 indexed orderId,
        address indexed maker,
        address indexed tokenIn,
        address tokenOut,
        uint256 amountIn,
        bool isBuy
    );
    event OrderCancelled(uint256 indexed orderId, address indexed maker, uint256 refund);
    event OrderMatched(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        address indexed keeper,
        uint256 settlementPrice,
        uint256 filledAmount
    );
    event OrderFilled(uint256 indexed orderId);
    event OrderPartiallyFilled(uint256 indexed orderId, uint256 remainingIn);

    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 private constant MAX_LIFETIME    = 315_360_000;
    uint256 private constant SLOPE_ABS_LIMIT = type(uint128).max / MAX_LIFETIME;

    // ─── External Functions ───────────────────────────────────────────────────

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
    ) external override returns (uint256 orderId) {
        // Checks
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (tokenIn == tokenOut)                             revert ZeroAddress();
        if (amountIn == 0)                                   revert ZeroAmount();
        if (startPrice == 0)                                 revert ZeroStartPrice();
        if (expiry != 0 && expiry <= block.timestamp)        revert InvalidExpiry();
        if (maxPrice != 0 && maxPrice < minPrice)            revert InvalidPriceBounds();
        if (slope != 0 && MathUtils.abs(slope) > SLOPE_ABS_LIMIT) revert SlopeOverflow();

        // Effects — store and register BEFORE the external transfer (CEI)
        Order memory order = Order({
            id:          0,
            maker:       msg.sender,
            isBuy:       isBuy,
            active:      true,
            tokenIn:     tokenIn,
            tokenOut:    tokenOut,
            amountIn:    amountIn,
            remainingIn: amountIn,
            startPrice:  startPrice,
            slope:       slope,
            minPrice:    minPrice,
            maxPrice:    maxPrice,
            createdAt:   block.timestamp,
            expiry:      expiry
        });

        orderId = _storeOrder(order);
        _addOrderToPair(tokenIn, tokenOut, orderId);

        // Interactions
        TokenTransfer.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        emit OrderCreated(orderId, msg.sender, tokenIn, tokenOut, amountIn, isBuy);
    }

    function cancelOrder(uint256 orderId) external override nonReentrant {
        Order storage order = _getOrder(orderId);

        if (order.maker != msg.sender) revert NotMaker();
        if (!order.active)             revert OrderInactive();

        uint256 refund   = order.remainingIn;
        address tokenIn  = order.tokenIn;
        address tokenOut = order.tokenOut;

        // Effects before interaction
        _deactivateOrder(orderId);
        _removeOrderFromPair(tokenIn, tokenOut, orderId);

        // Interaction
        TokenTransfer.safeTransfer(tokenIn, msg.sender, refund);

        emit OrderCancelled(orderId, msg.sender, refund);
    }

    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external override nonReentrant {
        Order memory buy  = _getOrderMem(buyOrderId);
        Order memory sell = _getOrderMem(sellOrderId);

        _validateMatch(buy, sell, block.timestamp);

        (
            uint256 settlementPx,
            uint256 filledAsset,
            uint256 paymentOwed,
            bool    buyFilled,
            bool    sellFilled
        ) = _computeSettlement(buy, sell, block.timestamp);

        uint256 newBuyRemaining  = buy.remainingIn  - paymentOwed;
        uint256 newSellRemaining = sell.remainingIn - filledAsset;

        // Effects
        if (buyFilled) {
            _deactivateOrder(buyOrderId);
            _removeOrderFromPair(buy.tokenIn, buy.tokenOut, buyOrderId);
        } else {
            _updateRemainingIn(buyOrderId, newBuyRemaining);
        }

        if (sellFilled) {
            _deactivateOrder(sellOrderId);
            _removeOrderFromPair(sell.tokenIn, sell.tokenOut, sellOrderId);
        } else {
            _updateRemainingIn(sellOrderId, newSellRemaining);
        }

        // Interactions
        TokenTransfer.safeTransfer(sell.tokenIn, buy.maker,  filledAsset);
        TokenTransfer.safeTransfer(buy.tokenIn,  sell.maker, paymentOwed);

        emit OrderMatched(buyOrderId, sellOrderId, msg.sender, settlementPx, filledAsset);

        if (buyFilled)  emit OrderFilled(buyOrderId);
        else            emit OrderPartiallyFilled(buyOrderId,  newBuyRemaining);

        if (sellFilled) emit OrderFilled(sellOrderId);
        else            emit OrderPartiallyFilled(sellOrderId, newSellRemaining);
    }

    function currentPrice(uint256 orderId, uint256 timestamp)
        external
        view
        override
        returns (uint256)
    {
        return PriceCurve.currentPriceMem(_getOrderMem(orderId), timestamp);
    }

    function getOrder(uint256 orderId)
        external
        view
        override
        returns (Order memory)
    {
        return _getOrderMem(orderId);
    }

    function getOrdersByPair(address tokenA, address tokenB)
        external
        view
        override
        returns (uint256[] memory)
    {
        return _getOrdersByPair(tokenA, tokenB);
    }

    function totalOrders()
        external
        view
        override
        returns (uint256)
    {
        return _totalOrders();
    }

    // ─── Internal Helpers ────────────────────────────────────────────────────

    function _validateMatch(Order memory buy, Order memory sell, uint256 ts) private pure {
        if (!buy.active)                                          revert OrderInactive();
        if (!sell.active)                                         revert OrderInactive();
        if (buy.expiry  != 0 && ts > buy.expiry)                 revert OrderExpired();
        if (sell.expiry != 0 && ts > sell.expiry)                revert OrderExpired();
        if (!buy.isBuy || sell.isBuy)                            revert PairMismatch();
        if (buy.tokenOut != sell.tokenIn || buy.tokenIn != sell.tokenOut) revert PairMismatch();
        if (buy.maker == sell.maker)                             revert SelfMatch();
        if (!PriceCurve.hasCrossed(buy, sell, ts))               revert NoCross();
    }

    function _computeSettlement(
        Order memory buy,
        Order memory sell,
        uint256 ts
    ) private pure returns (
        uint256 settlementPx,
        uint256 filledAsset,
        uint256 paymentOwed,
        bool    buyFilled,
        bool    sellFilled
    ) {
        settlementPx = PriceCurve.settlementPrice(buy, sell, ts);
        if (settlementPx == 0) revert ZeroSettlementPrice();

        uint256 maxAssetFromBuy = MathUtils.mulDiv(buy.remainingIn, settlementPx, MathUtils.RAY);
        filledAsset = maxAssetFromBuy < sell.remainingIn ? maxAssetFromBuy : sell.remainingIn;

        paymentOwed = MathUtils.mulDiv(filledAsset, MathUtils.RAY, settlementPx);
        if (paymentOwed > buy.remainingIn) paymentOwed = buy.remainingIn;

        buyFilled  = (buy.remainingIn  - paymentOwed) == 0;
        sellFilled = (sell.remainingIn - filledAsset)  == 0;
    }
}
