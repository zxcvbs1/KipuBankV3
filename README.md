KipuBankV3
=======================

Descripción general
-------------------
- `src/KipuBankV3.sol` acepta depósitos en ETH, USDC y cualquier ERC‑20 con par directo a USDC (Uniswap V2).
- Si el token no es USDC, el contrato hace el swap a USDC y acredita el resultado (contabilidad en USDC, 6 decimales).
- Respeta el bank cap antes y después del swap (pre‑check con `getAmountsOut` + check con el `out` real).
- Mantiene roles (admin/pauser), pausas y protección de reentrada.
- Los depósitos de ETH pueden validar opcionalmente la cotización de Uniswap V2 contra un oráculo Chainlink ETH/USD (`oracleDevBps > 0`) y revertir si el desvío es excesivo.
- La instancia de referencia en este repo está desplegada y verificada en Sepolia en:
  - Address: `0x4D82522dFa226d7B0C850272dd3b290053029C73`
  - URL: https://sepolia.etherscan.io/address/0x4D82522dFa226d7B0C850272dd3b290053029C73

Contexto del examen
--------------------
- Este proyecto es la evolución de `KipuBankV2` a `KipuBankV3`, integrando Uniswap V2 para admitir depósitos generalizados en ERC‑20 y consolidando contabilidad en USDC.
- Objetivos de la consigna que cubre este repo:
  - Manejar cualquier token soportado por Uniswap V2 (ETH, USDC y ERC‑20 con par directo a USDC).
  - Ejecutar swaps dentro del contrato para convertir todo a USDC antes de acreditar.
  - Preservar la lógica de depósitos/retiros/roles de KipuBankV2.
  - Respetar el `bankCap` antes y después de los swaps.
  - Alcanzar ≥ 50% de cobertura de pruebas (ver sección "Cobertura y gas").

Decisiones de diseño y trade‑offs
---------------------------------
- V3 hace contabilidad en USDC: todo lo no‑USDC entra por swap (solo par directo) y se acredita en 6 decimales.
- Se exige par directo `token/USDC` y se precalcula `minOut` con slippage para no pasarnos del cap y proteger la ejecucion.
- Para ETH se ofrece una validación opcional contra oráculo: el flujo interno `_depositNativeSwap` puede comparar `getAmountsOut` (AMM) contra Chainlink si `oracleDevBps > 0` y revertir por precio viejo o desvío excesivo, o bien saltar el oráculo (cuando `oracleDevBps == 0`) y usar solo slippage.

Diferencias vs KipuBankV2
--------------------------
- V2 aceptaba un set más limitado de tokens; V3 generaliza depósitos a cualquier ERC‑20 con par directo a USDC en Uniswap V2.
- V3 abstrae toda la contabilidad en USDC (tipo `USD6`) y separa claramente el cálculo contable de la capa de swaps.
- El bank cap ahora se valida explícitamente tanto antes del swap (con `minOut`) como después (con el `out` real), reduciendo riesgos de exceder el límite.
- Se añadieron parámetros configurables on‑chain para slippage y oráculo (`setSlippageBps`, `setOracle`, `setOracleDevBps`).
- La ruta con oráculo ETH/USDC es opcional y parametrizable, pensada como POC extensible a futuros feeds.
- Se mantuvieron y endurecieron mecanismos de seguridad (ReentrancyGuard, Pausable, `tokenAceptado`, limpieza de approvals, etc.).

Entorno y variables
-------------------
- Se usan variables unificadas via `script/select-env.sh` (perfiles `testnet` y `mainnet`).
- Claves: `FORK_RPC_URL`, `FORK_CHAIN_ID`, `FORK_BLOCK`, `V2_ROUTER`, `WETH`, `USDC`, `ETH_ORACLE`, `ORACLE_MAX_DELAY` (default 86400), `ORACLE_DEV_BPS` (0 desactiva oraculo), `PAIR_TOKEN`, `NOT_PAIR_TOKEN` y `ETHERSCAN_API_KEY` (opcional).
- Hay un `.env.example` listo para copiar y completar segun red.

Como correr en local
--------------------
Linux/macOS:
1) Levantar el fork:
   - `bash script/anvil-fork.sh mainnet` (o `testnet`)
2) En la misma shell, seleccionar el perfil para tests:
   - `source script/select-env.sh mainnet`
3) Ejecutar pruebas:
   - `forge test --rpc-url http://127.0.0.1:8545`

Windows (PowerShell):
1) Levantar el fork:
   - `./script/anvil-fork.ps1 mainnet` (o `testnet`)
2) En la misma consola, seleccionar el perfil para tests:
   - `./script/select-env.ps1 mainnet`
3) Ejecutar pruebas:
   - `forge test --rpc-url http://127.0.0.1:8545`
Nota: si PowerShell bloquea la ejecucion de scripts, habilitar en la sesion actual: `Set-ExecutionPolicy -Scope Process RemoteSigned`

Importante: las direcciones de `V2_ROUTER/WETH/USDC/ETH_ORACLE` deben coincidir con la red del fork. Si mezclas Sepolia con un fork mainnet (o viceversa) los tests que interactuan con on‑chain van a revertir.

Seguridad
---------
- `checks-effects-interactions` en depósitos y retiros.
- `ReentrancyGuard` en entradas públicas mutantes.
- `Pausable` con rol dedicado para emergencias.
- `SafeERC20` y limpieza de approvals antes de aprobar un nuevo monto.
- Validación de par directo `factory.getPair(token, USDC) != address(0)`.
- Slippage configurable por constructor (`maxSlippageBps`).

Despliegue y verificacion
-------------------------
Hay dos caminos principales para desplegar en Sepolia:

1) **Manual con `forge create` (ADMIN directo, sin timelock)**
- Variables leídas desde `.env`: `SEPOLIA_RPC_URL`, `PRIVATE_KEY`, `ADMIN`, `PAUSER`, `V2_ROUTER`, `USDC`, `BANK_CAP_USD6`, `WITHDRAW_CAP_USD6`, `SLIPPAGE_BPS`, `ETH_ORACLE`, `ORACLE_MAX_DELAY`, `ORACLE_DEV_BPS`.
- Comando recomendado (contract‑first):

```bash
source script/load-env.sh

forge create src/KipuBankV3.sol:KipuBankV3 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast -vv \
  --constructor-args \
  "$ADMIN" "$PAUSER" "$V2_ROUTER" "$USDC" \
  "$BANK_CAP_USD6" "$WITHDRAW_CAP_USD6" "$SLIPPAGE_BPS" \
  "$ETH_ORACLE" "$ORACLE_MAX_DELAY" "$ORACLE_DEV_BPS"
```

2) **Script automatizado en Linux: `deploy-bank-admin-sepolia.sh`**
- Lee las mismas variables de `.env` (después de `source script/load-env.sh`).
- Ejecuta internamente `script/DeployKipuBankV3.s.sol:DeployKipuBankV3` usando `ADMIN` directo.
- Fuerza `ORACLE_DEV_BPS=0` solo para ese deploy (útil en Sepolia, donde suele haber mucha diferencia entre el precio de ETH en Uniswap y el oráculo Chainlink).
- Si `ETHERSCAN_API_KEY` está definido, intenta verificar automáticamente el contrato.

```bash
source script/load-env.sh
bash deploy-bank-admin-sepolia.sh
```

Contrato de referencia en Sepolia
---------------------------------
- Address desplegada: `0x4D82522dFa226d7B0C850272dd3b290053029C73`
- URL verificada: https://sepolia.etherscan.io/address/0x4D82522dFa226d7B0C850272dd3b290053029C73

Interaccion
-----------
- Depositos (default sin oraculo):
  - ETH: `depositar(address(0), 0)` con `msg.value > 0` o enviar ETH al `receive()`.
  - USDC: `depositar(USDC, amount)` con `approve` previo.
  - ERC‑20 con par directo: `depositar(token, amount)` con `approve` previo; hace swap y acredita.
- Comportamiento del oráculo (ETH):
  - Todos los depósitos de ETH entran por `depositar(address(0), 0)` y usan internamente `_depositNativeSwap`.
  - Si `oracleDevBps == 0`, el contrato usa solo la ruta directa de Uniswap V2 con slippage (`_depositNativeSwapDirect`).
  - Si `oracleDevBps > 0`, el contrato intenta leer Chainlink; si el precio es válido y no está stale (`ORACLE_MAX_DELAY`), compara `getAmountsOut` (AMM) contra el valor implícito del oráculo y revierte con `DesviacionOraculoExcesiva` cuando la diferencia supera `oracleDevBps`. Si el oráculo falla o está stale, hace fallback a la ruta directa.
- Retiros:
  - `retirar(USDC, amount)` respetando `withdrawCap`.

Funciones principales
---------------------
- `depositar(address token, uint256 amount)` (external, payable)
  - Entrada única para depósitos:
    - `token == address(0)` y `msg.value > 0` → ETH.
    - `token == USDC` → depósito USDC directo.
    - otro ERC‑20 con par directo USDC → `_depositErc20Swap` via Uniswap V2.
  - Aplica `validDepositParams`, `whenNotPaused`, `nonReentrant` y respeta `bankCap`.
- `retirar(address token, uint256 amount)` (external)
  - Sólo permite `token == USDC`.
  - Respeta `withdrawCapUSD6` y actualiza `totalValueUSD6` y contadores.
- `pause()` / `unpause()` (external)
  - Control de pausa global, restringido a `PAUSER_ROLE`.
- `setSlippageBps(uint256 newBps)` (external, sólo `DEFAULT_ADMIN_ROLE`)
  - Actualiza la tolerancia de slippage en bps (máx `MAX_SLIPPAGE_BPS`).
- `setOracle(address newOracle, uint256 newMaxDelay)` (external, sólo `DEFAULT_ADMIN_ROLE`)
  - Cambia el oráculo Chainlink ETH/USD y el `oracleMaxDelay`, validando que el feed tenga `decimals()` válido.
- `setOracleDevBps(uint256 newBps)` (external, sólo `DEFAULT_ADMIN_ROLE`)
  - Ajusta la tolerancia de desvío contra el oráculo en bps (`0..10000`; `0` deshabilita el chequeo).
- Vistas clave:
  - `saldoUSDCDe(address)` → saldo en USDC (6 decimales) de un usuario.
  - `totalValueUSD6Raw()` → TVL del banco en USDC 6 decimales.
  - `bankCapUSD6Raw()` / `withdrawCapUSD6Raw()` → límites global y por retiro.
  - `capacidadDisponibleUSD()` → espacio disponible antes de alcanzar el `bankCap`.
  - `contadoresDeUsuario(address)` → #depósitos y #retiros realizados por un usuario.
  - `tokenAceptado(address)` → indica si un token es válido para depositar (ETH nativo, USDC o ERC‑20 con par directo USDC).

Pruebas con Foundry
-------------------
- Seleccionar entorno: `source script/select-env.sh mainnet` (o `testnet`).
- Fork de 1 comando: `bash script/anvil-fork.sh mainnet`.
- Ejecutar tests: `forge test --rpc-url http://127.0.0.1:8545`.
- Suites incluidas:
  - `test/KipuBankV3.t.sol`: depositos, retiros, slippage, caps, pausa y roles.
  - `test/KipuBankV3Oracle.t.sol`: ruta con oraculo y comparativa de gas. Si `ORACLE_DEV_BPS=0`, los tests de oraculo se auto‑saltan.
  - `test/CheckAmmVsOracle.t.sol`: imprime brecha AMM vs oraculo (tambien se auto‑salta si `ORACLE_DEV_BPS=0`).
 - Scripts de apoyo para pruebas en Sepolia:
   - `bash script/fund-link-and-token.sh`: swappea una fracción pequeña de ETH de las wallets de prueba a LINK y `TOKEN`/`NOT_PAIR_TOKEN` para generar saldos mínimos.
   - `bash script/run-link-and-token-tests.sh`: ejecuta depósitos de prueba contra el banco usando LINK (par directo a USDC) y el token sin par (para verificar el revert `PairInexistente`).

Cobertura y gas
---------------
- Cobertura (resumen): `forge coverage --rpc-url http://127.0.0.1:8545 | tee reportes/coverage-resumen.txt`
  - Si aparece "stack too deep", usar `--ir-minimum`.
- Gas report: `forge test --gas-report --rpc-url http://127.0.0.1:8545 | tee reportes/gas-report.txt`
- Snapshot de gas: `forge snapshot && cp .gas-snapshot reportes/gas-snapshot.txt`

Detalle de suites y tests ejecutados (extracto de `reportes/coverage-resumen.txt`)
---------------------------------------------------------------------------------
- Total suites: 4
  - `test/KipuTimelock.t.sol:KipuTimelockTest` → 1 test
    - `test_timelock_puede_actualizar_configs()`
  - `test/CheckAmmVsOracle.t.sol:CheckAmmVsOracle` → 1 test
    - `test_amm_vs_oraculo_info()`
  - `test/KipuBankV3Oracle.t.sol:KipuBankV3OracleTest` → 5 tests
    - `test_eth_con_oraculo_ok_tolerancia_alta()`
    - `test_eth_con_oraculo_revert_por_desviacion()`
    - `test_eth_oraculo_fallback_por_revert()`
    - `test_eth_sin_oraculo_ok()`
    - `test_gas_eth_sin_vs_con_oraculo()`
  - `test/KipuBankV3.t.sol:KipuBankV3Test` → 34 tests
    - Constructor y parámetros:
      - `test_constructor_decimales_usdc_invalidos()`
      - `test_constructor_parametros_invalidos()`
      - `test_constructor_slippage_excesivo()`
    - Admin/roles/config:
      - `test_admin_setters_config()`
      - `test_roles_admin_otorga_pauser_y_nuevo_pauser_puede_pausar()`
      - `test_roles_no_admin_no_puede_otorgar_pauser()`
      - `test_roles_no_pauser_no_puede_pausar_y_unpause()`
      - `test_roles_pauser_sin_admin_no_puede_otorgar()`
    - Depósitos ERC20:
      - `test_depositar_erc20_con_par_swapea_a_usdc()`
      - `test_depositar_erc20_cap_precheck_revert()`
      - `test_depositar_erc20_revert_cap_en_cierre()`
      - `test_depositar_erc20_revert_cap_en_cierre_sin_mocks()`
      - `test_depositar_parametros_invalidos_erc20()`
      - `test_depositar_revertir_sin_par_directo()`
    - Depósitos ETH:
      - `test_depositar_eth_swapea_a_usdc()`
      - `test_depositar_eth_cap_precheck_revert()`
      - `test_depositar_eth_revert_cap_en_cierre()`
      - `test_depositar_eth_revert_pair_inexistente()`
      - `test_depositar_recibe_eth_via_receive()`
      - `test_receive_eth_monto_cero_revert()`
      - `test_depositar_parametros_invalidos_eth()`
    - Depósitos USDC y vistas:
      - `test_depositar_usdc_directo()`
      - `test_vistas_capacidad_y_contadores()`
      - `test_token_aceptado()`
    - Slippage y caps:
      - `test_bank_cap_precheck_y_credito()`
      - `test_slippage_erc20_custom_revert_por_minout()`
      - `test_slippage_erc20_dentro_margen_ok()`
      - `test_slippage_erc20_fuera_margen_revert()`
      - `test_slippage_eth_custom_revert_por_minout()`
      - `test_slippage_eth_dentro_margen_ok()`
      - `test_slippage_eth_fuera_margen_revert()`
    - Retiros y pausa:
      - `test_retirar_respeta_withdraw_cap()`
      - `test_retirar_token_invalido_y_casos_borde()`
      - `test_pausar_bloquea_ops_y_roles()`

En total: 41 tests ejecutados, 0 fallados, 0 skippeados.

Reportes incluidos
------------------
- `reportes/gas-report.txt`: consumo de gas por funcion (incluye comparativa de la ruta con oraculo).
- `reportes/coverage-resumen.txt`: cobertura por archivo; `src/KipuBankV3.sol` supera 50% (objetivo de la consigna).
- `reportes/gas-snapshot.txt`: baseline para comparar cambios de gas entre commits.

Resumen minimo de reportes (ejemplo)
------------------------------------
Gas (extracto de `reportes/gas-report.txt`):

```
Deployment Cost: 2,190,838 gas

Function                         Avg Gas   Calls
-------------------------------- --------  -----
depositar                        117,521   19
receive                          226,885   1
retirar                           36,448   6
```

Cobertura (extracto de `reportes/coverage-resumen.txt`):

```
src/KipuBankV3.sol   Lines 79.15% (167/211)  Statements 74.83% (223/298)  Branches 60.71% (34/56)  Funcs 91.30% (21/23)
Total                Lines 58.16% (171/294)  Statements 56.82% (225/396)  Branches 53.12% (34/64)  Funcs 71.88% (23/32)
```

Notas Sepolia
-------------
- Direcciones de Uniswap en testnets pueden variar; usa `.env.example` como referencia y ajustar segun proveedor.
- Verificar que exista par directo `WETH/USDC`; sin ese par, los depositos de ETH fallan.
- En Sepolia en particular, se ha observado que el precio implícito del pool WETH/USDC en Uniswap V2 y el precio de Chainlink pueden diferir mucho; con `oracleDevBps > 0` esto provoca reverts frecuentes por `DesviacionOraculoExcesiva`. Por eso la instancia de referencia y el script `deploy-bank-admin-sepolia.sh` usan `ORACLE_DEV_BPS=0` por defecto.

Guía de despliegue en Sepolia (resumen de PASOS.md)
---------------------------------------------------
1) **Preparar `.env`**
   - Copiar `.env.example` a `.env`.
   - Completar: `SEPOLIA_RPC_URL`, `V2_ROUTER`, `FACTORY`, `WETH`, `USDC`, `ETH_ORACLE`, `BANK_CAP_USD6`, `WITHDRAW_CAP_USD6`, `SLIPPAGE_BPS`.
   - Definir credenciales de deploy: `PRIVATE_KEY`, `ADMIN`, `PAUSER`.
   - Opcional: configurar sección de timelock (`TIMELOCK_*`) si vas a usar `KipuTimelock`.

2) **Cargar variables en la shell**
   - `source script/load-env.sh` (exporta todas las variables de `.env`).

3) **Deploy de KipuBankV3 sin timelock (ADMIN directo)**
   - Opción manual: comando `forge create` descrito en la sección "Despliegue y verificación".
   - Opción script Linux: `bash deploy-bank-admin-sepolia.sh` (usa `ADMIN` directo y fuerza `ORACLE_DEV_BPS=0` solo para ese deploy).
   - Guardar la dirección desplegada en `KIPUBANKV3_SEPOLIA` en `.env`.

4) **(Opcional) Deploy de KipuTimelock y banco gobernado por timelock**
   - Deploy timelock: `forge create src/KipuTimelock.sol:KipuTimelock ...` usando los parámetros de `TIMELOCK_*`.
   - Guardar la dirección en `KIPUTIMELOCK_SEPOLIA` y `TIMELOCK_ADDRESS`.
   - Para una segunda instancia "seria", usar `TIMELOCK_ADDRESS` como primer parámetro (`admin`) al desplegar otro `KipuBankV3`.

5) **Verificación en Etherscan**
   - Con `ETHERSCAN_API_KEY` en `.env`, usar `forge verify-contract` con los `CONSTRUCTOR_ARGS` apropiados (ADMIN directo o timelock como primer parámetro).

6) **Tráfico de prueba sobre el banco**
   - Opcional: usar `script/fund-link-and-token.sh` y `script/run-link-and-token-tests.sh` para generar depósitos mínimos con LINK y el token sin par.

Apéndice: Pasos detallados de deploy (versión textual de `PASOS.md`)
--------------------------------------------------------------------
Para referencia completa, estos son los pasos más detallados descritos en `PASOS.md`:

1. **Configurar `.env`**
   - Sección 1.1 (Sepolia): definir `SEPOLIA_RPC_URL`, `V2_ROUTER`, `FACTORY`, `WETH`, `USDC`, `PAIR_TOKEN`, `NOT_PAIR_TOKEN`, `ETH_ORACLE`, `ORACLE_MAX_DELAY`, `ORACLE_DEV_BPS`.
   - Sección 1.2 (Banco): `BANK_CAP_USD6`, `WITHDRAW_CAP_USD6`, `SLIPPAGE_BPS`.
   - Sección 1.3 (Deploy/roles): `PRIVATE_KEY`, `ADMIN`, `PAUSER`.
   - Sección 1.4 (Timelock): `TIMELOCK_MIN_DELAY`, `TIMELOCK_PROPOSER`, `TIMELOCK_EXECUTOR`, `TIMELOCK_ADMIN`, y placeholders `KIPUTIMELOCK_SEPOLIA`, `KIPUBANKV3_SEPOLIA` para completarlos luego.

2. **Cargar `.env` y seleccionar entorno**
   - `source script/load-env.sh` para exportar todas las variables.
   - (Opcional) `source script/select-env.sh testnet` o `mainnet` para crear variables unificadas (`V2_ROUTER`, `WETH`, `USDC`, `ETH_ORACLE`, etc.).

3. **Deploy de `KipuBankV3` sin timelock (ADMIN directo)**
   - Comando manual (idéntico al de la sección 3.1):

```bash
forge create src/KipuBankV3.sol:KipuBankV3 \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast -vv \
  --constructor-args \
  "$ADMIN" "$PAUSER" "$V2_ROUTER" "$USDC" \
  "$BANK_CAP_USD6" "$WITHDRAW_CAP_USD6" "$SLIPPAGE_BPS" \
  "$ETH_ORACLE" "$ORACLE_MAX_DELAY" "$ORACLE_DEV_BPS"
```

   - Guardar la address devuelta en `KIPUBANKV3_SEPOLIA` dentro de `.env`.

4. **(Opcional) Deploy de `KipuTimelock` y banco gobernado por timelock**
   - Deploy timelock:

```bash
forge create src/KipuTimelock.sol:KipuTimelock \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast -vv \
  --constructor-args \
  "$TIMELOCK_MIN_DELAY" "[$TIMELOCK_PROPOSER]" "[$TIMELOCK_EXECUTOR]" "$TIMELOCK_ADMIN"
```

   - Guardar la address del timelock en `KIPUTIMELOCK_SEPOLIA` y `TIMELOCK_ADDRESS`.
   - Si se desea que el timelock sea `ADMIN` de un banco, actualizar `ADMIN=TIMELOCK_ADDRESS` y desplegar una nueva instancia de `KipuBankV3` usando esa address como primer parámetro del constructor.

5. **Verificación de contratos**
   - Timelock (`KipuTimelock`): codificar constructor con `cast abi-encode 'constructor(uint256,address[],address[],address)' ...` y usar `forge verify-contract` en la address `TIMELOCK_ADDRESS`.
   - Banco (`KipuBankV3`): codificar constructor con `cast abi-encode 'constructor(address,address,address,address,uint256,uint256,uint256,address,uint256,uint256)' ...` usando como primer parámetro `ADMIN` (EOA/multisig) o `TIMELOCK_ADDRESS` (si usaste timelock).

Todos estos pasos están documentados también en español en `PASOS.md` con ejemplos concretos de valores para Sepolia.


Cumplimiento de consignas
-------------------------
- Manejar tokens soportados (ETH/USDC/ERC20 con par directo) → OK.
- Swaps a USDC dentro del contrato → OK.
- Depositos/retiros/roles → OK.
- Respetar bank cap (pre y post swap) → OK.
- Cobertura >= 50% → OK (ver `reportes/coverage-resumen.txt`).

Apuntes de seguridad
--------------------
- Slippage protege al usuario ajustando `amountOutMin`; si no se cumple, revierte.
- La credencial final siempre usa el monto real del swap, no la cotizacion.
- La ruta con oráculo compara AMM vs Chainlink y revierte por precio viejo o desvío alto. **En Sepolia en particular, debido a la alta discrepancia entre el pool WETH/USDC y el oráculo, se recomienda deshabilitar este chequeo (`oracleDevBps = 0`) para pruebas**, usando solo slippage o un fork de mainnet para escenarios realistas.
- Protecciones de reentrada, pausas y validaciones de parametros en todas las rutas.

Amenazas y trade‑offs
---------------------
- Manipulacion de precio en AMM: en pools poco liquidos el precio puede ser movido. La ruta default solo usa slippage; la ruta con oraculo (`depositarEthConOraculo`) compara contra Chainlink y revierte si hay desvio mayor a `ORACLE_DEV_BPS`.
- Alcance del oraculo (POC): la verificacion con oraculo esta implementada solo para ETH como prueba de concepto. Extenderla a todos los pares contra USDC requeriria feeds de oraculo por cada token, y muchos pares poco liquidos ya son vulnerables por si mismos; por eso se prioriza slippage en la ruta default y oraculo opcional en ETH.
- Liquidez en testnets: gaps grandes entre AMM y oraculo son comunes; para pruebas se sugiere `ORACLE_DEV_BPS=0` o tolerancias altas, y/o usar mainnet fork para escenarios realistas.
- Solo par directo a USDC: se evita complejidad de rutas multi‑hop, pero limita tokens aceptados. Simplifica validaciones y reduce superficie de ataque.
- Front‑running / sandwich: mitigado por slippage, pero **incluso con oráculo sigue existiendo riesgo de MEV**. Validar contra Chainlink ayuda a detectar desvíos extremos, pero no impide que un atacante reorganice transacciones alrededor del swap; la app/UX puede aumentar `slippageBps` prudencialmente o forzar tolerancias conservadoras para operaciones sensibles.
- Dependencia del oraculo: si el precio esta viejo (`ORACLE_MAX_DELAY`) o el feed falla, las operaciones por la ruta con oraculo revierten (disponibilidad vs seguridad).
- DOS por cap: si el bank cap se alcanza, nuevos depositos revierten hasta que se retiren fondos.
- Roles y pausas: mal uso del pauser/admin puede frenar el sistema; se recomienda gobernanza/procesos para cambios de rol.
- Sin upgradeability: ante bugs se requiere redeploy. Menos riesgo de proxy, pero menos flexibilidad.
- Allowances: se limpia el allowance post swap por higiene; reduce riesgo de approvals colgados.

Roadmap y posibles mejoras futuras
----------------------------------
- **Rutas multi‑hop y agregador de liquidez**: hoy sólo se aceptan tokens con par directo a USDC. Una evolución natural sería soportar rutas multi‑hop (p. ej. TOKEN→WETH→USDC) y/o integrar un agregador para encontrar la mejor ruta, manteniendo el chequeo de `bankCap` y slippage.
- **Soporte extendido de oráculos**: el chequeo con Chainlink está implementado sólo para ETH y es opcional. Futuras versiones podrían:
  - añadir feeds específicos para tokens clave (por ejemplo, stables o blue‑chips),
  - combinar AMM + oráculo por token para reglas de admisión más ricas,
  - introducir umbrales dinámicos según liquidez/volatilidad.
- **Gobernanza y timelock por defecto**: este repo incluye `KipuTimelock` y ejemplos de uso, pero la instancia principal corre con `ADMIN` directo. Para entornos productivos sería razonable:
  - usar siempre timelock/multisig como `DEFAULT_ADMIN_ROLE`,
  - documentar playbooks de gobernanza (cambios de slippage, oráculo, caps) y procesos de emergencia.
- **Mejoras de UX y monitoreo off‑chain**: agregar tooling que exponga métricas (TVL, uso de caps, frecuencia de reverts), alertas sobre precios fuera de rango y dashboards para auditar rutas y oráculo.
- **Optimización de gas y layout**: aunque el contrato ya usa errores personalizados y estructuras razonables, hay espacio para:
  - refinar packing de storage,
  - analizar patrones de uso reales para inlining/outsourcing de funciones,
  - estudiar un posible split en módulos (router/oráculo/bóveda) sin perder claridad.
