// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// OpenZeppelin
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V2
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
// Chainlink
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

/// @title KipuBankV3
/// @author Kipu
/// @notice Contrato de contabilidad tipo banco que acepta depositos en ETH, USDC o cualquier ERC20 con par directo
///         a USDC en Uniswap V2 y acredita saldo del usuario en USDC (6 decimales). Los tokens que no son USDC se
///         swappean a USDC via el router V2 configurado. Un tope global del banco (USDC 6 decimales) limita el valor
///         total acreditado. Opcionalmente se valida contra un oraculo Chainlink ETH/USD mediante oracleDevBps para
///         comparar la cotizacion del AMM y rechazar desvios excesivos.
contract KipuBankV3 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TIPOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Alias interno para cantidades contables expresadas en USDC (6 decimales).
    type USD6 is uint256;

    /// @notice Contadores de actividad por usuario (solo informativo).
    struct UserCounters {
        uint64 deposits;
        uint64 withdrawals;
    }

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /*//////////////////////////////////////////////////////////////
                        CONSTANTES / INMUTABLES
    //////////////////////////////////////////////////////////////*/

    string public constant NAME = "KipuBankV3";
    string public constant VERSION = "3.0.0";

    /// @notice Direccion canonica usada para representar ETH nativo en la API.
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Decimales de USDC usados para la contabilidad (se esperan 6).
    uint8 public constant USD_DECIMALS = 6;
    /// @notice Maximo slippage permitido en basis points para swaps en AMM (50%).
    uint256 public constant MAX_SLIPPAGE_BPS = 5_000;


    /// @notice Router Uniswap V2 usado para cotizar y swappear (inmutable).
    IUniswapV2Router02 public immutable router;
    /// @notice Factory Uniswap V2 resuelta desde el router (inmutable).
    IUniswapV2Factory public immutable factory;
    /// @notice Direccion WETH retornada por el router (inmutable).
    address public immutable WETH;
    /// @notice Token USDC usado como unidad contable (direccion inmutable, se esperan 6 decimales).
    address public immutable USDC;
    /// @notice Oraculo Chainlink ETH/USD usado para validar cotizaciones del AMM (configurable por admin).
    AggregatorV3Interface public ethUsdOracle;
    /// @notice Antiguedad maxima permitida del precio del oraculo en segundos (configurable por admin).
    uint256 public oracleMaxDelay;
    /// @notice Desviacion permitida contra el oraculo en basis points. 0 deshabilita el chequeo (configurable por admin).
    uint256 public oracleDevBps;
    /// @notice Decimales cacheados del oraculo Chainlink ETH/USD, se actualizan al cambiar el oraculo.
    uint8 public ethOracleDecimals;

    /// @notice Tope global del banco expresado en USDC 6 decimales.
    USD6 public immutable bankCapUSD6;
    /// @notice Limite por retiro por transaccion expresado en USDC 6 decimales.
    USD6 public immutable withdrawCapUSD6;
    /// @notice Tolerancia de slippage en basis points (ej 100 = 1%). Configurable por admin.
    uint256 public slippageBps;

    /*//////////////////////////////////////////////////////////////
                               ALMACENAMIENTO
    //////////////////////////////////////////////////////////////*/
    /// @notice Saldos de usuarios en USDC (6 decimales). Mapea usuario => saldo.
    mapping(address => uint256) private _balancesUSDC; // user => usdc amount (6 decs)
    /// @notice Valor total contable del banco en USDC (6 decimales).
    USD6 public totalValueUSD6;
    /// @notice Mapeo de contadores por usuario.
    mapping(address => UserCounters) private _counters;

    /*//////////////////////////////////////////////////////////////
                                   ERRORES
    //////////////////////////////////////////////////////////////*/
    /// @notice Lanzado cuando el monto es cero.
    error MontoCero();
    /// @notice Lanzado cuando los parametros de deposito ETH son invalidos.
    error ParametrosEthInvalidos();
    /// @notice Lanzado cuando los parametros de deposito ERC20 son invalidos.
    error ParametrosErc20Invalidos();
    /// @notice Lanzado cuando el nuevo total propuesto excederia el tope del banco.
    /// @param propuestoUSD6 total propuesto en USDC 6 decimales
    /// @param capUSD6 tope del banco en USDC 6 decimales
    error ExcedeTopeBancoUSD(uint256 propuestoUSD6, uint256 capUSD6);
    /// @notice Lanzado cuando un retiro excede el limite por retiro.
    /// @param montoUSD6 retiro solicitado en USDC 6 decimales
    /// @param capUSD6 limite por retiro en USDC 6 decimales
    error ExcedeTopeRetiroUSD(uint256 montoUSD6, uint256 capUSD6);
    /// @notice Lanzado cuando el saldo del usuario es insuficiente para retirar.
    /// @param saldo saldo actual del usuario
    /// @param monto monto solicitado
    error SaldoInsuficiente(uint256 saldo, uint256 monto);
    /// @notice Lanzado cuando el total del banco subfluiria.
    /// @param total total actual
    /// @param monto monto
    error TotalInsuficiente(uint256 total, uint256 monto);
    /// @notice Lanzado cuando falla la transferencia nativa.
    error TransferenciaNativaFallida();
    /// @notice Lanzado cuando una direccion es cero.
    error DireccionInvalida();
    /// @notice Lanzado cuando no existe par directo V2 entre token y USDC.
    /// @param token token de entrada
    /// @param usdc direccion de USDC
    error PairInexistente(address token, address usdc);
    /// @notice Lanzado cuando el out del swap esta por debajo del minimo esperado.
    /// @param minOut minimo requerido
    /// @param realOut out real recibido
    error SlippageInsuficiente(uint256 minOut, uint256 realOut);
    /// @notice Lanzado cuando los decimales de USDC no son 6.
    /// @param actual decimales reportados
    error UsdcDecimalesInvalido(uint8 actual);
    /// @notice Lanzado para parametros numericos invalidos (ej demoras en cero, orden de caps).
    error ParametrosNumericosInvalidos();
    /// @notice Lanzado cuando el slippage solicitado excede MAX_SLIPPAGE_BPS.
    /// @param maxPermitido slippage maximo permitido en bps
    error SlippageExcesivo(uint256 maxPermitido);
    /// @notice Lanzado cuando el precio del oraculo esta stale.
    /// @param updatedAt timestamp de ultima actualizacion
    /// @param maxDelay antiguedad maxima permitida
    error OraculoStale(uint256 updatedAt, uint256 maxDelay);
    /// @notice Lanzado cuando el oraculo retorna precio no positivo.
    error OraculoPrecioInvalido();
    /// @notice Lanzado cuando el out esperado por AMM se desvia del oraculo por encima de la tolerancia.
    /// @param esperadoAMM monto segun AMM
    /// @param esperadoOraculo monto segun oraculo
    /// @param bps desviacion permitida en basis points
    error DesviacionOraculoExcesiva(uint256 esperadoAMM, uint256 esperadoOraculo, uint256 bps);
    /// @notice Reservado para uso futuro cuando se requiera oraculo pero no este configurado.
    error OraculoNoConfigurado();



    /*//////////////////////////////////////////////////////////////
                                   EVENTOS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitido cuando se acredita valor al saldo de un usuario.
    /// @param cuenta direccion del usuario acreditado
    /// @param token token recibido (USDC contable)
    /// @param montoRaw monto recibido en decimales del token
    /// @param nuevoSaldoRaw nuevo saldo del usuario en USDC (6 decimales)
    /// @param valorUSD6 valor acreditado en USDC 6 decimales
    event Depositado(address indexed cuenta, address indexed token, uint256 montoRaw, uint256 nuevoSaldoRaw, uint256 valorUSD6);
    /// @notice Emitido cuando se debita valor del saldo de un usuario.
    /// @param cuenta direccion del usuario debitado
    /// @param token token enviado (USDC)
    /// @param montoRaw monto retirado
    /// @param nuevoSaldoRaw nuevo saldo del usuario
    /// @param valorUSD6 valor debitado en USDC 6 decimales
    event Retirado(address indexed cuenta, address indexed token, uint256 montoRaw, uint256 nuevoSaldoRaw, uint256 valorUSD6);
    /// @notice Emitido cuando se ejecuta un swap para convertir a USDC.
    /// @param cuenta usuario que inicio el deposito
    /// @param tokenIn token de entrada
    /// @param montoIn monto de entrada
    /// @param montoOutUSDC monto de USDC recibido
    event Swapeado(address indexed cuenta, address indexed tokenIn, uint256 montoIn, uint256 montoOutUSDC);

    /*//////////////////////////////////////////////////////////////
                                 CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /// @notice Inicializa el contrato.
    /// @param admin direccion que recibe DEFAULT_ADMIN_ROLE
    /// @param pauser direccion que recibe PAUSER_ROLE
    /// @param router_ direccion del router Uniswap V2
    /// @param usdc direccion del token USDC (debe reportar 6 decimales)
    /// @param bankCapUSD6_ tope global del banco en USDC 6 decimales
    /// @param withdrawCapUSD6_ limite por retiro en USDC 6 decimales
    /// @param slippageBps_ tolerancia de slippage del AMM en bps (0..MAX_SLIPPAGE_BPS)
    /// @param ethOracle_ direccion del agregador Chainlink ETH/USD
    /// @param oracleMaxDelay_ antiguedad maxima permitida en segundos para el precio del oraculo
    /// @param oracleDevBps_ tolerancia de desviacion en bps contra el oraculo (0 deshabilita)
    constructor(
    address admin,
    address pauser,
    address router_,
    address usdc,
    uint256 bankCapUSD6_,
    uint256 withdrawCapUSD6_,
    uint256 slippageBps_,
    address ethOracle_,
    uint256 oracleMaxDelay_,
    uint256 oracleDevBps_
) {
    // ---- Checks de direcciones y parametros numericos ----
    if (admin == address(0) || pauser == address(0)) revert DireccionInvalida();
    if (router_ == address(0) || usdc == address(0) || ethOracle_ == address(0)) revert DireccionInvalida();
    if (bankCapUSD6_ == 0 || withdrawCapUSD6_ == 0 || withdrawCapUSD6_ > bankCapUSD6_) revert ParametrosNumericosInvalidos();
    if (slippageBps_ > MAX_SLIPPAGE_BPS) revert SlippageExcesivo(MAX_SLIPPAGE_BPS);
    if (oracleMaxDelay_ == 0) revert ParametrosNumericosInvalidos();
    if (oracleDevBps_ > 10_000) revert ParametrosNumericosInvalidos();

    // ---- Sanidad: chequear decimales de USDC ----
    // Si no implementa decimals() o revierte, no lo aceptamos.
    try IERC20Metadata(usdc).decimals() returns (uint8 d) {
        if (d != USD_DECIMALS) revert UsdcDecimalesInvalido(d);
    } catch {
        // Token no cumple la interfaz esperada, no lo tratamos como USDC valido
        revert DireccionInvalida();
    }

    // ---- Roles ----
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(PAUSER_ROLE, pauser);

    // ---- Uniswap V2 ----
    router = IUniswapV2Router02(router_);
    factory = IUniswapV2Factory(router.factory());
    WETH = router.WETH();

    // ---- Configuracion de USDC y limites ----
    USDC = usdc;
    bankCapUSD6 = USD6.wrap(bankCapUSD6_);
    withdrawCapUSD6 = USD6.wrap(withdrawCapUSD6_);
    slippageBps = slippageBps_;
    ethUsdOracle = AggregatorV3Interface(ethOracle_);
    oracleMaxDelay = oracleMaxDelay_;
    oracleDevBps = oracleDevBps_;
    ethOracleDecimals = ethUsdOracle.decimals();
}

    /*//////////////////////////////////////////////////////////////
                             ADMIN / PAUSA
    //////////////////////////////////////////////////////////////*/
    /// @notice Pone el contrato en pausa. Solo puede llamarlo PAUSER_ROLE.
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }

    /// @notice Quita la pausa del contrato. Solo puede llamarlo PAUSER_ROLE.
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    /*//////////////////////////////////////////////////////////////
                             INTERFAZ PUBLICA
    //////////////////////////////////////////////////////////////*/
    /// @notice Deposita ETH, USDC o un ERC20 con par directo a USDC a traves de Uniswap V2.
    /// @dev Para ETH: token debe ser NATIVE_TOKEN, amount debe ser 0 y msg.value > 0.
    ///      Para ERC20 (incluido USDC): msg.value debe ser 0 y amount > 0.
    function depositar(address token, uint256 amount)
        external
        payable
        whenNotPaused
        nonReentrant
        validDepositParams(token, amount)
    {
        if (token == NATIVE_TOKEN) {

            _depositNativeSwap(msg.sender, msg.value);

        } else if (token == USDC) {

            _depositUSDC(msg.sender, amount);

        } else {

            _depositErc20Swap(msg.sender, token, amount);

        }
}



    /// @notice Retira USDC del saldo del emisor respetando el limite por retiro.
    function retirar(address token, uint256 amount)
        external
        whenNotPaused
        nonReentrant
    {
        if (token != USDC) revert DireccionInvalida();
        if (amount == 0) revert MontoCero();

        uint256 bal = _balancesUSDC[msg.sender];
        if (bal < amount) revert SaldoInsuficiente(bal, amount);

        if (amount > USD6.unwrap(withdrawCapUSD6)) {
            revert ExcedeTopeRetiroUSD(amount, USD6.unwrap(withdrawCapUSD6));
        }
        uint256 newTv = USD6.unwrap(totalValueUSD6) - amount;  // Fuera de unchecked para check de underflow

        unchecked {
            _balancesUSDC[msg.sender] = bal - amount;
            totalValueUSD6 = USD6.wrap(newTv);
            _counters[msg.sender].withdrawals += 1;
        }

        emit Retirado(msg.sender, USDC, amount, _balancesUSDC[msg.sender], amount);

        IERC20(USDC).safeTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                             ADMIN / CONFIG
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitido cuando se actualiza la tolerancia de slippage.
    /// @param anterior slippage anterior en bps
    /// @param nuevo slippage nuevo en bps
    event SlippageActualizado(uint256 anterior, uint256 nuevo);
    /// @notice Emitido cuando se actualiza la direccion del oraculo o el max delay.
    /// @param anterior direccion anterior del oraculo
    /// @param nuevo nueva direccion del oraculo
    /// @param delayAnterior delay maximo anterior
    /// @param delayNuevo delay maximo nuevo
    /// @param decimales decimales reportados por el nuevo oraculo
    event OracleActualizado(address anterior, address nuevo, uint256 delayAnterior, uint256 delayNuevo, uint8 decimales);
    /// @notice Emitido cuando se actualiza la tolerancia de desviacion contra el oraculo.
    /// @param anterior valor anterior en bps
    /// @param nuevo valor nuevo en bps
    event OracleDevBpsActualizado(uint256 anterior, uint256 nuevo);

    /// @notice Actualiza la tolerancia de slippage en bps. Solo ADMIN.
    /// @param newBps nuevo valor de slippage en bps (debe ser <= MAX_SLIPPAGE_BPS)
    function setSlippageBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_SLIPPAGE_BPS) revert SlippageExcesivo(MAX_SLIPPAGE_BPS);
        uint256 old = slippageBps;
        slippageBps = newBps;
        emit SlippageActualizado(old, newBps);
    }

    /// @notice Actualiza el oraculo y el max delay. Solo ADMIN.
    /// @param newOracle nueva direccion del agregador Chainlink
    /// @param newMaxDelay nuevo maximo delay en segundos
    function setOracle(address newOracle, uint256 newMaxDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOracle == address(0)) revert DireccionInvalida();
        if (newMaxDelay == 0) revert ParametrosNumericosInvalidos();
        // validar que el oraculo implementa decimals()
        uint8 dec;
        try AggregatorV3Interface(newOracle).decimals() returns (uint8 d) {
            dec = d;
        } catch {
            revert DireccionInvalida();
        }
        address old = address(ethUsdOracle);
        uint256 oldDelay = oracleMaxDelay;
        ethUsdOracle = AggregatorV3Interface(newOracle);
        oracleMaxDelay = newMaxDelay;
        ethOracleDecimals = dec;
        emit OracleActualizado(old, newOracle, oldDelay, newMaxDelay, dec);
    }

    /// @notice Actualiza la tolerancia de desviacion contra el oraculo (bps). Solo ADMIN.
    /// @param newBps nuevo valor en bps (0..10000)
    function setOracleDevBps(uint256 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > 10_000) revert ParametrosNumericosInvalidos();
        uint256 old = oracleDevBps;
        oracleDevBps = newBps;
        emit OracleDevBpsActualizado(old, newBps);
    }

    /*//////////////////////////////////////////////////////////////
                                   VISTAS
    //////////////////////////////////////////////////////////////*/
    /// @notice Devuelve el saldo en USDC (6 decimales) de una cuenta.
    /// @param cuenta direccion a consultar
    /// @return saldoUSDC saldo del usuario en USDC (6 decimales)
    function saldoUSDCDe(address cuenta) external view returns (uint256 saldoUSDC) { return _balancesUSDC[cuenta]; }

    /// @notice Devuelve el valor total del banco en USDC (6 decimales).
    /// @return totalUSD6 total en USDC (6 decimales)
    function totalValueUSD6Raw() external view returns (uint256 totalUSD6) { return USD6.unwrap(totalValueUSD6); }

    /// @notice Devuelve el tope global del banco en USDC (6 decimales).
    /// @return capUSD6 tope en USDC (6 decimales)
    function bankCapUSD6Raw() external view returns (uint256 capUSD6) { return USD6.unwrap(bankCapUSD6); }

    /// @notice Devuelve el limite por retiro en USDC (6 decimales).
    /// @return capUSD6 limite por retiro en USDC (6 decimales)
    function withdrawCapUSD6Raw() external view returns (uint256 capUSD6) { return USD6.unwrap(withdrawCapUSD6); }

    /// @notice Devuelve la capacidad restante antes de alcanzar el tope del banco.
    /// @return espacioUSD6 espacio disponible en USDC (6 decimales)
    function capacidadDisponibleUSD() external view returns (uint256 espacioUSD6) {
        uint256 cap = USD6.unwrap(bankCapUSD6);
        uint256 tv = USD6.unwrap(totalValueUSD6);
        return cap > tv ? cap - tv : 0;
    }

    /// @notice Devuelve contadores informativos del usuario.
    /// @param cuenta direccion a consultar
    /// @return depositos cantidad de depositos realizados por el usuario
    /// @return retiros cantidad de retiros realizados por el usuario
    function contadoresDeUsuario(address cuenta) external view returns (uint64 depositos, uint64 retiros) {
        UserCounters memory c = _counters[cuenta];
        return (c.deposits, c.withdrawals);
    }

    /// @notice Indica si un token es aceptado para depositar (USDC, ETH nativo, o par directo con USDC).
    /// @param token direccion del token a consultar
    /// @return aceptado true si es aceptado, false en caso contrario
    function tokenAceptado(address token) public view returns (bool aceptado) {
        if (token == NATIVE_TOKEN || token == USDC) return true;
        return factory.getPair(token, USDC) != address(0);
    }

    /*//////////////////////////////////////////////////////////////
                           RECEPCION DE ETH
    //////////////////////////////////////////////////////////////*/
    /// @notice Funcion receive para aceptar ETH nativo y depositar swappeando a USDC.
    receive() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert MontoCero();

        _depositNativeSwap(msg.sender, msg.value);
}

    /*//////////////////////////////////////////////////////////////
                           LOGICA DE DEPOSITO
    //////////////////////////////////////////////////////////////*/
    /// @notice Rutina interna para depositar USDC directo.
    /// @param from direccion fuente
    /// @param amount monto USDC (6 decimales) a depositar
    function _depositUSDC(address from, uint256 amount) internal {
        if (amount == 0) revert MontoCero();


        uint256 before = IERC20(USDC).balanceOf(address(this));
        IERC20(USDC).safeTransferFrom(from, address(this), amount);
        uint256 received = IERC20(USDC).balanceOf(address(this)) - before;


        uint256 proposed = USD6.unwrap(totalValueUSD6) + received;
        if (proposed > USD6.unwrap(bankCapUSD6)) {
            revert ExcedeTopeBancoUSD(proposed, USD6.unwrap(bankCapUSD6));
        }

        unchecked {
            _balancesUSDC[from] += received;
            totalValueUSD6 = USD6.wrap(proposed);
            _counters[from].deposits += 1;
        }

        emit Depositado(from, USDC, received, _balancesUSDC[from], received);
    }

    /// @notice Rutina interna para depositar un ERC20 con par directo a USDC, swappeando a USDC.
    /// @param from direccion fuente
    /// @param tokenIn direccion del token ERC20
    /// @param amountIn monto de entrada
    function _depositErc20Swap(address from, address tokenIn, uint256 amountIn) internal {
        if (amountIn == 0) revert MontoCero();
        if (!tokenAceptado(tokenIn)) revert PairInexistente(tokenIn, USDC);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = USDC;

        uint256 minOut = _quoteMinOut(amountIn, path);

        // Pre-chequeo de cap usando minOut para no exceder el limite
        uint256 proposed = USD6.unwrap(totalValueUSD6) + minOut;
        if (proposed > USD6.unwrap(bankCapUSD6)) {
            revert ExcedeTopeBancoUSD(proposed, USD6.unwrap(bankCapUSD6));
        }

        // Pull token y aprobar router
        IERC20(tokenIn).safeTransferFrom(from, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // swap exact in -> USDC to this contract
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        uint256 outUSDC = amounts[amounts.length - 1];
        if (outUSDC < minOut) revert SlippageInsuficiente(minOut, outUSDC);

        // Cierre de allowance por higiene (no estrictamente requerido)
        IERC20(tokenIn).forceApprove(address(router), 0);

        // Chequeo final de cap con el monto real
        uint256 proposedFinal = USD6.unwrap(totalValueUSD6) + outUSDC;
        if (proposedFinal > USD6.unwrap(bankCapUSD6)) {
            revert ExcedeTopeBancoUSD(proposedFinal, USD6.unwrap(bankCapUSD6));
        }

        unchecked {
            _balancesUSDC[from] += outUSDC;
            totalValueUSD6 = USD6.wrap(proposedFinal);
            _counters[from].deposits += 1;
        }

        emit Swapeado(from, tokenIn, amountIn, outUSDC);
        emit Depositado(from, USDC, outUSDC, _balancesUSDC[from], outUSDC);
    }

    /// @notice Rutina interna para depositar ETH nativo usando la ruta directa del AMM.
    /// @param from direccion fuente
    /// @param amountInWei monto de ETH en wei
    function _depositNativeSwapDirect(address from, uint256 amountInWei) internal {
        if (amountInWei == 0) revert MontoCero();

        // path WETH -> USDC
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // verificar que exista par WETH/USDC
        if (factory.getPair(WETH, USDC) == address(0)) revert PairInexistente(WETH, USDC);

        // Cotiza esperado y minOut (2 hops: WETH -> USDC)
        uint256 expectedOut = router.getAmountsOut(amountInWei, path)[1];
        uint256 minOut = (expectedOut * (10_000 - slippageBps)) / 10_000;
        uint256 proposed = USD6.unwrap(totalValueUSD6) + minOut;
        if (proposed > USD6.unwrap(bankCapUSD6)) {
            revert ExcedeTopeBancoUSD(proposed, USD6.unwrap(bankCapUSD6));
        }

        uint256[] memory amounts = router.swapExactETHForTokens{value: amountInWei}(
            minOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        uint256 outUSDC = amounts[amounts.length - 1];
        if (outUSDC < minOut) revert SlippageInsuficiente(minOut, outUSDC);

        uint256 proposedFinal = USD6.unwrap(totalValueUSD6) + outUSDC;
        if (proposedFinal > USD6.unwrap(bankCapUSD6)) {
            revert ExcedeTopeBancoUSD(proposedFinal, USD6.unwrap(bankCapUSD6));
        }

        unchecked {
            _balancesUSDC[from] += outUSDC;
            totalValueUSD6 = USD6.wrap(proposedFinal);
            _counters[from].deposits += 1;
        }

        emit Swapeado(from, NATIVE_TOKEN, amountInWei, outUSDC);
        emit Depositado(from, USDC, outUSDC, _balancesUSDC[from], outUSDC);
    }

    /// @notice Rutina interna para depositar ETH nativo usando validacion con oraculo.
    /// @param from direccion fuente
    /// @param amountInWei monto de ETH en wei
    function _depositNativeSwapOracle(address from, uint256 amountInWei) internal {
        if (amountInWei == 0) revert MontoCero();
        
        // path WETH -> USDC
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        if (factory.getPair(WETH, USDC) == address(0)) revert PairInexistente(WETH, USDC);

        uint256 expectedOut = router.getAmountsOut(amountInWei, path)[1];
        uint256 minOut = (expectedOut * (10_000 - slippageBps)) / 10_000;

        // chequeo duro contra oraculo
        (/*roundId*/, int256 answer, /*startedAt*/, uint256 updatedAt, /*answeredInRound*/) = ethUsdOracle.latestRoundData();
        if (answer <= 0) revert OraculoPrecioInvalido();
        if (block.timestamp - updatedAt > oracleMaxDelay) revert OraculoStale(updatedAt, oracleMaxDelay);
        uint256 oracleOut = (amountInWei * (uint256(answer) * (10 ** USD_DECIMALS) / (10 ** ethOracleDecimals))) / 1e18;
        uint256 diff = expectedOut > oracleOut ? expectedOut - oracleOut : oracleOut - expectedOut;
        uint256 maxDiff = (oracleOut * oracleDevBps) / 10_000;
        if (diff > maxDiff) revert DesviacionOraculoExcesiva(expectedOut, oracleOut, oracleDevBps);

        uint256 proposed = USD6.unwrap(totalValueUSD6) + minOut;
        if (proposed > USD6.unwrap(bankCapUSD6)) {
            revert ExcedeTopeBancoUSD(proposed, USD6.unwrap(bankCapUSD6));
        }

        uint256[] memory amounts = router.swapExactETHForTokens{value: amountInWei}(
            minOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        uint256 outUSDC = amounts[amounts.length - 1];
        if (outUSDC < minOut) revert SlippageInsuficiente(minOut, outUSDC);

        uint256 proposedFinal = USD6.unwrap(totalValueUSD6) + outUSDC;
        if (proposedFinal > USD6.unwrap(bankCapUSD6)) {
            revert ExcedeTopeBancoUSD(proposedFinal, USD6.unwrap(bankCapUSD6));
        }

        unchecked {
            _balancesUSDC[from] += outUSDC;
            totalValueUSD6 = USD6.wrap(proposedFinal);
            _counters[from].deposits += 1;
        }

        emit Swapeado(from, NATIVE_TOKEN, amountInWei, outUSDC);
        emit Depositado(from, USDC, outUSDC, _balancesUSDC[from], outUSDC);
    }

    /// @notice Deposito nativo unificado que realiza chequeo con oraculo cuando esta habilitado y hace fallback a la ruta directa si es necesario.
    function _depositNativeSwap(address from, uint256 amountInWei) internal {
        if (amountInWei == 0) revert MontoCero();

        // If oracle comparison is disabled, use direct route.
        if (oracleDevBps == 0) {
            _depositNativeSwapDirect(from, amountInWei);
            return;
        }

        // Ensure WETH/USDC pair exists for any route
        if (factory.getPair(WETH, USDC) == address(0)) revert PairInexistente(WETH, USDC);

        // Try oracle; if it fails or is stale/invalid, fallback to direct swap
        int256 answer;
        uint256 updatedAt;
        bool oracleOk;
        try ethUsdOracle.latestRoundData() returns (
            uint80 /*roundId*/,
            int256 a,
            uint256 /*startedAt*/,
            uint256 u,
            uint80 /*answeredInRound*/
        ) {
            answer = a;
            updatedAt = u;
            oracleOk = (a > 0) && (block.timestamp - u <= oracleMaxDelay);
        } catch {
            oracleOk = false;
        }

        if (!oracleOk) {
            _depositNativeSwapDirect(from, amountInWei);
            return;
        }

        // With oracle OK: validate deviation against AMM quote
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        uint256 expectedOut = router.getAmountsOut(amountInWei, path)[1];
        // Convert oracle price to USDC units (6 decimals)
        uint256 oracleOut = (amountInWei * (uint256(answer) * (10 ** USD_DECIMALS) / (10 ** ethOracleDecimals))) / 1e18;
        uint256 diff = expectedOut > oracleOut ? expectedOut - oracleOut : oracleOut - expectedOut;
        uint256 maxDiff = (oracleOut * oracleDevBps) / 10_000;

        if (diff > maxDiff) {
            revert DesviacionOraculoExcesiva(expectedOut, oracleOut, oracleDevBps);
        }

        // Deviation acceptable: perform direct swap (same accounting/events)
        _depositNativeSwapDirect(from, amountInWei);
    }

    /// @notice Calcula el minimo aceptable del swap segun la tolerancia de slippage.
    /// @param amountIn monto de entrada
    /// @param path path del swap
    /// @return minOut minimo aceptable de salida
    function _quoteMinOut(uint256 amountIn, address[] memory path) internal view returns (uint256 minOut) {
        uint256[] memory outs = router.getAmountsOut(amountIn, path);
        uint256 expected = outs[outs.length - 1];
        // minOut = expected * (1 - slippageBps/10000)
        uint256 bps = 10_000;
        uint256 tol = bps - slippageBps;
        minOut = (expected * tol) / bps;
    }

    /*//////////////////////////////////////////////////////////////
                           MODIFICADORES
    //////////////////////////////////////////////////////////////*/
    /// @notice Valida parametros de deposito para ETH vs ERC20.
    /// @param token direccion del token (usar NATIVE_TOKEN para ETH)
    /// @param amount parametro de monto (0 para depositos de ETH)
    modifier validDepositParams(address token, uint256 amount) {
        if (token == NATIVE_TOKEN) {
            // Para ETH: amount debe ser 0 y msg.value > 0
            if (amount != 0 || msg.value == 0) revert ParametrosEthInvalidos();
        } else {
            // Para ERC-20 (incluido USDC): msg.value debe ser 0 y amount > 0
            if (msg.value != 0 || amount == 0) revert ParametrosErc20Invalidos();
        }
        _;
    }
}

