// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {KipuBankV3} from "src/KipuBankV3.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

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
        vm.label(admin, "ADMIN");
        vm.label(pauser, "PAUSER");
        vm.label(user, "USER");

        router = vm.envAddress("V2_ROUTER");
        weth = vm.envAddress("WETH");
        usdc = vm.envAddress("USDC");
        oracle = vm.envAddress("ETH_ORACLE");
        oracleMaxDelay = vm.envUint("ORACLE_MAX_DELAY");

        // Si ORACLE_DEV_BPS == 0, evitamos correr estos tests (por configuracion deshabilitada)
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
        // tolerancia 100% para no depender del gap real de la red
        KipuBankV3 bank = _deploy(10_000);

        uint256 amountIn = 0.2 ether;
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = usdc;
        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];

        vm.prank(user);
        bank.depositarEthConOraculo{value: amountIn}();

        // el credito real debe coincidir con el out real del AMM para ese monto
        assertEq(bank.saldoUSDCDe(user), realOut, "credito usdc tras deposito con oraculo");
    }

    // --- Deposito ETH con oraculo deshabilitado (oracleDevBps=0) debe revertir ---
    function test_eth_con_oraculo_revert_no_configurado() public {
        if (skipOracleTests) return;
        KipuBankV3 bank = _deploy(0);
        vm.expectRevert(abi.encodeWithSignature("OraculoNoConfigurado()"));
        vm.prank(user);
        bank.depositarEthConOraculo{value: 0.1 ether}();
    }

    // --- Deposito ETH con oraculo: desviacion excesiva provoca revert ---
    function test_eth_con_oraculo_revert_por_desviacion() public {
        if (skipOracleTests) return;
        // tolerancia 1% y forzamos un expectedOut artificialmente inflado
        KipuBankV3 bank = _deploy(100);

        uint256 amountIn = 0.2 ether;
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = usdc;

        // obtener out real y luego inflarlo +50%
        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 inflated = (realOut * 150) / 100;
        uint256[] memory fake = new uint256[](2);
        fake[0] = amountIn;
        fake[1] = inflated;

        // mockear getAmountsOut para que el banco calcule expectedOut inflado y falle contra el oraculo
        vm.mockCall(
            router,
            abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, amountIn, path),
            abi.encode(fake)
        );

        vm.expectRevert(); // DesviacionOraculoExcesiva
        vm.prank(user);
        bank.depositarEthConOraculo{value: amountIn}();

        vm.clearMockedCalls();
    }

    // --- Gas: comparar depositos con y sin oraculo ---
    function test_gas_eth_sin_vs_con_oraculo() public {
        if (skipOracleTests) return;
        // despliegues: sin oraculo y con oraculo (tolerancia amplia para no fallar)
        KipuBankV3 bankNoOracle = _deploy(0);
        KipuBankV3 bankWithOracle = _deploy(10_000);

        uint256 amountIn = 0.15 ether;

        // sin oraculo (ruta por defecto via depositar ETH)
        vm.prank(user);
        bankNoOracle.depositar{value: amountIn}(address(0), 0);

        // con oraculo (ruta especial)
        vm.prank(user);
        bankWithOracle.depositarEthConOraculo{value: amountIn}();

        // Para comparar gas, usar: forge test --gas-report -m test_gas_eth_sin_vs_con_oraculo
        assertGt(bankNoOracle.saldoUSDCDe(user), 0, "sin oraculo ok");
        assertGt(bankWithOracle.saldoUSDCDe(user), 0, "con oraculo ok");
    }
}
