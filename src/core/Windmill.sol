// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IWindmill} from "../interfaces/IWindmill.sol";
import {PriceMath} from "../libraries/PriceMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*
 * INVARIANTS
 * ----------
 * 1. For every active order:
 *    remainingAmount represents escrowed tokens held by the contract.
 *
 * 2. Sum of escrowed balances equals sum of remainingAmount across active orders.
 *
 * 3. Settlement price is derived only from deterministic stored parameters.
 *
 * 4. No external actor can influence price computation.
 */

/**
 * @title Windmill
 * @notice Minimal lazy auction order book: deterministic on-chain settlement only. No keeper, surplus, or incentive logic.
 * @dev ERC20-only; all prices derived from stored (startPrice, slope, startTime). CEI respected.
 * TODO: Expiry logic (e.g. order invalid after a max duration) — not implemented; leave as future extension.
 */
contract Windmill is IWindmill {
    using SafeERC20 for IERC20;

    // Prices are expressed as quote per base scaled by 1e18.
    uint256 internal constant PRICE_SCALE = 1e18;

    mapping(uint256 => Order) private _orders;
    uint256 public nextOrderId;

    error Windmill_InvalidOrder();
    error Windmill_OrderInactive();
    error Windmill_NotOwner();
    error Windmill_InvalidMatch();
    error Windmill_PriceNotCrossed();
    error Windmill_ZeroAmount();

    /// @inheritdoc IWindmill
    function createOrder(
        address tokenIn,
        address tokenOut,
        uint256 startPrice,
        int256 slope,
        uint256 amount,
        bool isBuy
    ) external returns (uint256 orderId) {
        if (tokenIn == address(0) || tokenOut == address(0) || amount == 0)
            revert Windmill_InvalidOrder();

        orderId = nextOrderId++;
        _orders[orderId] = Order({
            owner: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            startPrice: startPrice,
            slope: slope,
            startTime: block.timestamp,
            remainingAmount: amount,
            isBuy: isBuy,
            active: true
        });

        // CEI: state updated; then external call (transfer in).
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amount);

        emit OrderCreated(
            orderId,
            msg.sender,
            tokenIn,
            tokenOut,
            startPrice,
            slope,
            block.timestamp,
            amount,
            isBuy
        );
        return orderId;
    }

    /// @inheritdoc IWindmill
    function matchOrders(uint256 buyId, uint256 sellId) external {
        Order storage buy = _orders[buyId];
        Order storage sell = _orders[sellId];

        // 1. Active checks
        if (!buy.active || !sell.active) revert Windmill_OrderInactive();
        // 2. Side validation (buy must be buy, sell must be sell)
        if (!buy.isBuy || sell.isBuy) revert Windmill_InvalidMatch();
        // 3. Token pair validation (buy's out is sell's in, buy's in is sell's out)
        if (buy.tokenOut != sell.tokenIn || buy.tokenIn != sell.tokenOut)
            revert Windmill_InvalidMatch();

        uint256 ts = block.timestamp;
        uint256 buyPrice = PriceMath.priceAt(
            buy.startPrice,
            buy.slope,
            buy.startTime,
            ts
        );
        uint256 sellPrice = PriceMath.priceAt(
            sell.startPrice,
            sell.slope,
            sell.startTime,
            ts
        );
        // 4. Price cross validation (settlement at sellPrice)
        if (buyPrice < sellPrice) revert Windmill_PriceNotCrossed();

        // Settlement at sellPrice (maker price).
        // SELL.remainingAmount = base; BUY.remainingAmount = quote. Unit-consistent: tradeBase in base, tradeQuote in quote.
        uint256 maxBaseFromBuy = (buy.remainingAmount * PRICE_SCALE) /
            sellPrice;
        uint256 tradeBase = sell.remainingAmount < maxBaseFromBuy
            ? sell.remainingAmount
            : maxBaseFromBuy;
        uint256 tradeQuote = (tradeBase * sellPrice) / PRICE_SCALE;

        // 5. Trade > 0 validation
        if (tradeBase == 0) revert Windmill_ZeroAmount();

        // Effects first (CEI): decrease remaining in same units (base for sell, quote for buy).
        sell.remainingAmount -= tradeBase;
        buy.remainingAmount -= tradeQuote;
        if (buy.remainingAmount == 0) buy.active = false;
        if (sell.remainingAmount == 0) sell.active = false;

        // Interactions: transfer base from sell escrow to buyer; quote from buy escrow to seller.
        IERC20(sell.tokenIn).safeTransfer(buy.owner, tradeBase);
        IERC20(buy.tokenIn).safeTransfer(sell.owner, tradeQuote);

        emit OrdersMatched(buyId, sellId, msg.sender, tradeBase, tradeQuote);
    }

    /// @inheritdoc IWindmill
    function cancelOrder(uint256 orderId) external {
        Order storage order = _orders[orderId];
        if (order.owner != msg.sender) revert Windmill_NotOwner();
        if (!order.active) revert Windmill_OrderInactive();

        order.active = false;
        uint256 refund = order.remainingAmount;
        order.remainingAmount = 0;

        IERC20(order.tokenIn).safeTransfer(msg.sender, refund);
        emit OrderCancelled(orderId, msg.sender);
    }

    /// @inheritdoc IWindmill
    function priceAt(
        uint256 orderId,
        uint256 timestamp
    ) external view returns (uint256) {
        Order storage order = _orders[orderId];
        return
            PriceMath.priceAt(
                order.startPrice,
                order.slope,
                order.startTime,
                timestamp
            );
    }

    /// @inheritdoc IWindmill
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }
}
