// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {pairKeyOf} from "../types/OrderTypes.sol";

abstract contract PairStorage {
    mapping(bytes32 => uint256[]) private _pairOrders;
    mapping(uint256 => uint256)   private _pairIndex;

    function _addOrderToPair(address tokenA, address tokenB, uint256 orderId) internal {
        bytes32 key = pairKeyOf(tokenA, tokenB);
        _pairOrders[key].push(orderId);
        _pairIndex[orderId] = _pairOrders[key].length;
    }

    function _removeOrderFromPair(address tokenA, address tokenB, uint256 orderId) internal {
        bytes32 key = pairKeyOf(tokenA, tokenB);
        uint256 idx = _pairIndex[orderId];
        if (idx == 0) return;

        uint256[] storage list = _pairOrders[key];
        uint256 lastIdx = list.length;

        if (idx != lastIdx) {
            uint256 lastId = list[lastIdx - 1];
            list[idx - 1] = lastId;
            _pairIndex[lastId] = idx;
        }

        list.pop();
        delete _pairIndex[orderId];
    }

    function _getOrdersByPair(address tokenA, address tokenB)
        internal
        view
        returns (uint256[] memory)
    {
        return _pairOrders[pairKeyOf(tokenA, tokenB)];
    }
}
