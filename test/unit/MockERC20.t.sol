// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/**
 * @title MockERC20 unit tests
 * @notice Ensures template MockERC20 works with mint and standard ERC20 behavior.
 */
contract MockERC20Test is Test {
    MockERC20 public token;

    function setUp() public {
        token = new MockERC20("Test Token", "TST");
    }

    function test_Mint() public {
        token.mint(address(this), 1000e18);
        assertEq(token.balanceOf(address(this)), 1000e18);
        assertEq(token.totalSupply(), 1000e18);
    }

    function test_Transfer() public {
        token.mint(address(this), 100e18);
        require(token.transfer(address(0x1), 40e18));
        assertEq(token.balanceOf(address(this)), 60e18);
        assertEq(token.balanceOf(address(0x1)), 40e18);
    }

    function test_NameAndSymbol() public view {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TST");
        assertEq(token.decimals(), 18);
    }
}
