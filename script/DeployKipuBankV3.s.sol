// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {KipuBankV3, IUniswapV2Factory} from "src/KipuBankV3.sol";

contract DeployKipuBankV3 is Script {
    function run() external {
        // Env vars requeridas
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.envAddress("ADMIN");
        address pauser = vm.envAddress("PAUSER");
        // Router: preferimos variable unificada V2_ROUTER, con fallback a ROUTER para compatibilidad
        address router;
        try vm.envAddress("V2_ROUTER") returns (address r) {
            router = r;
        } catch {
            router = vm.envAddress("ROUTER");
        }
        address usdc = vm.envAddress("USDC");
        uint256 bankCapUSD6 = vm.envUint("BANK_CAP_USD6");
        uint256 withdrawCapUSD6 = vm.envUint("WITHDRAW_CAP_USD6");
        uint16 slippageBps = uint16(vm.envUint("SLIPPAGE_BPS"));
        address ethOracle = vm.envAddress("ETH_ORACLE");
        uint256 oracleMaxDelay = vm.envUint("ORACLE_MAX_DELAY");
        uint256 oracleDevBps = vm.envUint("ORACLE_DEV_BPS");

        vm.startBroadcast(pk);
        KipuBankV3 bank = new KipuBankV3(
            admin,
            pauser,
            router,
            usdc,
            bankCapUSD6,
            withdrawCapUSD6,
            slippageBps,
            ethOracle,
            oracleMaxDelay,
            oracleDevBps
        );
        vm.stopBroadcast();

        console2.log("KipuBankV3 deployed at:", address(bank));
        console2.log("Admin:", admin);
        console2.log("Pauser:", pauser);
        console2.log("Router:", router);
        console2.log("USDC:", usdc);
        console2.log("BankCapUSD6:", bankCapUSD6);
        console2.log("WithdrawCapUSD6:", withdrawCapUSD6);
        console2.log("SlippageBps:", slippageBps);
        console2.log("ETH Oracle:", ethOracle);
        console2.log("OracleMaxDelay:", oracleMaxDelay);
        console2.log("OracleDevBps:", oracleDevBps);

        // Chequeo informativo del par WETH/USDC en la factory
        address factory = address(bank.factory());
        address weth = bank.WETH();
        address pair = IUniswapV2Factory(factory).getPair(weth, usdc);
        if (pair == address(0)) {
            console2.log("[WARN] No existe par directo WETH/USDC en la factory provista.");
        } else {
            console2.log("Pair WETH/USDC:", pair);
        }
    }
}
