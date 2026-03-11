// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {WindmillExchange} from "../src/core/WindmillExchange.sol";
import {Order} from "../src/types/OrderTypes.sol";
import {
    ZeroAddress,
    ZeroAmount,
    ZeroStartPrice,
    InvalidExpiry,
    InvalidPriceBounds,
    SlopeOverflow,
    NotMaker,
    OrderInactive,
    OrderExpired,
    SelfMatch,
    NoCross,
    PairMismatch,
    ZeroSettlementPrice
} from "../src/core/WindmillExchange.sol";

contract MockERC20 {
    string  public name;
    string  public symbol;
    uint8   public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256)                     public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to,       uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}

contract WindmillExchangeTest is Test {
    uint256 internal constant RAY = 1e27;

    WindmillExchange internal exchange;
    MockERC20        internal tokenA;
    MockERC20        internal tokenB;

    address internal alice  = makeAddr("alice");
    address internal bob    = makeAddr("bob");

    function setUp() public {
        exchange = new WindmillExchange();
        tokenA   = new MockERC20("TokenA", "TKNA");
        tokenB   = new MockERC20("TokenB", "TKNB");

        tokenA.mint(alice, 1_000_000 ether);
        tokenB.mint(bob,   1_000_000 ether);

        vm.prank(alice); tokenA.approve(address(exchange), type(uint256).max);
        vm.prank(alice); tokenB.approve(address(exchange), type(uint256).max);
        vm.prank(bob);   tokenA.approve(address(exchange), type(uint256).max);
        vm.prank(bob);   tokenB.approve(address(exchange), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Alice buys tokenB with tokenA.  tokenIn=tokenA, tokenOut=tokenB.
    function _createBuyOrder(address maker, uint256 amountIn, uint256 startPrice, int256 slope, uint256 expiry)
        internal returns (uint256)
    {
        vm.prank(maker);
        return exchange.createOrder(address(tokenA), address(tokenB), amountIn, startPrice, slope, 0, 0, expiry, true);
    }

    /// @dev Bob sells tokenB for tokenA.  tokenIn=tokenB, tokenOut=tokenA.
    function _createSellOrder(address maker, uint256 amountIn, uint256 startPrice, int256 slope, uint256 expiry)
        internal returns (uint256)
    {
        vm.prank(maker);
        return exchange.createOrder(address(tokenB), address(tokenA), amountIn, startPrice, slope, 0, 0, expiry, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // createOrder — success
    // ─────────────────────────────────────────────────────────────────────────

    function test_createBuyOrder_success() public {
        uint256 amount     = 1000 ether;
        uint256 startPrice = 2 * RAY;

        vm.expectEmit(true, true, true, true);
        emit WindmillExchange.OrderCreated(1, alice, address(tokenA), address(tokenB), amount, true);

        uint256 id = _createBuyOrder(alice, amount, startPrice, 0, 0);

        assertEq(id, 1);

        Order memory o = exchange.getOrder(id);
        assertEq(o.maker,       alice);
        assertEq(o.tokenIn,     address(tokenA));
        assertEq(o.tokenOut,    address(tokenB));
        assertEq(o.amountIn,    amount);
        assertEq(o.remainingIn, amount);
        assertEq(o.startPrice,  startPrice);
        assertTrue(o.isBuy);
        assertTrue(o.active);

        assertEq(tokenA.balanceOf(address(exchange)), amount);
        assertEq(tokenA.balanceOf(alice), 1_000_000 ether - amount);
    }

    function test_createSellOrder_success() public {
        uint256 amount = 500 ether;
        uint256 id     = _createSellOrder(bob, amount, 2 * RAY, 0, 0);

        Order memory o = exchange.getOrder(id);
        assertFalse(o.isBuy);
        assertEq(o.tokenIn,  address(tokenB));
        assertEq(o.tokenOut, address(tokenA));
        assertEq(tokenB.balanceOf(address(exchange)), amount);
    }

    function test_createOrder_withExpiry() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 id = _createBuyOrder(alice, 100 ether, RAY, 0, expiry);
        assertEq(exchange.getOrder(id).expiry, expiry);
    }

    function test_createOrder_withSlope() public {
        int256 slope = int256(RAY / 1000);
        uint256 id = _createBuyOrder(alice, 100 ether, RAY, slope, 0);
        assertEq(exchange.getOrder(id).slope, slope);
    }

    function test_ordersByPair_registered() public {
        _createBuyOrder(alice, 100 ether, RAY, 0, 0);
        _createSellOrder(bob,  100 ether, RAY, 0, 0);
        assertEq(exchange.getOrdersByPair(address(tokenA), address(tokenB)).length, 2);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // createOrder — reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_createOrder_revert_zeroTokenIn() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAddress.selector);
        exchange.createOrder(address(0), address(tokenB), 100 ether, RAY, 0, 0, 0, 0, true);
    }

    function test_createOrder_revert_zeroTokenOut() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAddress.selector);
        exchange.createOrder(address(tokenA), address(0), 100 ether, RAY, 0, 0, 0, 0, true);
    }

    function test_createOrder_revert_sameToken() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAddress.selector);
        exchange.createOrder(address(tokenA), address(tokenA), 100 ether, RAY, 0, 0, 0, 0, true);
    }

    function test_createOrder_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        exchange.createOrder(address(tokenA), address(tokenB), 0, RAY, 0, 0, 0, 0, true);
    }

    function test_createOrder_revert_zeroStartPrice() public {
        vm.prank(alice);
        vm.expectRevert(ZeroStartPrice.selector);
        exchange.createOrder(address(tokenA), address(tokenB), 100 ether, 0, 0, 0, 0, 0, true);
    }

    function test_createOrder_revert_expiryInPast() public {
        vm.warp(1000);
        vm.prank(alice);
        vm.expectRevert(InvalidExpiry.selector);
        exchange.createOrder(address(tokenA), address(tokenB), 100 ether, RAY, 0, 0, 0, 999, true);
    }

    function test_createOrder_revert_slopeOverflow() public {
        vm.prank(alice);
        vm.expectRevert(SlopeOverflow.selector);
        exchange.createOrder(address(tokenA), address(tokenB), 100 ether, RAY, type(int128).max, 0, 0, 0, true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // cancelOrder
    // ─────────────────────────────────────────────────────────────────────────

    function test_cancelOrder_success() public {
        uint256 amount = 200 ether;
        uint256 id = _createBuyOrder(alice, amount, RAY, 0, 0);
        uint256 balBefore = tokenA.balanceOf(alice);

        vm.expectEmit(true, true, false, true);
        emit WindmillExchange.OrderCancelled(id, alice, amount);

        vm.prank(alice);
        exchange.cancelOrder(id);

        assertFalse(exchange.getOrder(id).active);
        assertEq(tokenA.balanceOf(alice), balBefore + amount);
        assertEq(exchange.getOrdersByPair(address(tokenA), address(tokenB)).length, 0);
    }

    function test_cancelOrder_revert_notMaker() public {
        uint256 id = _createBuyOrder(alice, 100 ether, RAY, 0, 0);
        vm.prank(bob);
        vm.expectRevert(NotMaker.selector);
        exchange.cancelOrder(id);
    }

    function test_cancelOrder_revert_alreadyInactive() public {
        uint256 id = _createBuyOrder(alice, 100 ether, RAY, 0, 0);
        vm.prank(alice); exchange.cancelOrder(id);
        vm.prank(alice);
        vm.expectRevert(OrderInactive.selector);
        exchange.cancelOrder(id);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // matchOrders — success (full fill)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Equal amounts at same price → both orders fully filled.
    ///      buyPrice == sellPrice → hasCrossed == true, settlementPrice == startPrice.
    ///      When an order is fully filled, _deactivateOrder is called (not _updateRemainingIn),
    ///      so `remainingIn` in storage is unchanged — test checks active==false instead.
    function test_matchOrders_success_fullFill() public {
        uint256 price  = RAY;          // 1 tokenA per tokenB
        uint256 amount = 100 ether;

        // At price = 1 RAY, 100 tokenA buys exactly 100 tokenB.
        uint256 buyId  = _createBuyOrder(alice, amount, price, 0, 0);   // pays tokenA
        uint256 sellId = _createSellOrder(bob,  amount, price, 0, 0);   // pays tokenB

        uint256 aliceTokenBBefore = tokenB.balanceOf(alice);
        uint256 bobTokenABefore   = tokenA.balanceOf(bob);

        exchange.matchOrders(buyId, sellId);

        // Both orders should be deactivated (fully filled)
        assertFalse(exchange.getOrder(buyId).active,  "buy should be inactive");
        assertFalse(exchange.getOrder(sellId).active, "sell should be inactive");

        // Alice should have received tokenB (filledAsset from sell order)
        assertGt(tokenB.balanceOf(alice), aliceTokenBBefore, "alice should receive tokenB");
        // Bob should have received tokenA (paymentOwed from buy order)
        assertGt(tokenA.balanceOf(bob), bobTokenABefore, "bob should receive tokenA");

        // Pair should have no active orders
        assertEq(exchange.getOrdersByPair(address(tokenA), address(tokenB)).length, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // matchOrders — partial fills
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Buy order is smaller than sell order → buy fully fills, sell is partial.
    function test_matchOrders_partialFill_buySmaller() public {
        uint256 price    = RAY;
        uint256 buyAmt   = 50 ether;   // buyer deposits 50 tokenA
        uint256 sellAmt  = 100 ether;  // seller deposits 100 tokenB

        uint256 buyId  = _createBuyOrder(alice, buyAmt,  price, 0, 0);
        uint256 sellId = _createSellOrder(bob,  sellAmt, price, 0, 0);

        exchange.matchOrders(buyId, sellId);

        Order memory buyOrder  = exchange.getOrder(buyId);
        Order memory sellOrder = exchange.getOrder(sellId);

        // Buy fully consumed — deactivated (remainingIn in storage is unchanged;
        // _updateRemainingIn is only called for partial fills)
        assertFalse(buyOrder.active,            "buy should be inactive after full fill");

        // Sell still active with reduced remaining
        assertTrue(sellOrder.active,            "sell should still be active");
        assertLt(sellOrder.remainingIn, sellAmt, "sell.remainingIn should have decreased");
        assertGt(sellOrder.remainingIn, 0,       "sell.remainingIn should not be 0 yet");

        // Alice received tokenB
        assertGt(tokenB.balanceOf(alice), 0, "alice should receive some tokenB");
        // Bob received tokenA
        assertGt(tokenA.balanceOf(bob), 0,   "bob should receive some tokenA");
    }

    /// @dev Sell order is smaller than buy order → sell fully fills, buy is partial.
    ///      When fully filled, _deactivateOrder is called but _updateRemainingIn is NOT.
    function test_matchOrders_partialFill_sellSmaller() public {
        uint256 price    = RAY;
        uint256 buyAmt   = 100 ether;  // buyer deposits 100 tokenA
        uint256 sellAmt  = 40 ether;   // seller deposits 40 tokenB

        uint256 buyId  = _createBuyOrder(alice, buyAmt,  price, 0, 0);
        uint256 sellId = _createSellOrder(bob,  sellAmt, price, 0, 0);

        exchange.matchOrders(buyId, sellId);

        Order memory buyOrder  = exchange.getOrder(buyId);
        Order memory sellOrder = exchange.getOrder(sellId);

        // Sell fully consumed — deactivated
        assertFalse(sellOrder.active,           "sell should be inactive after full fill");

        // Buy still active with reduced remaining
        assertTrue(buyOrder.active,             "buy should still be active");
        assertLt(buyOrder.remainingIn, buyAmt,  "buy.remainingIn should have decreased");
        assertGt(buyOrder.remainingIn, 0,       "buy.remainingIn should not be 0 yet");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // matchOrders — reverts
    // ─────────────────────────────────────────────────────────────────────────

    function test_matchOrders_revert_expired() public {
        vm.warp(1000);
        uint256 expiry = 1500;
        uint256 price  = RAY;

        uint256 buyId  = _createBuyOrder(alice, 100 ether, price, 0, expiry);
        uint256 sellId = _createSellOrder(bob,  100 ether, price, 0, 0);

        // Advance past expiry
        vm.warp(expiry + 1);
        vm.expectRevert(OrderExpired.selector);
        exchange.matchOrders(buyId, sellId);
    }

    function test_matchOrders_revert_selfMatch() public {
        // Give alice tokenB as well so she can create both sides
        tokenB.mint(alice, 100 ether);
        vm.prank(alice); tokenB.approve(address(exchange), type(uint256).max);

        uint256 price = RAY;
        uint256 buyId = _createBuyOrder(alice, 100 ether, price, 0, 0);

        // Alice creates the sell order too
        vm.prank(alice);
        uint256 sellId = exchange.createOrder(
            address(tokenB), address(tokenA), 100 ether, price, 0, 0, 0, 0, false
        );

        vm.expectRevert(SelfMatch.selector);
        exchange.matchOrders(buyId, sellId);
    }

    function test_matchOrders_revert_noCross() public {
        // buyPrice (0.5 RAY) < sellPrice (2 RAY) → no crossing
        uint256 buyId  = _createBuyOrder(alice, 100 ether, RAY / 2, 0, 0);
        uint256 sellId = _createSellOrder(bob,  100 ether, RAY * 2, 0, 0);

        vm.expectRevert(NoCross.selector);
        exchange.matchOrders(buyId, sellId);
    }

    function test_matchOrders_revert_pairMismatch_wrongIsBuy() public {
        // A buy order matched against another buy order (sell.isBuy=true) triggers PairMismatch.
        uint256 buyId = _createBuyOrder(alice, 100 ether, RAY, 0, 0);

        // Bob creates another buy-side order (isBuy=true) to act as the "sell" argument
        tokenA.mint(bob, 100 ether);
        vm.prank(bob); tokenA.approve(address(exchange), type(uint256).max);
        vm.prank(bob);
        uint256 wrongSellId = exchange.createOrder(
            address(tokenA), address(tokenB), 100 ether, RAY, 0, 0, 0, 0, true  // isBuy=true on sell side
        );

        vm.expectRevert(PairMismatch.selector);
        exchange.matchOrders(buyId, wrongSellId);
    }

    function test_matchOrders_revert_pairMismatch_differentTokens() public {
        // Introduce a third token to create a genuine pair mismatch
        MockERC20 tokenC = new MockERC20("TokenC", "TKNC");
        tokenC.mint(bob, 100 ether);
        vm.prank(bob); tokenC.approve(address(exchange), type(uint256).max);

        uint256 buyId = _createBuyOrder(alice, 100 ether, RAY, 0, 0);

        // Sell order for tokenC→tokenA instead of tokenB→tokenA
        vm.prank(bob);
        uint256 sellId = exchange.createOrder(
            address(tokenC), address(tokenA), 100 ether, RAY, 0, 0, 0, 0, false
        );

        vm.expectRevert(PairMismatch.selector);
        exchange.matchOrders(buyId, sellId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // currentPrice
    // ─────────────────────────────────────────────────────────────────────────

    function test_currentPrice_flatOrder_returnsStartPrice() public {
        uint256 startPrice = 3 * RAY;
        uint256 id = _createBuyOrder(alice, 100 ether, startPrice, 0, 0);

        // With slope=0, price should always equal startPrice regardless of timestamp
        assertEq(exchange.currentPrice(id, block.timestamp),         startPrice);
        assertEq(exchange.currentPrice(id, block.timestamp + 1 days), startPrice);
    }

    function test_currentPrice_descendingSlope_decreasesOverTime() public {
        uint256 startPrice = 4 * RAY;
        int256  slope      = -int256(RAY / 1000);  // price decreases 1e24 per second

        uint256 id = _createBuyOrder(alice, 100 ether, startPrice, slope, 0);
        uint256 t0 = block.timestamp;

        uint256 priceNow   = exchange.currentPrice(id, t0);
        uint256 priceLater = exchange.currentPrice(id, t0 + 1000);

        assertEq(priceNow, startPrice);
        assertLt(priceLater, priceNow, "price should decrease over time with negative slope");
    }

    function test_currentPrice_afterFullMatch_orderInactive() public {
        uint256 price = RAY;
        uint256 buyId  = _createBuyOrder(alice, 100 ether, price, 0, 0);
        uint256 sellId = _createSellOrder(bob,  100 ether, price, 0, 0);

        exchange.matchOrders(buyId, sellId);

        // Order is inactive but getOrder still allows reading; price is still computable
        Order memory o = exchange.getOrder(buyId);
        assertFalse(o.active);
        // currentPrice still returns a value based on stored params (no revert)
        assertEq(exchange.currentPrice(buyId, block.timestamp), price);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fuzz
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_escrow(uint96 amount) public {
        vm.assume(amount > 0);
        tokenA.mint(alice, amount);
        uint256 id = _createBuyOrder(alice, amount, RAY, 0, 0);
        assertEq(exchange.getOrder(id).remainingIn, amount);
    }
}
