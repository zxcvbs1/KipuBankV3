// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {KipuBankV3} from "src/KipuBankV3.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

// Suite principal de pruebas para KipuBankV3.
// Aqui documento en mis palabras que hace cada test:
// - Constructor: valida parametros, decimales y slippage.
// - Vistas: tokenAceptado.
// - Depositos: USDC directo, ERC20 con par directo (swap), ETH y receive.
// - Slippage: casos fuera y dentro de margen para ERC20 y ETH.
// - Cap: prechequeo y credito final.
// - Retiros: withdraw cap y casos borde.
// - Pausa y roles: permisos y efectos.

contract KipuBankV3Test is Test {
    // configuracion por defecto para pruebas
    uint256 internal constant SLIPPAGE_BPS = 100;      // 1%
    uint256 internal constant ORACLE_DEV_BPS = 10;      // 0 = deshabilita comparacion con oraculo
    // actores: definimos admin, pauser y un usuario para probar flujos
    address internal admin = address(0xA11CE);
    address internal pauser = address(0xBEEF);
    address internal user = address(0xCAFE);

    // tokens (leidos de .env en modo anvil sepolia)
    // usdc es el token contable con 6 decimales
    // pairToken es un token con par directo a usdc (por ejemplo LINK)
    IERC20 internal usdc; // USDC (6 dec)
    IERC20 internal pairToken; // token con par directo a USDC (p.ej. LINK)

    // direcciones uniswap v2 leidas de .env
    address internal router;   // direccion del router uniswap v2
    address internal wethAddr; // direccion de WETH (contrato canonical conocido como WETH9)

    // sistema bajo prueba
    KipuBankV3 internal bank;

    // topes
    uint256 internal bankCap = 1_000_000e6;   // 1M USDC
    uint256 internal withdrawCap = 100_000e6; // 100k USDC

    function setUp() public {
        // Crear fork de la red definida para que existan router/tokens/oraculo reales
        string memory rpc;
        try vm.envString("FORK_RPC_URL") returns (string memory frpc) {
            rpc = frpc;
        } catch {
            rpc = vm.envString("SEPOLIA_RPC_URL");
        }
        // Si se definió un bloque para el fork, usarlo; si no, forkeamos al tip
        try vm.envUint("FORK_BLOCK") returns (uint256 fb) {
            if (fb > 0) {
                vm.createSelectFork(rpc, fb);
            } else {
                vm.createSelectFork(rpc);
            }
        } catch {
            vm.createSelectFork(rpc);
        }

        // etiquetas para que los logs se lean mejor
        vm.label(admin, "ADMIN");
        vm.label(pauser, "PAUSER");
        vm.label(user, "USER");

        // leer direcciones desde .env (usamos anvil como fork externo)
        router   = vm.envAddress("V2_ROUTER");
        wethAddr = vm.envAddress("WETH");
        address usdcAddr  = vm.envAddress("USDC");
        address pairAddr  = vm.envAddress("PAIR_TOKEN");

        // instancias de interfaces
        usdc = IERC20(usdcAddr);
        pairToken = IERC20(pairAddr);

        vm.label(usdcAddr, "USDC");
        vm.label(wethAddr, "WETH");
        vm.label(pairAddr, "PAIR_TOKEN");
        vm.label(router, "UNI-V2-ROUTER");

        // balances iniciales para el usuario: damos usdc, pairToken y eth
        deal(usdcAddr, user, 200_000e6);
        deal(pairAddr, user, 50_000 ether);
        vm.deal(user, 100 ether);

        // desplegar banco con slippage y desviacion oraculo definidos por constantes
        address ethOracle = vm.envAddress("ETH_ORACLE");
        uint256 oracleMaxDelay = vm.envUint("ORACLE_MAX_DELAY");
        // En esta suite enfocada a logica general, deshabilitamos el oráculo (ruta directa para ETH)
        uint256 oracleDevBps = 0;
        vm.prank(admin);
        bank = new KipuBankV3(
            admin,
            pauser,
            router,
            usdcAddr,
            bankCap,
            withdrawCap,
            SLIPPAGE_BPS,
            ethOracle,
            oracleMaxDelay,
            oracleDevBps
        );
        vm.label(address(bank), "KIPU-BANK-V3");
    }

    // ------------------ constructor ------------------
    // Constructor: valida que parametros invalidos revienten (direcciones y caps)
    function test_constructor_parametros_invalidos() public {
        vm.expectRevert(abi.encodeWithSignature("DireccionInvalida()"));
        new KipuBankV3(address(0), pauser, address(router), address(usdc), bankCap, withdrawCap, 0, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);

        vm.expectRevert(abi.encodeWithSignature("DireccionInvalida()"));
        new KipuBankV3(admin, address(0), address(router), address(usdc), bankCap, withdrawCap, 0, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);

        vm.expectRevert(abi.encodeWithSignature("DireccionInvalida()"));
        new KipuBankV3(admin, pauser, address(0), address(usdc), bankCap, withdrawCap, 0, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);

        vm.expectRevert(abi.encodeWithSignature("DireccionInvalida()"));
        new KipuBankV3(admin, pauser, address(router), address(0), bankCap, withdrawCap, 0, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);

        // caps invalidos
        vm.expectRevert(abi.encodeWithSignature("ParametrosNumericosInvalidos()"));
        new KipuBankV3(admin, pauser, address(router), address(usdc), 0, withdrawCap, 0, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);

        vm.expectRevert(abi.encodeWithSignature("ParametrosNumericosInvalidos()"));
        new KipuBankV3(admin, pauser, address(router), address(usdc), bankCap, 0, 0, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);

        vm.expectRevert(abi.encodeWithSignature("ParametrosNumericosInvalidos()"));
        new KipuBankV3(admin, pauser, address(router), address(usdc), 100e6, 200e6, 0, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
    }

    // Constructor: rechaza USDC con 18 decimales
    function test_constructor_decimales_usdc_invalidos() public {
        // usdc con 18 decimales debe revertir
        MockERC20 usdc18 = new MockERC20("FakeUSDC", "FUSDC", 18);
        vm.expectRevert(abi.encodeWithSignature("UsdcDecimalesInvalido(uint8)", 18));
        new KipuBankV3(admin, pauser, address(router), address(usdc18), bankCap, withdrawCap, 0, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
    }

    // Constructor: rechaza slippageBps por encima del maximo permitido
    function test_constructor_slippage_excesivo() public {
        vm.expectRevert(abi.encodeWithSignature("SlippageExcesivo(uint256)", 5000));
        new KipuBankV3(admin, pauser, address(router), address(usdc), bankCap, withdrawCap, 5001, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
    }

    // ------------------ vistas ------------------
    // Vistas: tokenAceptado debe ser true para nativo/USDC y para un token con par directo
    function test_token_aceptado() public {
        // nativo y usdc aceptados
        assertTrue(bank.tokenAceptado(address(0)));
        assertTrue(bank.tokenAceptado(address(usdc)));
        // par directo aceptado
        assertTrue(bank.tokenAceptado(wethAddr));
        // token sin par no aceptado (desde .env)
        address notPair = vm.envAddress("NOT_PAIR_TOKEN");
        assertFalse(bank.tokenAceptado(notPair));
    }

    // ------------------ depositar ------------------
    // Deposito USDC directo: acredita el mismo monto y actualiza total
    function test_depositar_usdc_directo() public {
        // caso feliz: deposito directo en usdc
        uint256 amount = 10_000e6; // 10k usdc
        vm.startPrank(user);
        usdc.approve(address(bank), type(uint256).max);
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.Depositado(user, address(usdc), amount, amount, amount);
        bank.depositar(address(usdc), amount);
        vm.stopPrank();

        assertEq(bank.saldoUSDCDe(user), amount, "saldo usuario usdc");
        assertEq(bank.totalValueUSD6Raw(), amount, "tv usd6");
        (uint64 dep, uint64 ret) = bank.contadoresDeUsuario(user);
        assertEq(dep, 1, "contador depositos");
        assertEq(ret, 0, "contador retiros");
    }

    // Deposito de ERC20 con par directo: hace swap a USDC y acredita el out
    function test_depositar_erc20_con_par_swapea_a_usdc() public {
        // caso feliz: deposito de un erc20 con par directo a usdc (pairToken)
        uint256 amountIn = 1_000 ether; // pairToken
        address[] memory path = new address[](2);
        path[0] = address(pairToken);
        path[1] = address(usdc);
        uint256 quotedOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];

        vm.startPrank(user);
        pairToken.approve(address(bank), type(uint256).max);
        vm.expectEmit(true, true, true, true);
        // swapeado
        emit KipuBankV3.Swapeado(user, address(pairToken), amountIn, quotedOut);
        vm.expectEmit(true, true, true, true);
        // depositado
        emit KipuBankV3.Depositado(user, address(usdc), quotedOut, quotedOut, quotedOut);
        bank.depositar(address(pairToken), amountIn);
        vm.stopPrank();

        assertEq(bank.saldoUSDCDe(user), quotedOut, "credito post swap usdc");
        assertEq(bank.totalValueUSD6Raw(), quotedOut, "tv usd6 actualizada");
    }

    // Deposito ETH: swapea via [WETH, USDC] y acredita out real
    function test_depositar_eth_swapea_a_usdc() public {
        // caso feliz: deposito de eth, swapea via path [weth, usdc]
        uint256 amountIn = 5 ether;
        address[] memory path = new address[](2);
        path[0] = wethAddr;
        path[1] = address(usdc);
        uint256 quotedOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];

        vm.prank(user);
        bank.depositar{value: amountIn}(address(0), 0);

        assertEq(bank.saldoUSDCDe(user), quotedOut, "acreditado tras swap eth");
    }

    // Receive: envio de ETH directo debe swappear a USDC y acreditar
    function test_depositar_recibe_eth_via_receive() public {
        // envio directo de eth al contrato (receive), debe swappear a usdc
        uint256 amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = wethAddr;
        path[1] = address(usdc);
        uint256 quotedOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];

        vm.prank(user);
        (bool ok, ) = address(bank).call{value: amountIn}("");
        require(ok, "enviar eth");
        assertEq(bank.saldoUSDCDe(user), quotedOut, "acreditado via receive");
    }

    // ------------------ slippage ------------------
    // Slippage ERC20 fuera de margen: inflamos quote para que minOut supere out real y revierta
    function test_slippage_erc20_fuera_margen_revert() public {
        // idea: inflar artificialmente el quote para que minOut quede por encima del out real
        // y Uniswap revierta por INSUFFICIENT_OUTPUT_AMOUNT (fuera del margen de slippage del banco)
        uint256 amountIn = 200 ether;
        address[] memory path = new address[](2);
        path[0] = address(pairToken);
        path[1] = address(usdc);

        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 inflated = (realOut * 102) / 100; // +2%
        // devolveremos [amountIn, inflated] en getAmountsOut para elevar minOut
        uint256[] memory fake = new uint256[](2);
        fake[0] = amountIn;
        fake[1] = inflated;

        // mockear la cotizacion
        vm.mockCall(
            router,
            abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, amountIn, path),
            abi.encode(fake)
        );

        vm.startPrank(user);
        pairToken.approve(address(bank), type(uint256).max);
        vm.expectRevert(); // revert del router por amountOutMin demasiado alto
        bank.depositar(address(pairToken), amountIn);
        vm.stopPrank();

        vm.clearMockedCalls();
    }

    // Slippage ERC20 dentro de margen: deflamos quote para que el swap pase y acredite out real
    function test_slippage_erc20_dentro_margen_ok() public {
        // idea: deflamos el quote (minOut mas bajo) para que el swap pase dentro del margen
        uint256 amountIn = 200 ether;
        address[] memory path = new address[](2);
        path[0] = address(pairToken);
        path[1] = address(usdc);

        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 deflated = (realOut * 99) / 100; // -1%
        uint256[] memory fake = new uint256[](2);
        fake[0] = amountIn;
        fake[1] = deflated;

        vm.mockCall(
            router,
            abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, amountIn, path),
            abi.encode(fake)
        );

        vm.startPrank(user);
        pairToken.approve(address(bank), type(uint256).max);
        bank.depositar(address(pairToken), amountIn);
        vm.stopPrank();

        // el credito final debe ser el out real del router (no el fake)
        assertEq(bank.saldoUSDCDe(user), realOut, "slippage dentro margen: credito usdc real");

        vm.clearMockedCalls();
    }

    // Slippage ETH fuera de margen: inflamos quote y debe revertir
    function test_slippage_eth_fuera_margen_revert() public {
        uint256 amountIn = 2 ether;
        address[] memory path = new address[](2);
        path[0] = wethAddr;
        path[1] = address(usdc);
        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 inflated = (realOut * 102) / 100;

        uint256[] memory fake = new uint256[](2);
        fake[0] = amountIn;
        fake[1] = inflated;

        vm.mockCall(
            router,
            abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, amountIn, path),
            abi.encode(fake)
        );

        vm.expectRevert();
        vm.prank(user);
        bank.depositar{value: amountIn}(address(0), 0);

        vm.clearMockedCalls();
    }

    // Slippage ETH dentro de margen: deflamos quote y debe pasar
    function test_slippage_eth_dentro_margen_ok() public {
        uint256 amountIn = 2 ether;
        address[] memory path = new address[](2);
        path[0] = wethAddr;
        path[1] = address(usdc);
        uint256 realOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 deflated = (realOut * 99) / 100;
        uint256[] memory fake = new uint256[](2);
        fake[0] = amountIn;
        fake[1] = deflated;
        vm.mockCall(
            router,
            abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, amountIn, path),
            abi.encode(fake)
        );

        vm.prank(user);
        bank.depositar{value: amountIn}(address(0), 0);
        assertEq(bank.saldoUSDCDe(user), realOut, "slippage dentro margen eth: credito usdc real");

        vm.clearMockedCalls();
    }

    // ETH: bank cap - prechequeo (minOut) excede cap -> revierte
    function test_depositar_eth_cap_precheck_revert() public {
        uint256 amountIn = 0.2 ether;
        address[] memory path = new address[](2);
        path[0] = wethAddr; path[1] = address(usdc);
        uint256 expectedOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 minOut = (expectedOut * (10_000 - SLIPPAGE_BPS)) / 10_000;

        // cap más chico que minOut para forzar revert en prechequeo
        uint256 tinyCap = minOut > 0 ? (minOut - 1) : 0;
        vm.startPrank(admin);
        bank = new KipuBankV3(admin, pauser, router, address(usdc), tinyCap, tinyCap, SLIPPAGE_BPS, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(user);
        bank.depositar{value: amountIn}(address(0), 0);
    }

    // ETH: bank cap - prechequeo pasa pero cierre excede cap -> revierte
    function test_depositar_eth_revert_cap_en_cierre() public {
        uint256 amountIn = 0.25 ether;
        address[] memory path = new address[](2);
        path[0] = wethAddr; path[1] = address(usdc);
        uint256 expectedOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 minOut = (expectedOut * (10_000 - SLIPPAGE_BPS)) / 10_000;

        // cap entre minOut y expectedOut
        uint256 capBetween = minOut + (expectedOut - minOut) / 2;
        if (capBetween <= minOut) capBetween = minOut + 1; // asegurar > minOut

        vm.startPrank(admin);
        bank = new KipuBankV3(admin, pauser, router, address(usdc), capBetween, capBetween, SLIPPAGE_BPS, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(user);
        bank.depositar{value: amountIn}(address(0), 0);
    }

    // ERC20: bank cap - prechequeo (minOut) excede cap -> revierte
    function test_depositar_erc20_cap_precheck_revert() public {
        uint256 amountIn = 500 ether;
        address[] memory path = new address[](2);
        path[0] = address(pairToken); path[1] = address(usdc);
        uint256 expectedOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 minOut = (expectedOut * (10_000 - SLIPPAGE_BPS)) / 10_000;

        uint256 tinyCap = minOut > 0 ? (minOut - 1) : 0;
        vm.startPrank(admin);
        bank = new KipuBankV3(admin, pauser, router, address(usdc), tinyCap, tinyCap, SLIPPAGE_BPS, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
        vm.stopPrank();

        vm.startPrank(user);
        pairToken.approve(address(bank), type(uint256).max);
        vm.expectRevert();
        bank.depositar(address(pairToken), amountIn);
        vm.stopPrank();
    }

    // ERC20: bank cap - prechequeo pasa pero cierre excede cap (sin mocks) -> revierte
    function test_depositar_erc20_revert_cap_en_cierre_sin_mocks() public {
        uint256 amountIn = 300 ether;
        address[] memory path = new address[](2);
        path[0] = address(pairToken); path[1] = address(usdc);
        uint256 expectedOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 minOut = (expectedOut * (10_000 - SLIPPAGE_BPS)) / 10_000;

        uint256 capBetween = minOut + (expectedOut - minOut) / 2;
        if (capBetween <= minOut) capBetween = minOut + 1;

        vm.startPrank(admin);
        bank = new KipuBankV3(admin, pauser, router, address(usdc), capBetween, capBetween, SLIPPAGE_BPS, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
        vm.stopPrank();

        vm.startPrank(user);
        pairToken.approve(address(bank), type(uint256).max);
        vm.expectRevert();
        bank.depositar(address(pairToken), amountIn);
        vm.stopPrank();
    }

    // Slippage ERC20: custom revert cuando swap devuelve menos que minOut (mockeado)
    function test_slippage_erc20_custom_revert_por_minout() public {
        uint256 amountIn = 100 ether;
        address[] memory path = new address[](2);
        path[0] = address(pairToken);
        path[1] = address(usdc);

        // 1) Cotización esperada y minOut segun banco
        uint256 expectedOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 minOut = (expectedOut * (10_000 - SLIPPAGE_BPS)) / 10_000;

        // 2) Mockear getAmountsOut para devolver expectedOut (consistente con cálculo de minOut)
        uint256[] memory quote = new uint256[](2);
        quote[0] = amountIn; quote[1] = expectedOut;
        vm.mockCall(
            router,
            abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, amountIn, path),
            abi.encode(quote)
        );

        // 3) Mockear swapExactTokensForTokens para devolver menos que minOut (no revert de Uniswap)
        uint256 outLess = minOut - 1;
        uint256[] memory swapOuts = new uint256[](2);
        swapOuts[0] = amountIn; swapOuts[1] = outLess;
        vm.mockCall(
            router,
            IUniswapV2Router02.swapExactTokensForTokens.selector,
            abi.encode(swapOuts)
        );

        vm.startPrank(user);
        pairToken.approve(address(bank), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("SlippageInsuficiente(uint256,uint256)", minOut, outLess));
        bank.depositar(address(pairToken), amountIn);
        vm.stopPrank();

        vm.clearMockedCalls();
    }

    // Slippage ETH: custom revert cuando swap devuelve menos que minOut (mockeado, sin oráculo)
    function test_slippage_eth_custom_revert_por_minout() public {
        // re desplegar banco con oracle desactivado para usar ruta directa
        vm.startPrank(admin);
        bank = new KipuBankV3(admin, pauser, router, address(usdc), bankCap, withdrawCap, SLIPPAGE_BPS, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
        vm.stopPrank();

        uint256 amountIn = 1 ether;
        address[] memory path = new address[](2);
        path[0] = wethAddr; path[1] = address(usdc);

        uint256 expectedOut = IUniswapV2Router02(router).getAmountsOut(amountIn, path)[1];
        uint256 minOut = (expectedOut * (10_000 - SLIPPAGE_BPS)) / 10_000;

        // Mockear getAmountsOut
        uint256[] memory quote = new uint256[](2);
        quote[0] = amountIn; quote[1] = expectedOut;
        vm.mockCall(
            router,
            abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, amountIn, path),
            abi.encode(quote)
        );

        // Mockear swapExactETHForTokens con menos que minOut
        uint256 outLess = minOut - 1;
        uint256[] memory swapOuts = new uint256[](2);
        swapOuts[0] = amountIn; swapOuts[1] = outLess;
        vm.mockCall(
            router,
            amountIn,
            IUniswapV2Router02.swapExactETHForTokens.selector,
            abi.encode(swapOuts)
        );

        vm.expectRevert(abi.encodeWithSignature("SlippageInsuficiente(uint256,uint256)", minOut, outLess));
        vm.prank(user);
        bank.depositar{value: amountIn}(address(0), 0);

        vm.clearMockedCalls();
    }

    // ETH: par inexistente en factory debe revertir
    function test_depositar_eth_revert_pair_inexistente() public {
        address factory = IUniswapV2Router02(router).factory();
        // mock getPair(WETH, USDC) -> address(0)
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IUniswapV2Factory.getPair.selector, wethAddr, address(usdc)),
            abi.encode(address(0))
        );
        vm.expectRevert(abi.encodeWithSignature("PairInexistente(address,address)", wethAddr, address(usdc)));
        vm.prank(user);
        bank.depositar{value: 0.5 ether}(address(0), 0);
        vm.clearMockedCalls();
    }

    // ERC20: precheck pasa pero cierre de cap excede con out real (mockeado)
    function test_depositar_erc20_revert_cap_en_cierre() public {
        // banco con cap chico pero suficiente para minOut, no para out real
        vm.startPrank(admin);
        bank = new KipuBankV3(admin, pauser, router, address(usdc), 200e6, 200e6, SLIPPAGE_BPS, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
        vm.stopPrank();

        uint256 amountIn = 100 ether;
        address[] memory path = new address[](2);
        path[0] = address(pairToken); path[1] = address(usdc);

        // Definir expected y minOut bajos (minOut=150e6), pero simular swap con outUSDC=210e6
        uint256 expectedOut = 160e6;
        uint256 minOut = (expectedOut * (10_000 - SLIPPAGE_BPS)) / 10_000; // ~158.4e6
        // Mock getAmountsOut
        uint256[] memory quote = new uint256[](2);
        quote[0] = amountIn; quote[1] = expectedOut;
        vm.mockCall(
            router,
            abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, amountIn, path),
            abi.encode(quote)
        );
        // Mock swap con out mayor al cap disponible (210e6)
        uint256 outUSDC = 210e6;
        uint256[] memory swapOuts = new uint256[](2);
        swapOuts[0] = amountIn; swapOuts[1] = outUSDC;
        vm.mockCall(
            router,
            IUniswapV2Router02.swapExactTokensForTokens.selector,
            abi.encode(swapOuts)
        );

        vm.startPrank(user);
        pairToken.approve(address(bank), type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("ExcedeTopeBancoUSD(uint256,uint256)", outUSDC, 200e6));
        bank.depositar(address(pairToken), amountIn);
        vm.stopPrank();

        vm.clearMockedCalls();
    }

    // Receive: enviar 0 debe revertir por MontoCero
    function test_receive_eth_monto_cero_revert() public {
        vm.expectRevert(abi.encodeWithSignature("MontoCero()"));
        (bool ok, ) = address(bank).call("");
        ok; // silence warnings
    }

    // Vistas y contadores extra: capacidadDisponible y retiro incrementa contadores
    function test_vistas_capacidad_y_contadores() public {
        uint256 cap = bank.bankCapUSD6Raw();
        assertEq(bank.capacidadDisponibleUSD(), cap, "capacidad inicial igual al cap");

        // depositar 1 USDC
        vm.startPrank(user);
        usdc.approve(address(bank), type(uint256).max);
        bank.depositar(address(usdc), 1e6);
        vm.stopPrank();

        assertEq(bank.capacidadDisponibleUSD(), cap - 1e6, "capacidad post deposito");

        // retirar 1 USDC
        vm.prank(user);
        bank.retirar(address(usdc), 1e6);

        (uint64 d, uint64 r) = bank.contadoresDeUsuario(user);
        assertEq(d, 1, "depositos=1");
        assertEq(r, 1, "retiros=1");
    }

    // Deposito de token sin par directo: debe revertir con PairInexistente
    function test_depositar_revertir_sin_par_directo() public {
        // usar NOT_PAIR_TOKEN desde .env, no requiere balance/approve porque revierte antes del pull
        address notPair = vm.envAddress("NOT_PAIR_TOKEN");
        vm.expectRevert(abi.encodeWithSignature("PairInexistente(address,address)", notPair, address(usdc)));
        bank.depositar(notPair, 100 ether);
    }

    // Parametros invalidos para ETH: amount != 0 o msg.value == 0
    function test_depositar_parametros_invalidos_eth() public {
        // amount != 0 o msg.value == 0 deben revertir
        vm.expectRevert(abi.encodeWithSignature("ParametrosEthInvalidos()"));
        bank.depositar(address(0), 1);
        vm.expectRevert(abi.encodeWithSignature("ParametrosEthInvalidos()"));
        bank.depositar{value: 0}(address(0), 0);
    }

    // Parametros invalidos para ERC20: msg.value != 0 o amount == 0
    function test_depositar_parametros_invalidos_erc20() public {
        vm.expectRevert(abi.encodeWithSignature("ParametrosErc20Invalidos()"));
        bank.depositar{value: 1}(address(usdc), 100);
        vm.expectRevert(abi.encodeWithSignature("ParametrosErc20Invalidos()"));
        bank.depositar(address(usdc), 0);
    }

    // Bank cap: prechequeo con quote evita exceder cap y credito final actualiza total
    function test_bank_cap_precheck_y_credito() public {
        // re desplegar banco con tope chico 100 usdc
        vm.startPrank(admin);
        bank = new KipuBankV3(admin, pauser, router, address(usdc), 100e6, 100e6, 0, vm.envAddress("ETH_ORACLE"), vm.envUint("ORACLE_MAX_DELAY"), 0);
        vm.stopPrank();

        // deposito directo en USDC excediendo tope debe revertir
        vm.startPrank(user);
        usdc.approve(address(bank), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KipuBankV3.ExcedeTopeBancoUSD.selector, 200e6, 100e6));
        bank.depositar(address(usdc), 200e6);
        vm.stopPrank();

        // deposito dentro del tope funciona
        vm.startPrank(user);
        bank.depositar(address(usdc), 80e6);
        vm.stopPrank();
        assertEq(bank.totalValueUSD6Raw(), 80e6, "tv despues del primer deposito");

        // deposito de token con quote que excede los 20 USDC restantes debe revertir en prechequeo
        address[] memory path = new address[](2);
        path[0] = address(pairToken);
        path[1] = address(usdc);
        uint256 needToExceed = 1_000_000 ether;
        uint256 quoted = IUniswapV2Router02(router).getAmountsOut(needToExceed, path)[1];
        assertGt(quoted, 20e6);

        vm.startPrank(user);
        pairToken.approve(address(bank), type(uint256).max);
        uint256 proposed = 80e6 + quoted;
        vm.expectRevert(abi.encodeWithSelector(KipuBankV3.ExcedeTopeBancoUSD.selector, proposed, 100e6));
        bank.depositar(address(pairToken), needToExceed);
        vm.stopPrank();
    }

    // ------------------ retirar ------------------
    // Retirar respeta withdraw cap: dentro del tope ok y excediendo revierte
    function test_retirar_respeta_withdraw_cap() public {
        // depositar primero
        vm.startPrank(user);
        usdc.approve(address(bank), type(uint256).max);
        // asegurar balance y allowance suficientes
        deal(address(usdc), user, 1_000_000e6);
        bank.depositar(address(usdc), 300_000e6);
        vm.stopPrank();

        // retiro dentro del tope ok
        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit KipuBankV3.Retirado(user, address(usdc), 50_000e6, 250_000e6, 50_000e6);
        bank.retirar(address(usdc), 50_000e6);
        assertEq(bank.saldoUSDCDe(user), 250_000e6, "despues de retirar");

        // retiro excediendo el tope por transaccion debe revertir
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(KipuBankV3.ExcedeTopeRetiroUSD.selector, 200_000e6, 100_000e6));
        bank.retirar(address(usdc), 200_000e6);
    }

    // Retirar: token invalido, monto cero y saldo insuficiente
    function test_retirar_token_invalido_y_casos_borde() public {
        // token invalido
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("DireccionInvalida()"));
        bank.retirar(address(0xBEEF), 1);

        // monto cero
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("MontoCero()"));
        bank.retirar(address(usdc), 0);

        // saldo insuficiente
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("SaldoInsuficiente(uint256,uint256)", 0, 1e6));
        bank.retirar(address(usdc), 1e6);
    }

    // ------------------ pausa ------------------
    // Pausa: solo pauser puede pausar; pausa bloquea depositos y retiros; unpause permite operar
    function test_pausar_bloquea_ops_y_roles() public {
        // solo pauser puede pausar
        vm.expectRevert();
        bank.pause();

        vm.prank(pauser);
        bank.pause();

        vm.startPrank(user);
        usdc.approve(address(bank), type(uint256).max);
        vm.expectRevert();
        bank.depositar(address(usdc), 10e6);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert();
        bank.retirar(address(usdc), 1e6);

        vm.prank(pauser);
        bank.unpause();
        // sanidad basica despues de unpause
        vm.startPrank(user);
        bank.depositar(address(usdc), 1e6);
        vm.stopPrank();
    }

    // ------------------ roles ------------------
    // Roles: un usuario sin PAUSER_ROLE no puede pausar ni despausar
    function test_roles_no_pauser_no_puede_pausar_y_unpause() public {
        // si un usuario sin rol intenta pausar, debe revertir con AccessControlUnauthorizedAccount
        bytes32 role = bank.PAUSER_ROLE();
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, role));
        vm.prank(user);
        bank.pause();

        // pausar con el rol valido
        vm.prank(pauser);
        bank.pause();

        // usuario sin rol no puede unpause
        vm.expectRevert(abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", user, role));
        vm.prank(user);
        bank.unpause();

        // pauser si puede unpause
        vm.prank(pauser);
        bank.unpause();
    }

    // Setters admin: slippage, oracle, oracleDevBps
    function test_admin_setters_config() public {
        // Admin puede actualizar slippage dentro de limites
        vm.prank(admin);
        bank.setSlippageBps(250);
        assertEq(bank.slippageBps(), 250, "slippage actualizado");

        // Rechaza slippage por encima del maximo
        vm.expectRevert(abi.encodeWithSignature("SlippageExcesivo(uint256)", 5000));
        vm.prank(admin);
        bank.setSlippageBps(5001);

        // Admin puede actualizar oracleDevBps (<=10000)
        vm.prank(admin);
        bank.setOracleDevBps(1234);
        assertEq(bank.oracleDevBps(), 1234, "oracleDevBps actualizado");

        // Rechaza oracleDevBps > 10000
        vm.expectRevert();
        vm.prank(admin);
        bank.setOracleDevBps(10001);

        // Admin puede actualizar oraculo y maxDelay
        address newOracle = vm.envAddress("ETH_ORACLE");
        vm.prank(admin);
        bank.setOracle(newOracle, 3600);
        assertEq(address(bank.ethUsdOracle()), newOracle, "oraculo actualizado");
        assertEq(bank.oracleMaxDelay(), 3600, "max delay actualizado");

        // No admin no puede usar setters
        vm.expectRevert();
        vm.prank(user);
        bank.setSlippageBps(100);
        vm.expectRevert();
        vm.prank(user);
        bank.setOracleDevBps(100);
        vm.expectRevert();
        vm.prank(user);
        bank.setOracle(newOracle, 7200);
    }

    // Roles: admin otorga PAUSER_ROLE y el nuevo pauser puede pausar y despausar
    function test_roles_admin_otorga_pauser_y_nuevo_pauser_puede_pausar() public {
        // admin puede otorgar PAUSER_ROLE a un nuevo actor y este debe poder pausar/unpause
        address nuevo = address(0xD00D);
        bytes32 pauserRole = bank.PAUSER_ROLE();
        vm.prank(admin);
        bank.grantRole(pauserRole, nuevo);
        assertTrue(bank.hasRole(pauserRole, nuevo), "nuevo no tiene rol pauser");

        vm.prank(nuevo);
        bank.pause();
        vm.prank(nuevo);
        bank.unpause();
    }

    // Roles: un actor sin DEFAULT_ADMIN_ROLE no puede otorgar PAUSER_ROLE
    function test_roles_no_admin_no_puede_otorgar_pauser() public {
        // un usuario sin rol admin no puede otorgar roles
        bytes32 adminRole = bank.DEFAULT_ADMIN_ROLE();
        // sanity: user no es pauser
        assertFalse(bank.hasRole(bank.PAUSER_ROLE(), user), "user no deberia ser pauser");
        // orden seguro: primero expectRevert, luego prank para que la siguiente llamada sea la del usuario
        // usamos llamada de bajo nivel para afirmar el revert sin depender de expectRevert
        vm.prank(user);
        (bool okUser, ) = address(bank).call(abi.encodeWithSelector(bank.grantRole.selector, bank.PAUSER_ROLE(), address(0xABCD)));
        assertFalse(okUser, "grantRole por user sin admin deberia revertir");
        // asegurar que no se otorgo el rol
        assertFalse(bank.hasRole(bank.PAUSER_ROLE(), address(0xABCD)));
    }

    // Roles: un pauser sin DEFAULT_ADMIN_ROLE no puede otorgar roles
    function test_roles_pauser_sin_admin_no_puede_otorgar() public {
        // un actor con PAUSER_ROLE pero sin DEFAULT_ADMIN_ROLE no puede otorgar roles
        bytes32 adminRole = bank.DEFAULT_ADMIN_ROLE();
        assertTrue(bank.hasRole(bank.PAUSER_ROLE(), pauser), "pauser deberia tener rol pauser");
        assertFalse(bank.hasRole(adminRole, pauser), "pauser no deberia ser admin por defecto");

        address destinatario = address(0xB0B0);
        // llamada de bajo nivel para verificar revert sin depender de expectRevert
        vm.prank(pauser);
        (bool okPauser, ) = address(bank).call(abi.encodeWithSelector(bank.grantRole.selector, bank.PAUSER_ROLE(), destinatario));
        assertFalse(okPauser, "grantRole por pauser sin admin deberia revertir");
        assertFalse(bank.hasRole(bank.PAUSER_ROLE(), destinatario), "no deberia haberse otorgado el rol");
    }
}
