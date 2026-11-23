
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockWETH} from "../src/MockWETH.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        MockUSDC usdc = new MockUSDC();
        MockWETH weth = new MockWETH();

        vm.stopBroadcast();

        console2.log("MockUSDC deployed at:", address(usdc));
        console2.log("MockWETH deployed at:", address(weth));
    }
}
