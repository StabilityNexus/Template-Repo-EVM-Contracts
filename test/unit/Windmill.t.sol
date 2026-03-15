// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Windmill} from "../../src/core/Windmill.sol";
import {IWindmill} from "../../src/interfaces/IWindmill.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PriceMath} from "../../src/libraries/PriceMath.sol";

/**
 * @title Windmill unit tests
 * @notice Order creation, price evaluation, lazy match, partial fill, cancel, and revert cases.
 */
contract WindmillTest is Test {
    Windmill public windmill;
    MockERC20 public base; // asset
    MockERC20 public quote; // payment token

    address public buyer;
    address public seller;
    address public taker;

    uint256 constant INITIAL_BASE = 1_000_000e18;
    uint256 constant INITIAL_QUOTE = 1_000_000e18;

    function setUp() public {
        windmill = new Windmill();
        base = new MockERC20("Base", "BASE");
        quote = new MockERC20("Quote", "QUOTE");

        buyer = makeAddr("buyer");
        seller = makeAddr("seller");
        taker = makeAddr("taker");

        base.mint(seller, INITIAL_BASE);
        quote.mint(buyer, INITIAL_QUOTE);

        vm.prank(seller);
        base.approve(address(windmill), type(uint256).max);
        vm.prank(buyer);
        quote.approve(address(windmill), type(uint256).max);
    }

    function test_OrderCreation_Buy() public {
        uint256 amount = 1000e18; // quote to escrow
        uint256 startPrice = 1e18; // 1 quote per 1e18 base
        int256 slope = 0;

        vm.prank(buyer);
        uint256 orderId = windmill.createOrder(
            address(quote),
            address(base),
            startPrice,
            slope,
            amount,
            true
        );

        IWindmill.Order memory o = windmill.getOrder(orderId);
        assertEq(o.owner, buyer);
        assertEq(o.tokenIn, address(quote));
        assertEq(o.tokenOut, address(base));
        assertEq(o.startPrice, startPrice);
        assertEq(o.remainingAmount, amount);
        assertTrue(o.isBuy);
        assertTrue(o.active);
        assertEq(quote.balanceOf(address(windmill)), amount);
    }

    function test_OrderCreation_Sell() public {
        uint256 amount = 500e18; // base to escrow
        uint256 startPrice = 1e18;
        int256 slope = 0;

        vm.prank(seller);
        uint256 orderId = windmill.createOrder(
            address(base),
            address(quote),
            startPrice,
            slope,
            amount,
            false
        );

        IWindmill.Order memory o = windmill.getOrder(orderId);
        assertEq(o.owner, seller);
        assertEq(o.tokenIn, address(base));
        assertEq(o.tokenOut, address(quote));
        assertEq(o.remainingAmount, amount);
        assertFalse(o.isBuy);
        assertTrue(o.active);
        assertEq(base.balanceOf(address(windmill)), amount);
    }

    function test_PriceAt_ZeroElapsed() public {
        vm.prank(buyer);
        uint256 orderId = windmill.createOrder(
            address(quote),
            address(base),
            10e18,
            0,
            100e18,
            true
        );
        uint256 ts = block.timestamp;
        assertEq(windmill.priceAt(orderId, ts), 10e18);
        assertEq(windmill.priceAt(orderId, ts + 1), 10e18);
    }

    function test_PriceAt_OneHour() public {
        vm.prank(buyer);
        uint256 orderId = windmill.createOrder(
            address(quote),
            address(base),
            10e18,
            1e15, // +1e15 per second
            100e18,
            true
        );
        uint256 oneHour = 3600;
        vm.warp(block.timestamp + oneHour);
        uint256 expected = 10e18 + (1e15 * oneHour);
        assertEq(windmill.priceAt(orderId, block.timestamp), expected);
    }

    function test_PriceAt_24Hours_Dutch() public {
        vm.prank(seller);
        uint256 orderId = windmill.createOrder(
            address(base),
            address(quote),
            100e18,
            -1e15, // Dutch
            100e18,
            false
        );
        uint256 day = 24 * 3600;
        vm.warp(block.timestamp + day);
        uint256 expected = 100e18 - (1e15 * day);
        assertEq(windmill.priceAt(orderId, block.timestamp), expected);
    }

    function test_SuccessfulLazyMatch() public {
        vm.prank(buyer);
        uint256 buyId = windmill.createOrder(
            address(quote),
            address(base),
            1e18,
            0,
            200e18,
            true
        );
        vm.prank(seller);
        uint256 sellId = windmill.createOrder(
            address(base),
            address(quote),
            1e18,
            0,
            100e18,
            false
        );

        uint256 buyerBaseBefore = base.balanceOf(buyer);
        uint256 sellerQuoteBefore = quote.balanceOf(seller);

        vm.prank(taker);
        windmill.matchOrders(buyId, sellId);

        // Sell 100 base at 1e18 -> 100 quote to seller. Buy gives 100 quote, gets 100 base.
        assertEq(base.balanceOf(buyer), buyerBaseBefore + 100e18);
        assertEq(quote.balanceOf(seller), sellerQuoteBefore + 100e18);
        assertEq(windmill.getOrder(sellId).remainingAmount, 0);
        assertTrue(!windmill.getOrder(sellId).active);
        assertEq(windmill.getOrder(buyId).remainingAmount, 100e18); // 100 quote left
        assertTrue(windmill.getOrder(buyId).active);
    }

    function test_PartialFill() public {
        vm.prank(buyer);
        uint256 buyId = windmill.createOrder(
            address(quote),
            address(base),
            1e18,
            0,
            300e18,
            true
        );
        vm.prank(seller);
        uint256 sellId = windmill.createOrder(
            address(base),
            address(quote),
            1e18,
            0,
            100e18,
            false
        );

        vm.prank(taker);
        windmill.matchOrders(buyId, sellId);

        assertEq(base.balanceOf(buyer), 100e18);
        assertEq(quote.balanceOf(seller), 100e18);
        assertEq(windmill.getOrder(buyId).remainingAmount, 200e18);

        // Second match: another 100 base
        vm.prank(seller);
        uint256 sellId2 = windmill.createOrder(
            address(base),
            address(quote),
            1e18,
            0,
            50e18,
            false
        );
        vm.prank(taker);
        windmill.matchOrders(buyId, sellId2);
        assertEq(base.balanceOf(buyer), 150e18);
        assertEq(windmill.getOrder(buyId).remainingAmount, 150e18);
    }

    function test_CancelOrder() public {
        vm.prank(buyer);
        uint256 orderId = windmill.createOrder(
            address(quote),
            address(base),
            1e18,
            0,
            50e18,
            true
        );
        uint256 buyerQuoteBefore = quote.balanceOf(buyer);

        vm.prank(buyer);
        windmill.cancelOrder(orderId);

        assertEq(quote.balanceOf(buyer), buyerQuoteBefore + 50e18);
        assertFalse(windmill.getOrder(orderId).active);
        assertEq(windmill.getOrder(orderId).remainingAmount, 0);
    }

    function test_RevertWhen_BuyPriceLessThanSellPrice() public {
        // Buy at 1e18 (flat), sell at 2e18 (flat) -> no cross
        vm.prank(buyer);
        uint256 buyId = windmill.createOrder(
            address(quote),
            address(base),
            1e18,
            0,
            200e18,
            true
        );
        vm.prank(seller);
        uint256 sellId = windmill.createOrder(
            address(base),
            address(quote),
            2e18,
            0,
            100e18,
            false
        );

        vm.prank(taker);
        vm.expectRevert(Windmill.Windmill_PriceNotCrossed.selector);
        windmill.matchOrders(buyId, sellId);
    }

    function test_RevertOn_NegativePrice() public {
        vm.prank(seller);
        uint256 orderId = windmill.createOrder(
            address(base),
            address(quote),
            10e18,
            -1e18, // steep Dutch
            100e18,
            false
        );
        // After 11 seconds price = 10e18 - 11e18 = -1e18
        vm.warp(block.timestamp + 11);
        vm.expectRevert(PriceMath.PriceMath_NegativePrice.selector);
        windmill.priceAt(orderId, block.timestamp);
    }

    function test_RevertCancel_NotOwner() public {
        vm.prank(buyer);
        uint256 orderId = windmill.createOrder(
            address(quote),
            address(base),
            1e18,
            0,
            50e18,
            true
        );
        vm.prank(seller);
        vm.expectRevert(Windmill.Windmill_NotOwner.selector);
        windmill.cancelOrder(orderId);
    }

    function test_RevertMatch_InvalidPair() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(seller, 1000e18);
        vm.prank(seller);
        other.approve(address(windmill), type(uint256).max);

        vm.prank(buyer);
        uint256 buyId = windmill.createOrder(
            address(quote),
            address(base),
            1e18,
            0,
            100e18,
            true
        );
        vm.prank(seller);
        uint256 sellId = windmill.createOrder(
            address(other),
            address(quote),
            1e18,
            0,
            100e18,
            false
        );
        // buy.tokenOut = base, sell.tokenIn = other -> mismatch
        vm.prank(taker);
        vm.expectRevert(Windmill.Windmill_InvalidMatch.selector);
        windmill.matchOrders(buyId, sellId);
    }
}
