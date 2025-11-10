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

/// @title KipuBankV3 - Depósitos de cualquier token swappeados a USDC vía Uniswap V2, con bank cap en USDC
/// @author Kipu
/// @notice Acepta depósitos de ETH, USDC o cualquier ERC20 con par directo a USDC en Uniswap V2.
///         Si el token no es USDC, se swappea automáticamente a USDC y se acredita en el saldo del usuario.
///         Se respeta un tope global del banco (bank cap) expresado en USDC (6 decimales).
contract KipuBankV3 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TIPOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Cantidades contables expresadas en USDC (6 decimales).
    type USD6 is uint256;

    /// @notice Contadores de actividad por usuario (informativos).
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

    /// @notice Direccion canonica para ETH.
    address public constant NATIVE_TOKEN = address(0);

    /// @notice Decimales de USDC utilizados para la contabilidad (6).
    uint8 public constant USD_DECIMALS = 6;
    /// @notice Máximo slippage permitido en basis points (50%).
    uint256 public constant MAX_SLIPPAGE_BPS = 5_000;


    /// @notice Router de Uniswap V2 (inmutable).
    IUniswapV2Router02 public immutable router;
    /// @notice Factory de Uniswap V2 (inmutable).
    IUniswapV2Factory public immutable factory;
    /// @notice WETH del router (inmutable).
    address public immutable WETH;
    /// @notice Direccion del token USDC usado como unidad contable.
    address public immutable USDC;
    /// @notice Oraculo Chainlink ETH/USD
    AggregatorV3Interface public immutable ethUsdOracle;
    /// @notice Maxima antiguedad permitida del precio del oraculo (segundos)
    uint256 public immutable oracleMaxDelay;
    /// @notice Tolerancia de desviacion contra oraculo en bps (0=deshabilitado)
    uint256 public immutable oracleDevBps;

    /// @notice Tope global del banco expresado en USD6 (USDC).
    USD6 public immutable bankCapUSD6;
    /// @notice Limite por retiro por transaccion en USD6.
    USD6 public immutable withdrawCapUSD6;
    /// @notice Tolerancia de slippage en basis points (p.ej. 100 = 1%).
    uint256 public immutable slippageBps;

    /*//////////////////////////////////////////////////////////////
                               ALMACENAMIENTO
    //////////////////////////////////////////////////////////////*/
    /// @notice Saldos de usuarios en USDC (6 decimales).
    mapping(address => uint256) private _balancesUSDC; // user => usdc amount (6 decs)
    /// @notice Valor contable total del banco en USDC (6 decimales).
    USD6 public totalValueUSD6;
    /// @notice Contadores por usuario (informativos).
    mapping(address => UserCounters) private _counters;

    /*//////////////////////////////////////////////////////////////
                                   ERRORES
    //////////////////////////////////////////////////////////////*/
    error MontoCero();
    error ParametrosEthInvalidos();
    error ParametrosErc20Invalidos();
    error ExcedeTopeBancoUSD(uint256 propuestoUSD6, uint256 capUSD6);
    error ExcedeTopeRetiroUSD(uint256 montoUSD6, uint256 capUSD6);
    error SaldoInsuficiente(uint256 saldo, uint256 monto);
    error TotalInsuficiente(uint256 total, uint256 monto);
    error TransferenciaNativaFallida();
    error DireccionInvalida();
    error PairInexistente(address token, address usdc);
    error SlippageInsuficiente(uint256 minOut, uint256 realOut);
    error UsdcDecimalesInvalido(uint8 actual);
    error ParametrosNumericosInvalidos(); // Para caps en cero o comparacion invalida
    error SlippageExcesivo(uint256 maxPermitido); // Para slippage > 50%
    error OraculoStale(uint256 updatedAt, uint256 maxDelay);
    error OraculoPrecioInvalido();
    error DesviacionOraculoExcesiva(uint256 esperadoAMM, uint256 esperadoOraculo, uint256 bps);
    error OraculoNoConfigurado();



    /*//////////////////////////////////////////////////////////////
                                   EVENTOS
    //////////////////////////////////////////////////////////////*/
    /// @dev Mantiene compatibilidad de eventos con V2 pero indicando el token contable (USDC).
    event Depositado(address indexed cuenta, address indexed token, uint256 montoRaw, uint256 nuevoSaldoRaw, uint256 valorUSD6);
    event Retirado(address indexed cuenta, address indexed token, uint256 montoRaw, uint256 nuevoSaldoRaw, uint256 valorUSD6);
    event Swapeado(address indexed cuenta, address indexed tokenIn, uint256 montoIn, uint256 montoOutUSDC);

    /*//////////////////////////////////////////////////////////////
                                 CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /// @param admin address con DEFAULT_ADMIN_ROLE.
    /// @param pauser address con PAUSER_ROLE.
    /// @param router_ direccion del router UniswapV2.
    /// @param usdc direccion del token USDC (6 decimales).
    /// @param bankCapUSD6_ tope global del banco en USDC (6 decimales).
    /// @param withdrawCapUSD6_ tope por retiro en USDC (6 decimales).
    /// @param slippageBps_ tolerancia de slippage en bps (0..10000).
    /// @param ethOracle_ direccion del oraculo Chainlink ETH/USD.
    /// @param oracleMaxDelay_ maxima antiguedad en segundos permitida del precio del oraculo.
    /// @param oracleDevBps_ tolerancia contra oraculo en bps (0 = deshabilita chequeo).
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
    // ---- Checks de direcciones y parámetros numéricos ----
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
    /// @notice Deposita ETH, USDC o un ERC20 con par directo a USDC en Uniswap V2.
    /// @dev Para ETH: amount debe ser 0 y msg.value > 0. Para ERC-20: msg.value == 0 y amount > 0.
    function depositar(address token, uint256 amount)
        external
        payable
        whenNotPaused
        nonReentrant
        validDepositParams(token, amount)
    {
        if (token == NATIVE_TOKEN) {
            // por defecto, version sin oraculo
            _depositNativeSwapDirect(msg.sender, msg.value);
        } else if (token == USDC) {
            _depositUSDC(msg.sender, amount);
        } else {
            _depositErc20Swap(msg.sender, token, amount);
        }
    }

    /// @notice Deposita ETH validando el precio del AMM contra el oraculo (chequeo siempre activo).
    function depositarEthConOraculo()
        external
        payable
        whenNotPaused
        nonReentrant
    {
        if (msg.value == 0) revert MontoCero();
        _depositNativeSwapOracle(msg.sender, msg.value);
    }

    /// @notice Retira USDC del saldo del emisor respetando el tope por retiro.
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

        unchecked {
            _balancesUSDC[msg.sender] = bal - amount;
            uint256 tv = USD6.unwrap(totalValueUSD6);
            if (amount > tv) revert TotalInsuficiente(tv, amount);
            totalValueUSD6 = USD6.wrap(tv - amount);
            _counters[msg.sender].withdrawals += 1;
        }

        emit Retirado(msg.sender, USDC, amount, _balancesUSDC[msg.sender], amount);

        IERC20(USDC).safeTransfer(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                   VISTAS
    //////////////////////////////////////////////////////////////*/
    /// @notice Devuelve el saldo en USDC (6 dec) de una cuenta.
    /// @param cuenta direccion del usuario a consultar.
    /// @return saldoUSDC monto de USDC (6 dec) acreditado a la cuenta.
    function saldoUSDCDe(address cuenta) external view returns (uint256 saldoUSDC) { return _balancesUSDC[cuenta]; }

    /// @notice Devuelve el valor total del banco en USDC (6 dec).
    /// @return totalUSD6 valor total en USDC (6 dec).
    function totalValueUSD6Raw() external view returns (uint256 totalUSD6) { return USD6.unwrap(totalValueUSD6); }

    /// @notice Devuelve el tope global del banco en USDC (6 dec).
    /// @return capUSD6 tope global en USDC (6 dec).
    function bankCapUSD6Raw() external view returns (uint256 capUSD6) { return USD6.unwrap(bankCapUSD6); }

    /// @notice Devuelve el tope por retiro por transaccion en USDC (6 dec).
    /// @return capUSD6 tope por retiro en USDC (6 dec).
    function withdrawCapUSD6Raw() external view returns (uint256 capUSD6) { return USD6.unwrap(withdrawCapUSD6); }

    /// @notice Devuelve la capacidad restante del banco antes de alcanzar el tope global.
    /// @return espacioUSD6 cantidad disponible en USDC (6 dec) que aun puede depositarse.
    function capacidadDisponibleUSD() external view returns (uint256 espacioUSD6) {
        uint256 cap = USD6.unwrap(bankCapUSD6);
        uint256 tv = USD6.unwrap(totalValueUSD6);
        return cap > tv ? cap - tv : 0;
    }

    /// @notice Devuelve los contadores informativos del usuario.
    /// @param cuenta direccion del usuario a consultar.
    /// @return depositos cantidad de depositos efectuados por el usuario.
    /// @return retiros cantidad de retiros efectuados por el usuario.
    function contadoresDeUsuario(address cuenta) external view returns (uint64 depositos, uint64 retiros) {
        UserCounters memory c = _counters[cuenta];
        return (c.deposits, c.withdrawals);
    }

    /// @notice Indica si un token es aceptado para depositar (USDC, ETH nativo o par directo con USDC).
    /// @param token direccion del token a consultar.
    /// @return aceptado true si el token es aceptado, false en caso contrario.
    function tokenAceptado(address token) public view returns (bool aceptado) {
        if (token == NATIVE_TOKEN || token == USDC) return true;
        return factory.getPair(token, USDC) != address(0);
    }

    /*//////////////////////////////////////////////////////////////
                           RECEPCION DE ETH
    //////////////////////////////////////////////////////////////*/
    /// @notice Recibe ETH directamente y lo deposita swappeando a USDC (ruta sin oraculo).
    receive() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert MontoCero();
        // por defecto, ruta sin oraculo
        _depositNativeSwapDirect(msg.sender, msg.value);
    }

    /*//////////////////////////////////////////////////////////////
                           LOGICA DE DEPOSITO
    //////////////////////////////////////////////////////////////*/
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

        emit Depositado(from, USDC, amount, _balancesUSDC[from], amount);
    }

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

    function _depositNativeSwapOracle(address from, uint256 amountInWei) internal {
        if (amountInWei == 0) revert MontoCero();
        if (oracleDevBps == 0) revert OraculoNoConfigurado();

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
        uint256 oracleOut = (amountInWei * (uint256(answer) * (10 ** USD_DECIMALS) / (10 ** ethUsdOracle.decimals()))) / 1e18;
        uint256 diff = expectedOut > oracleOut ? expectedOut - oracleOut : oracleOut - expectedOut;
        uint256 maxDiff = (oracleOut * oracleDevBps) / 10_000;
        if (diff > maxDiff) revert DesviacionOraculoExcesiva(expectedOut, oracleOut, slippageBps);

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
