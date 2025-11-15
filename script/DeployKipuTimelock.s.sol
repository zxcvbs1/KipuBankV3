// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KipuTimelock} from "src/KipuTimelock.sol";

// Minimal deploy script for KipuTimelock
// Reads single-address envs and wraps them into arrays
contract DeployKipuTimelock is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 minDelay = vm.envUint("TIMELOCK_MIN_DELAY");
        address proposer = vm.envAddress("TIMELOCK_PROPOSER");
        address executor = vm.envAddress("TIMELOCK_EXECUTOR");
        address admin = vm.envAddress("TIMELOCK_ADMIN");

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;

        vm.startBroadcast(pk);
        KipuTimelock timelock = new KipuTimelock(minDelay, proposers, executors, admin);
        vm.stopBroadcast();

        console2.log("KipuTimelock deployed at:", address(timelock));
        console2.log("MinDelay:", minDelay);
        console2.log("Proposer:", proposer);
        console2.log("Executor:", executor);
        console2.log("Admin:", admin);
    }
}

