// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {KipuBankV3} from "src/KipuBankV3.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

// Suite de pruebas enfocada en el camino con oraculo para ETH.
// Objetivo: validar que cuando oracleDevBps > 0 el contrato compara AMM vs oraculo,
// que acredita el out real del AMM si pasa la validacion y que revierte ante desvio alto.
// Tambien comprobamos que cuando oracleDevBps = 0 se usa la ruta directa sin oraculo.

contract KipuBankV3OracleTest is Test {
    // Actores
    address internal admin = address(0xA11CE);
    address internal pauser = address(0xBEEF);
    address internal user = address(0xCAFE);

    // Direcciones unificadas (select-env.sh)
    address internal router;
    address internal weth;
    address internal usdc;
    address internal oracle;

    // Parametros comunes
    uint256 internal constant SLIPPAGE_BPS = 100; // 1%
    uint256 internal bankCap = 1_000_000e6;
    uint256 internal withdrawCap = 100_000e6;
    uint256 internal oracleMaxDelay;
    bool internal skipOracleTests;

    function setUp() public {
        // Crear fork para que el router/oraculo existan en la EVM de prueba
        string memory rpc;
        try vm.envString("FORK_RPC_URL") returns (string memory frpc) {
            rpc = frpc;
        } catch {
            rpc = vm.envString("SEPOLIA_RPC_URL");
        }
        try vm.envUint("FORK_BLOCK") returns (uint256 fb) {
            if (fb > 0) {
                vm.createSelectFork(rpc, fb);
            } else {
                vm.createSelectFork(rpc);
            }
        } catch {
            vm.createSelectFork(rpc);
        }

        // Etiquetas para logs, lectura de variables y fondos basicos al usuario
        vm.label(admin, "ADMIN");
        vm.label(pauser, "PAUSER");
        vm.label(user, "USER");

        router = vm.envAddress("V2_ROUTER");
        weth = vm.envAddress("WETH");
        usdc = vm.envAddress("USDC");
        oracle = vm.envAddress("ETH_ORACLE");
        oracleMaxDelay = vm.envUint("ORACLE_MAX_DELAY");

        // Si ORACLE_DEV_BPS == 0, evitamos tests que obligan a oraculo (se auto-saltan)
        skipOracleTests = false;
        try vm.envUint("ORACLE_DEV_BPS") returns (uint256 bps) {
            if (bps == 0) skipOracleTests = true;
        } catch {}

        vm.label(router, "UNI-V2-ROUTER");
        vm.label(weth, "WETH");
        vm.label(usdc, "USDC");
        vm.label(oracle, "ETH_ORACLE");

        // dar ETH al usuario para depositar
        vm.deal(user, 100 ether);
    }

    function _deploy(uint256 oracleDevBps) internal returns (KipuBankV3 bank) {
        vm.prank(admin);
        bank = new KipuBankV3(
            admin,
            pauser,
            router,
            usdc,
            bankCap,
            withdrawCap,
            SLIPPAGE_BPS,
            oracle,
            oracleMaxDelay,
            oracleDevBps
        );
        vm.label(address(bank), "KIPU-BANK-V3");
    }

    // --- Deposito ETH con oraculo OK (tolerancia amplia para no depender del mercado) ---
    function test_eth_con_oraculo_ok_tolerancia_alta() public {
        if (skipOracleTests) return;
        uint256 amountIn = 0.2 ether;
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = usdc;
        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];

        // Calcular desviación vs oráculo (sin mocks)
        AggregatorV3Interface agg = AggregatorV3Interface(oracle);
        (, int256 answer, , , ) = agg.latestRoundData();
        require(answer > 0, "precio oraculo <= 0");
        uint8 od = agg.decimals();
        uint256 oraclePriceUSDC6 = (uint256(answer) * 1e6) / (10 ** od);
        uint256 oracleOut = (amountIn * oraclePriceUSDC6) / 1e18;
        if (oracleOut == 0) return;
        uint256 diff = realOut > oracleOut ? realOut - oracleOut : oracleOut - realOut;
        uint256 bps = (diff * 10_000) / oracleOut;
        if (bps > 10_000) return; // no es posible aprobar con el maximo permitido

        // Desplegar con tolerancia por encima de la desviación medida (pequeño buffer para redondeos)
        uint256 tolOk = bps + 50; // +0.50%
        if (tolOk > 10_000) tolOk = 10_000;
        KipuBankV3 bank = _deploy(tolOk);

        vm.prank(user);
        bank.depositar{value: amountIn}(address(0), 0);
        assertEq(bank.saldoUSDCDe(user), realOut, "credito usdc tras deposito con oraculo");
    }

    // --- Fallback: si el oráculo revierte, se usa ruta directa y el depósito debe pasar ---
    function test_eth_oraculo_fallback_por_revert() public {
        KipuBankV3 bank = _deploy(1000);

        uint256 amountIn = 0.2 ether;
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = usdc;
        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];

        // Forzar fallback por oráculo stale avanzando el tiempo mas alla de oracleMaxDelay
        vm.warp(block.timestamp + oracleMaxDelay + 1);

        vm.prank(user);
        bank.depositar{value: amountIn}(address(0), 0);
        assertEq(bank.saldoUSDCDe(user), realOut, "credito via fallback directo");
    }

    // --- Deposito ETH con oraculo deshabilitado: se usa ruta directa y no revierte ---
    function test_eth_sin_oraculo_ok() public {
        KipuBankV3 bank = _deploy(0);
        uint256 amountIn = 0.1 ether;
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = usdc;
        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];

        vm.prank(user);
        // Con oracleDevBps=0, depositar(address(0),0) usa la ruta directa (sin oraculo)
        bank.depositar{value: amountIn}(address(0), 0);
        assertEq(bank.saldoUSDCDe(user), realOut, "credito usdc via ruta directa sin oraculo");
    }

    // --- Deposito ETH con oraculo: desviacion excesiva provoca revert ---
    function test_eth_con_oraculo_revert_por_desviacion() public {
        if (skipOracleTests) return;
        uint256 amountIn = 0.2 ether;
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = usdc;

        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        AggregatorV3Interface agg = AggregatorV3Interface(oracle);
        (, int256 answer, , , ) = agg.latestRoundData();
        require(answer > 0, "precio oraculo <= 0");
        uint8 od = agg.decimals();
        uint256 oraclePriceUSDC6 = (uint256(answer) * 1e6) / (10 ** od);
        uint256 oracleOut = (amountIn * oraclePriceUSDC6) / 1e18;
        if (oracleOut == 0) return;
        uint256 diff = realOut > oracleOut ? realOut - oracleOut : oracleOut - realOut;
        uint256 bps = (diff * 10_000) / oracleOut;
        if (bps == 0) return; // nada que forzar

        // Desplegar con tolerancia por debajo de la desviación medida para forzar revert
        uint256 tol = bps > 0 ? bps - 1 : 0;
        if (tol == 0) return;
        if (tol > 10_000) tol = 10_000;
        KipuBankV3 bank = _deploy(tol);

        vm.expectRevert();
        vm.prank(user);
        bank.depositar{value: amountIn}(address(0), 0);
    }

    // --- Gas: comparar depositos con y sin oraculo ---
    function test_gas_eth_sin_vs_con_oraculo() public {
        if (skipOracleTests) return;
        uint256 amountIn = 0.15 ether;
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = usdc;
        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        AggregatorV3Interface agg = AggregatorV3Interface(oracle);
        (, int256 answer, , , ) = agg.latestRoundData();
        require(answer > 0, "precio oraculo <= 0");
        uint8 od = agg.decimals();
        uint256 oraclePriceUSDC6 = (uint256(answer) * 1e6) / (10 ** od);
        uint256 oracleOut = (amountIn * oraclePriceUSDC6) / 1e18;
        if (oracleOut == 0) return;
        uint256 diff = realOut > oracleOut ? realOut - oracleOut : oracleOut - realOut;
        uint256 bps = (diff * 10_000) / oracleOut;
        if (bps > 10_000) return; // con oráculo revertiría

        KipuBankV3 bankNoOracle = _deploy(0);
        uint256 tolOk = bps + 50; // +0.50% de margen para redondeos/variaciones mínimas
        if (tolOk > 10_000) tolOk = 10_000;
        KipuBankV3 bankWithOracle = _deploy(tolOk);

        vm.prank(user);
        bankNoOracle.depositar{value: amountIn}(address(0), 0);
        vm.prank(user);
        bankWithOracle.depositar{value: amountIn}(address(0), 0);

        assertGt(bankNoOracle.saldoUSDCDe(user), 0, "sin oraculo ok");
        assertGt(bankWithOracle.saldoUSDCDe(user), 0, "con oraculo ok");
    }
}
