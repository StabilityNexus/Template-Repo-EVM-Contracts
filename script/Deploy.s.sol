// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/core/WindmillExchange.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        WindmillExchange exchange = new WindmillExchange();
        vm.stopBroadcast();

        console.log("WindmillExchange deployed at:", address(exchange));
    }
}
