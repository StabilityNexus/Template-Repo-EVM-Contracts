// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../src/core/WindmillExchange.sol";
import "../src/interface/IWindmill.sol";
import "../src/libraries/PriceLib.sol";

// Minimal ERC-20 we mint freely in tests
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract WindmillExchangeTest is Test {
    WindmillExchange exchange;
    MockERC20 tokenA; // payment token
    MockERC20 tokenB; // commodity token

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    address keeper = makeAddr("keeper");

    // Shared order params
    // Buy order: wants tokenB, offers tokenA, price falls over time
    uint256 constant BUY_START = 1000e18;
    int256 constant BUY_SLOPE = -1e15;
    uint256 constant BUY_END = 800e18;
    // Sell order: wants tokenA, offers tokenB, price rises over time
    uint256 constant SELL_START = 900e18;
    int256 constant SELL_SLOPE = 1e15;
    uint256 constant SELL_END = 1200e18;

    uint256 constant BUY_AMOUNT = 10e18;
    uint256 constant SELL_AMOUNT = 10e18;
    uint256 constant ESCROW_A = 10000e18;

    function setUp() public {
        exchange = new WindmillExchange();
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");

        // Fund makers
        tokenA.mint(maker, 100_000e18);
        tokenB.mint(taker, 100_000e18);
        tokenA.mint(taker, 100_000e18);
        tokenB.mint(maker, 100_000e18);

        // Pre-approve exchange
        vm.prank(maker);
        tokenA.approve(address(exchange), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(exchange), type(uint256).max);
        vm.prank(taker);
        tokenA.approve(address(exchange), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(exchange), type(uint256).max);
    }

    // Helpers

    function _placeBuyOrder() internal returns (uint256) {
        vm.prank(maker);
        return
            exchange.placeOrder(
                address(tokenB),
                address(tokenA), // wants tokenB, offers tokenA
                BUY_AMOUNT,
                ESCROW_A,
                BUY_START,
                BUY_SLOPE,
                BUY_END,
                block.timestamp + 1 hours
            );
    }

    function _placeSellOrder() internal returns (uint256) {
        vm.prank(taker);
        return
            exchange.placeOrder(
                address(tokenA),
                address(tokenB), // wants tokenA, offers tokenB
                ESCROW_A,
                SELL_AMOUNT,
                SELL_START,
                SELL_SLOPE,
                SELL_END,
                block.timestamp + 1 hours
            );
    }

    // Test 1 — placeOrder stores exact fields

    function test_placeOrder_storesExactFields() public {
        uint256 id = _placeBuyOrder();

        (
            address retMaker,
            address retBuy,
            address retSell,
            uint256 retBuyAmt,
            uint256 retSellAmt,
            uint256 retExpiry,
            bool retActive
        ) = exchange.getOrder(id);

        assertEq(retMaker, maker);
        assertEq(retBuy, address(tokenB));
        assertEq(retSell, address(tokenA));
        assertEq(retBuyAmt, BUY_AMOUNT);
        assertEq(retSellAmt, ESCROW_A);
        assertEq(retExpiry, block.timestamp + 1 hours);
        assertTrue(retActive);

        // Escrow balance must equal sellAmount
        assertEq(tokenA.balanceOf(address(exchange)), ESCROW_A);
    }

    // Test 2 — placeOrder reverts on zero buyAmount

    function test_placeOrder_revert_zeroBuyAmount() public {
        vm.prank(maker);
        vm.expectRevert("buyAmount is zero");
        exchange.placeOrder(
            address(tokenB),
            address(tokenA),
            0,
            ESCROW_A, // buyAmount = 0
            BUY_START,
            BUY_SLOPE,
            BUY_END,
            block.timestamp + 1 hours
        );
    }

    // Test 3 — placeOrder revert: buy order endPrice >= startPrice

    function test_placeOrder_revert_buyEndPriceTooHigh() public {
        vm.prank(maker);
        vm.expectRevert("BUY: endPrice must be below startPrice");
        exchange.placeOrder(
            address(tokenB),
            address(tokenA),
            BUY_AMOUNT,
            ESCROW_A,
            BUY_START,
            BUY_SLOPE,
            BUY_START, // endPrice == startPrice → invalid floor
            block.timestamp + 1 hours
        );
    }

    // Test 4 — placeOrder revert: sell order endPrice <= startPrice

    function test_placeOrder_revert_sellEndPriceTooLow() public {
        vm.prank(taker);
        vm.expectRevert("SELL: endPrice must be above startPrice");
        exchange.placeOrder(
            address(tokenA),
            address(tokenB),
            ESCROW_A,
            SELL_AMOUNT,
            SELL_START,
            SELL_SLOPE,
            SELL_START, // endPrice == startPrice → invalid ceiling
            block.timestamp + 1 hours
        );
    }

    // Test 5 — cancelOrder by maker returns full remainingSell

    function test_cancelOrder_byMaker() public {
        uint256 id = _placeBuyOrder();
        uint256 balBefore = tokenA.balanceOf(maker);

        vm.prank(maker);
        exchange.cancelOrder(id);

        assertEq(tokenA.balanceOf(maker), balBefore + ESCROW_A);

        (, , , , , , bool active) = exchange.getOrder(id);
        assertFalse(active);
    }

    // Test 6 — cancelOrder by non-maker reverts

    function test_cancelOrder_revert_nonMaker() public {
        uint256 id = _placeBuyOrder();
        vm.prank(taker);
        vm.expectRevert("Not order maker");
        exchange.cancelOrder(id);
    }

    // Test 7 — priceAt buy order decreases, never below endPrice

    function test_priceAt_buyOrder_decreasesAndClamped() public {
        uint256 id = _placeBuyOrder();
        uint256 p0 = exchange.priceAt(id, block.timestamp);

        // 100 seconds later
        uint256 p1 = exchange.priceAt(id, block.timestamp + 100);
        assertLt(p1, p0); // price fell
        assertGe(p1, BUY_END); // never below floor

        // Far future — must clamp at endPrice
        uint256 pFar = exchange.priceAt(id, block.timestamp + 1_000_000);
        assertEq(pFar, BUY_END);
    }

    // Test 8 — priceAt sell order increases, never above endPrice

    function test_priceAt_sellOrder_increasesAndClamped() public {
        uint256 id = _placeSellOrder();
        uint256 p0 = exchange.priceAt(id, block.timestamp);

        uint256 p1 = exchange.priceAt(id, block.timestamp + 100);
        assertGt(p1, p0); // price rose
        assertLe(p1, SELL_END); // never above ceiling

        uint256 pFar = exchange.priceAt(id, block.timestamp + 1_000_000);
        assertEq(pFar, SELL_END);
    }

    // Test 9 — matchOrders before crossing reverts

    function test_matchOrders_revert_beforeCrossing() public {
        // Fresh orders where buy start (500) < sell start (900) → not yet crossed
        vm.prank(maker);
        uint256 buyId = exchange.placeOrder(
            address(tokenB),
            address(tokenA),
            BUY_AMOUNT,
            ESCROW_A,
            500e18,
            BUY_SLOPE,
            100e18, // buy starts at 500 — below sell start 900
            block.timestamp + 1 hours
        );
        vm.prank(taker);
        uint256 sellId = exchange.placeOrder(
            address(tokenA),
            address(tokenB),
            ESCROW_A,
            SELL_AMOUNT,
            900e18,
            SELL_SLOPE,
            SELL_END,
            block.timestamp + 1 hours
        );

        vm.expectRevert("Prices have not crossed");
        exchange.matchOrders(buyId, sellId);
    }

    // Test 10 — matchOrders after crossing: succeeds, tokens transferred

    function test_matchOrders_afterCrossing() public {
        // BUY_START=1000 > SELL_START=900 → already crossed at t=0
        uint256 buyId = _placeBuyOrder();
        uint256 sellId = _placeSellOrder();

        uint256 makerBefore = tokenB.balanceOf(maker); // buyer receives tokenB
        uint256 takerBefore = tokenA.balanceOf(taker); // seller receives tokenA

        vm.expectEmit(true, true, false, false);
        emit IWindmill.OrderMatched(buyId, sellId, 0, 0, 0, address(this));

        exchange.matchOrders(buyId, sellId);

        // Buyer received some tokenB
        assertGt(tokenB.balanceOf(maker), makerBefore);
        // Seller received some tokenA
        assertGt(tokenA.balanceOf(taker), takerBefore);
    }

    // Test 11 — matchOrders partial fill

    function test_matchOrders_partialFill() public {
        // Sell has low buy-demand and higher sell-supply.
        // At settlement=950e18, fill is capped by sell.remainingBuy, leaving residual sell escrow.
        vm.prank(taker);
        uint256 sellId = exchange.placeOrder(
            address(tokenA),
            address(tokenB),
            950e18, // seller only wants 950 tokenA total
            5e18, // but escrows 5 tokenB
            SELL_START,
            SELL_SLOPE,
            SELL_END,
            block.timestamp + 1 hours
        );
        uint256 buyId = _placeBuyOrder(); // wants 10 tokenB

        uint256 makerBBefore = tokenB.balanceOf(maker);
        uint256 takerABefore = tokenA.balanceOf(taker);
        uint256 takerBBefore = tokenB.balanceOf(taker);

        exchange.matchOrders(buyId, sellId);

        // settlementPrice = (1000e18 + 900e18) / 2 = 950e18
        // maxSellFromBuyer      = (10000e18 * 1e18) / 950e18  > 10e18
        // buy.remainingBuy cap  = 10e18
        // sell.remainingSell cap= 5e18
        // seller-demand cap     = (950e18 * 1e18) / 950e18 = 1e18
        // => fillSell = 1e18, fillBuy = 950e18
        assertEq(
            tokenB.balanceOf(maker),
            makerBBefore + 1e18,
            "buyer received wrong tokenB"
        );
        assertEq(
            tokenA.balanceOf(taker),
            takerABefore + 950e18,
            "seller received wrong tokenA"
        );

        // Sell order deactivates because remainingBuy hits zero, while residual sell escrow remains.
        (, , , , , , bool sellActive) = exchange.getOrder(sellId);
        assertFalse(sellActive);

        // Buy order still active after partial fill.
        (, , , , , , bool buyActive) = exchange.getOrder(buyId);
        assertTrue(buyActive);

        // Seller cannot cancel inactive order...
        vm.prank(taker);
        vm.expectRevert("Order not active");
        exchange.cancelOrder(sellId);

        // ...but can recover residual escrow via withdrawResidual.
        vm.prank(taker);
        exchange.withdrawResidual(sellId);
        assertEq(
            tokenB.balanceOf(taker),
            takerBBefore + 4e18,
            "seller did not recover residual escrow"
        );
        assertEq(
            tokenB.balanceOf(address(exchange)),
            0,
            "exchange should hold no tokenB after residual withdrawal"
        );

        // Buyer can cancel the still-active order and recover remaining payment escrow
        uint256 makerABeforeCancel = tokenA.balanceOf(maker);
        vm.prank(maker);
        exchange.cancelOrder(buyId);
        assertGt(
            tokenA.balanceOf(maker),
            makerABeforeCancel,
            "buyer escrow not returned on cancel"
        );
    }

    // Test 12 — matchOrders expired order reverts

    function test_matchOrders_revert_expiredOrder() public {
        uint256 buyId = _placeBuyOrder();
        uint256 sellId = _placeSellOrder();

        // Warp past expiry
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert("Buy order expired");
        exchange.matchOrders(buyId, sellId);
    }

    // Test 13 — matchOrders by third-party keeper (permissionless)

    function test_matchOrders_byKeeper_permissionless() public {
        uint256 buyId = _placeBuyOrder();
        uint256 sellId = _placeSellOrder();

        // Keeper is a random third party
        vm.prank(keeper);
        exchange.matchOrders(buyId, sellId); // must not revert
    }

    // Test 14 — matchOrders token pair mismatch reverts

    function test_matchOrders_revert_tokenPairMismatch() public {
        MockERC20 tokenC = new MockERC20("TokenC", "TKC");
        tokenC.mint(taker, 100_000e18);
        vm.prank(taker);
        tokenC.approve(address(exchange), type(uint256).max);

        uint256 buyId = _placeBuyOrder(); // wants tokenB, offers tokenA

        vm.prank(taker);
        uint256 wrongSellId = exchange.placeOrder(
            address(tokenA),
            address(tokenC), // wrong pair — offers tokenC, not tokenB
            ESCROW_A,
            SELL_AMOUNT,
            SELL_START,
            SELL_SLOPE,
            SELL_END,
            block.timestamp + 1 hours
        );

        vm.expectRevert("Token pair mismatch");
        exchange.matchOrders(buyId, wrongSellId);
    }

    // Test 15 — matchOrders self-match reverts

    function test_matchOrders_revert_selfMatch() public {
        // maker places both sides
        tokenB.mint(maker, 100_000e18);
        vm.prank(maker);
        tokenB.approve(address(exchange), type(uint256).max);

        uint256 buyId = _placeBuyOrder();

        vm.prank(maker);
        uint256 sellId = exchange.placeOrder(
            address(tokenA),
            address(tokenB),
            ESCROW_A,
            SELL_AMOUNT,
            SELL_START,
            SELL_SLOPE,
            SELL_END,
            block.timestamp + 1 hours
        );

        vm.expectRevert("Self-match not allowed");
        exchange.matchOrders(buyId, sellId);
    }

    // Test 16 — matchOrders mismatched side reverts

    function test_matchOrders_revert_mismatchedSide() public {
        uint256 buyId1 = _placeBuyOrder();

        // Place a second BUY order from taker
        tokenA.mint(taker, 100_000e18);
        vm.prank(taker);
        tokenA.approve(address(exchange), type(uint256).max);
        vm.prank(taker);
        uint256 buyId2 = exchange.placeOrder(
            address(tokenB),
            address(tokenA),
            BUY_AMOUNT,
            ESCROW_A,
            BUY_START,
            BUY_SLOPE,
            BUY_END,
            block.timestamp + 1 hours
        );

        vm.expectRevert("sellOrderId is not a SELL order");
        exchange.matchOrders(buyId1, buyId2); // two BUY orders
    }

    // Test 17 — pairOrders populated correctly

    function test_pairOrders_populated() public {
        bytes32 key = keccak256(abi.encode(address(tokenB), address(tokenA)));

        _placeBuyOrder();
        assertEq(exchange.pairOrders(key, 0), 0); // first orderId = 0

        _placeBuyOrder();
        assertEq(exchange.pairOrders(key, 1), 1); // second orderId = 1
    }

    // Test 18 — Fuzz: priceAt buy order always >= endPrice

    function testFuzz_priceAt_buyAlwaysAboveFloor(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 30 days);
        uint256 id = _placeBuyOrder();
        uint256 price = exchange.priceAt(id, block.timestamp + elapsed);
        assertGe(price, BUY_END, "buy price dropped below floor");
    }

    // Test 19 — Fuzz: priceAt sell order always <= endPrice

    function testFuzz_priceAt_sellAlwaysBelowCeiling(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 30 days);
        uint256 id = _placeSellOrder();
        uint256 price = exchange.priceAt(id, block.timestamp + elapsed);
        assertLe(price, SELL_END, "sell price exceeded ceiling");
    }

    // Test 20 — Fuzz: token conservation in matchOrders

    function testFuzz_matchOrders_tokenConservation(uint256 elapsed) public {
        // Keep within expiry (1 hour) and ensure prices stay crossed
        elapsed = bound(elapsed, 0, 30 minutes);
        vm.warp(block.timestamp + elapsed);

        uint256 buyId = _placeBuyOrder();
        uint256 sellId = _placeSellOrder();

        uint256 exchangeABefore = tokenA.balanceOf(address(exchange));
        uint256 exchangeBBefore = tokenB.balanceOf(address(exchange));

        exchange.matchOrders(buyId, sellId);

        uint256 exchangeAAfter = tokenA.balanceOf(address(exchange));
        uint256 exchangeBAfter = tokenB.balanceOf(address(exchange));

        // Exchange never gains tokens — only routes them
        assertLe(exchangeAAfter, exchangeABefore, "exchange gained tokenA");
        assertLe(exchangeBAfter, exchangeBBefore, "exchange gained tokenB");
    }

    // Test 21 — placeOrder reverts when |slope| > type(uint128).max

    function test_placeOrder_revert_slopeMagnitudeOverflow() public {
        int256 hugeSlope = -int256(uint256(type(uint128).max) + 1);
        vm.prank(maker);
        vm.expectRevert("slope magnitude overflow");
        exchange.placeOrder(
            address(tokenB),
            address(tokenA),
            BUY_AMOUNT,
            ESCROW_A,
            BUY_START,
            hugeSlope,
            BUY_END,
            block.timestamp + 1 hours
        );
    }
}
