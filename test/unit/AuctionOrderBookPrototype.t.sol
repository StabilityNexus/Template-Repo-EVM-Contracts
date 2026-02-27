// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AuctionOrderBookPrototype} from "../../src/AuctionOrderBookPrototype.sol";

contract AuctionOrderBookPrototypeTest is Test {
    AuctionOrderBookPrototype internal book;

    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);

    function setUp() public {
        book = new AuctionOrderBookPrototype();
        vm.deal(maker, 1000 ether);
        vm.deal(taker, 1000 ether);
    }

    function _createBuyOrder(
        uint256 amount,
        uint256 startPrice,
        int256 slope,
        uint256 stopPrice,
        uint256 expiryTime
    ) internal returns (uint256) {
        vm.prank(maker);
        return book.createOrder{value: amount * startPrice}(true, amount, startPrice, slope, stopPrice, expiryTime);
    }

    function test_createBuyOrder_storesEscrow() public {
        uint256 startPrice = 0.01 ether;
        uint256 id = _createBuyOrder(10, startPrice, 0, 0, 0);

        AuctionOrderBookPrototype.Order memory o = book.getOrder(id);
        assertEq(o.creator, maker);
        assertTrue(o.isBuy);
        assertEq(o.amount, 10);
        assertEq(o.escrowedEth, 10 * startPrice);
        assertTrue(o.active);
    }

    function test_createSellOrder_rejectsEth() public {
        vm.prank(maker);
        vm.expectRevert("Sell order should not send ETH");
        book.createOrder{value: 1}(false, 5, 0.01 ether, 0, 0, 0);
    }

    function test_currentPrice_becomesZeroAfterExpiry() public {
        uint256 startPrice = 0.01 ether;
        uint256 expiry = block.timestamp + 10;
        uint256 id = _createBuyOrder(10, startPrice, 0, 0, expiry);

        vm.warp(expiry + 1);
        assertEq(book.currentPrice(id), 0);
        assertTrue(book.isExpired(id));
    }

    function test_executeOrder_blocksCreatorSelfExecution() public {
        uint256 id = _createBuyOrder(10, 0.01 ether, 0, 0, 0);

        vm.prank(maker);
        vm.expectRevert("Creator cannot execute own order");
        book.executeOrder(id, 1);
    }

    function test_executeSellOrder_requiresExactEth() public {
        vm.prank(maker);
        uint256 id = book.createOrder(false, 10, 0.01 ether, 0, 0, 0);

        vm.prank(taker);
        vm.expectRevert("Must pay exact ETH");
        book.executeOrder{value: 0.050000000000000001 ether}(id, 5);
    }

    function test_partialThenFullFill_clearsBuyEscrow() public {
        uint256 id = _createBuyOrder(10, 0.01 ether, -1e12, 0, 0);

        vm.prank(taker);
        book.executeOrder(id, 4);

        AuctionOrderBookPrototype.Order memory half = book.getOrder(id);
        assertEq(half.amount, 6);
        assertTrue(half.active);

        vm.prank(taker);
        book.executeOrder(id, 6);

        AuctionOrderBookPrototype.Order memory done = book.getOrder(id);
        assertEq(done.amount, 0);
        assertEq(done.escrowedEth, 0);
        assertFalse(done.active);
        assertEq(book.getActiveOrderCount(), 0);
    }

    function test_expireOrder_refundsAndDeactivates() public {
        uint256 id = _createBuyOrder(10, 0.01 ether, 0, 0, block.timestamp + 5);

        vm.warp(block.timestamp + 6);
        vm.prank(taker);
        book.expireOrder(id);

        AuctionOrderBookPrototype.Order memory o = book.getOrder(id);
        assertFalse(o.active);
        assertEq(o.escrowedEth, 0);
        assertEq(book.getActiveOrderCount(), 0);
    }
}
