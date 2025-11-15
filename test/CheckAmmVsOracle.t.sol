// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

// Prueba informativa: compara el out del AMM para 1 ETH->USDC contra el precio del oraculo.
// No es un assert estricto porque la diferencia depende del bloque y la liquidez.
contract CheckAmmVsOracle is Test {
    function test_amm_vs_oraculo_info() external {
        // Si ORACLE_DEV_BPS == 0 (oraculo deshabilitado), evitamos este test informativo
        try vm.envUint("ORACLE_DEV_BPS") returns (uint256 bps) {
            if (bps == 0) return;
        } catch {}

        // Usar FORK_RPC_URL si existe; fallback a SEPOLIA_RPC_URL. Usar FORK_BLOCK si está definido.
        string memory rpc;
        try vm.envString("FORK_RPC_URL") returns (string memory frpc) { rpc = frpc; } catch { rpc = vm.envString("SEPOLIA_RPC_URL"); }
        try vm.envUint("FORK_BLOCK") returns (uint256 fb) {
            if (fb > 0) { vm.createSelectFork(rpc, fb); } else { vm.createSelectFork(rpc); }
        } catch {
            vm.createSelectFork(rpc);
        }

        address router = vm.envAddress("V2_ROUTER");
        address weth = vm.envAddress("WETH");
        address usdc = vm.envAddress("USDC");
        address oracle = vm.envAddress("ETH_ORACLE");

        // AMM: obtener amountsOut para 1 ETH -> USDC
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = usdc;
        uint256[] memory arr = IUniswapV2Router02(router).getAmountsOut(1 ether, path);
        uint256 ammOut = arr[1]; // USDC 6 decimales

        // Oraculo: ETH/USD con 8 decimales tipicamente
        AggregatorV3Interface agg = AggregatorV3Interface(oracle);
        (, int256 answer, , uint256 updatedAt, ) = agg.latestRoundData();
        uint8 od = agg.decimals();
        require(answer > 0, "precio oraculo <= 0");

        uint256 oracleOut = (uint256(answer) * 1e6) / (10 ** od); // USDC 6 decimales

        // Diferencia en bps para referencia
        uint256 diff = ammOut > oracleOut ? ammOut - oracleOut : oracleOut - ammOut;
        uint256 bps = oracleOut == 0 ? 0 : (diff * 10_000) / oracleOut;

        console2.log("AMM out USDC6:", ammOut);
        console2.log("ORC out USDC6:", oracleOut);
        console2.log("updatedAt:", updatedAt);
        console2.log("diff abs:", diff);
        console2.log("diff bps:", bps);

        // Nota: si quieres forzar un maximo, exporta MAINNET_ASSERT_BPS y compara:
        // uint256 maxBps = vm.envUint("MAINNET_ASSERT_BPS");
        // assertLe(bps, maxBps, "desviacion excesiva");
    }
}
