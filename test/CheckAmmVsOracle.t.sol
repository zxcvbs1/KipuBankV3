// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

contract CheckAmmVsOracle is Test {
    function test_amm_vs_oraculo_info() external {
        // Si ORACLE_DEV_BPS == 0 (oraculo deshabilitado), evitar este test informativo
        try vm.envUint("ORACLE_DEV_BPS") returns (uint256 bps) {
            if (bps == 0) return;
        } catch {}

        // Usa exclusivamente las variables unificadas provistas por select-env.sh
        string memory rpc = vm.envString("FORK_RPC_URL");
        vm.createSelectFork(rpc);

        address router = vm.envAddress("V2_ROUTER");
        address weth = vm.envAddress("WETH");
        address usdc = vm.envAddress("USDC");
        address oracle = vm.envAddress("ETH_ORACLE");

        // AMM: amounts out para 1 ETH -> USDC
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = usdc;
        uint256[] memory arr = IUniswapV2Router02(router).getAmountsOut(1 ether, path);
        uint256 ammOut = arr[1]; // USDC 6 dec

        // Oraculo: ETH/USD con 8 dec
        AggregatorV3Interface agg = AggregatorV3Interface(oracle);
        (, int256 answer, , uint256 updatedAt, ) = agg.latestRoundData();
        uint8 od = agg.decimals();
        require(answer > 0, "precio oraculo <= 0");

        uint256 oracleOut = (uint256(answer) * 1e6) / (10 ** od); // USDC 6 dec

        // Diferencia en bps
        uint256 diff = ammOut > oracleOut ? ammOut - oracleOut : oracleOut - ammOut;
        uint256 bps = oracleOut == 0 ? 0 : (diff * 10_000) / oracleOut;

        console2.log("AMM out USDC6:", ammOut);
        console2.log("ORC out USDC6:", oracleOut);
        console2.log("updatedAt:", updatedAt);
        console2.log("diff abs:", diff);
        console2.log("diff bps:", bps);

        // Nota: no assertamos un umbral fijo porque puede variar por bloque/mercado.
        // Si quieres forzar un maximo, exporta MAINNET_ASSERT_BPS y compara:
        // uint256 maxBps = vm.envUint("MAINNET_ASSERT_BPS");
        // assertLe(bps, maxBps, "desviacion excesiva");
    }
}
