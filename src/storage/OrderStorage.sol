// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Order} from "../types/OrderTypes.sol";

error OrderNotFound();

abstract contract OrderStorage {
    uint256 private _nextOrderId = 1;
    mapping(uint256 => Order) private _orders;

    /// @dev Existence check: an order exists iff its maker is non-zero.
    function _orderExists(uint256 id) private view returns (bool) {
        return _orders[id].maker != address(0);
    }

    function _storeOrder(Order memory order) internal returns (uint256 id) {
        id = _nextOrderId++;
        order.id = id;
        _orders[id] = order;
    }

    function _getOrder(uint256 id) internal view returns (Order storage) {
        if (!_orderExists(id)) revert OrderNotFound();
        return _orders[id];
    }

    function _getOrderMem(uint256 id) internal view returns (Order memory) {
        if (!_orderExists(id)) revert OrderNotFound();
        return _orders[id];
    }

    function _updateRemainingIn(uint256 id, uint256 newRemaining) internal {
        if (!_orderExists(id)) revert OrderNotFound();
        _orders[id].remainingIn = newRemaining;
    }

    function _deactivateOrder(uint256 id) internal {
        if (!_orderExists(id)) revert OrderNotFound();
        _orders[id].active = false;
    }

    function _totalOrders() internal view returns (uint256) {
        return _nextOrderId - 1;
    }
}
