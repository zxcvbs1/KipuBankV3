// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KipuBankV3} from "src/KipuBankV3.sol";

/// @notice Helper script to disable the oracle vs Uniswap deviation check
///         by setting oracleDevBps = 0 on an existing KipuBankV3.
///
/// Env vars used:
/// - PRIVATE_KEY: admin key (must have DEFAULT_ADMIN_ROLE on the bank)
/// - KIPUBANKV3_SEPOLIA: address of the deployed KipuBankV3
contract SetOracleDevBpsZero is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address payable bankAddr = payable(vm.envAddress("KIPUBANKV3_SEPOLIA"));

        KipuBankV3 bank = KipuBankV3(bankAddr);
        uint256 beforeBps = bank.oracleDevBps();

        vm.startBroadcast(pk);
        bank.setOracleDevBps(0);
        vm.stopBroadcast();

        uint256 afterBps = bank.oracleDevBps();

        console2.log("KipuBankV3:", bankAddr);
        console2.log("oracleDevBps before:", beforeBps);
        console2.log("oracleDevBps after:", afterBps);
    }
}
