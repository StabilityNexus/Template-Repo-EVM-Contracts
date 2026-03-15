// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {AuctionOrderBookPrototype} from "../src/AuctionOrderBookPrototype.sol";

contract DeployAuctionOrderBookPrototype is Script {
    function run() external returns (AuctionOrderBookPrototype deployed) {
        vm.startBroadcast();
        deployed = new AuctionOrderBookPrototype();
        vm.stopBroadcast();
    }
}
